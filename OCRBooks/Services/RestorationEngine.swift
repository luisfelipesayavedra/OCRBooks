import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum RestorationEngineError: Error {
    case renderFailed
}

/// Motor de restauración. Dos caminos:
///
/// **Suave** — cadena Core Image ligera (realce sin reconstrucción).
///
/// **Profunda / Máxima** — reconstrucción real de la página:
/// 1. Deskew + reducción de ruido (Core Image).
/// 2. Aplanado de iluminación en CPU (papel blanco uniforme).
/// 3. Pasada previa de OCR para localizar las zonas de texto.
/// 4. Binarización adaptativa Sauvola (umbral local, palabra por palabra).
/// 5. Despeckle por componentes conexas: motas fuera siempre; manchas fuera
///    del texto fuera (con protección opcional de ilustraciones).
/// 6. Composición: papel blanco puro, tinta con el detalle del trazo original.
/// 7. Máscara de enfoque final.
enum RestorationEngine {

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func enhance(_ input: CGImage, skewAngle: Double, settings: RestorationSettings) throws -> CGImage {
        switch settings.strength {
        case .light:
            return try lightEnhance(input, skewAngle: skewAngle, settings: settings)
        case .deep, .maximum:
            return try deepEnhance(input, skewAngle: skewAngle, settings: settings)
        }
    }

    // MARK: - Camino profundo

    private static func deepEnhance(_ input: CGImage, skewAngle: Double, settings: RestorationSettings) throws -> CGImage {
        // 1. Deskew + ruido con Core Image.
        var ci = CIImage(cgImage: input)
        let extent = ci.extent
        if settings.deskew, abs(skewAngle) >= SkewDetector.step / 2 {
            ci = desheared(ci, bitmapAngleDegrees: skewAngle)
        }
        if settings.noiseReduction > 0 {
            let noise = CIFilter.noiseReduction()
            noise.inputImage = ci
            noise.noiseLevel = Float(settings.noiseReduction)
            noise.sharpness = 0.6
            ci = noise.outputImage ?? ci
        }
        ci = ci.cropped(to: extent)
        guard let base = context.createCGImage(ci, from: ci.extent) else {
            throw RestorationEngineError.renderFailed
        }

        let w = base.width
        let h = base.height
        let ctx = try DeepRestorer.rgbaContext(from: base)

        // 2. Aplanado de iluminación (siempre en el camino profundo: es la
        // base para que Sauvola y el despeckle funcionen bien).
        DeepRestorer.flattenIllumination(in: ctx, dpi: settings.dpi)

        // 3. Pasada previa de OCR sobre la imagen aplanada: las cajas de texto
        // guían la eliminación de manchas.
        var keepRects: [CGRect] = []
        if settings.removeStainsOutsideText, let flat = ctx.makeImage() {
            let lines = (try? OCRService.recognize(
                in: flat, languages: settings.recognitionLanguages
            )) ?? []
            let margin = CGFloat(max(6, Int(settings.dpi / 40)))
            keepRects = lines.map { line in
                // Vision: origen abajo-izquierda normalizado → píxeles con
                // fila 0 arriba (sistema de los buffers de DeepRestorer).
                CGRect(
                    x: line.bbox.minX * CGFloat(w),
                    y: (1 - line.bbox.maxY) * CGFloat(h),
                    width: line.bbox.width * CGFloat(w),
                    height: line.bbox.height * CGFloat(h)
                ).insetBy(dx: -margin, dy: -margin)
            }
        }

        // 4. Binarización adaptativa.
        let gray = DeepRestorer.grayArray(from: ctx)
        let window = max(25, Int(settings.dpi / 8)) | 1
        var mask = DeepRestorer.sauvolaMask(
            gray: gray, width: w, height: h,
            window: window, k: settings.strength.sauvolaK
        )

        // 5. Despeckle: motas y manchas.
        let unit = (settings.dpi / 300) * (settings.dpi / 300)
        let minSpeck = Int(6 * unit * settings.despeckleLevel * settings.strength.despeckleMultiplier)
        let protectArea = settings.protectIllustrations
            ? max(1, Int(0.003 * Double(w * h)))
            : Int.max
        DeepRestorer.despeckle(
            mask: &mask,
            width: w, height: h,
            keepRects: keepRects,
            minSpeck: minSpeck,
            removeOutsideText: settings.removeStainsOutsideText && !keepRects.isEmpty,
            protectArea: protectArea
        )

        // 6. Composición final (dilatación 1 px para conservar el borde
        // antialiasado de los trazos).
        if settings.mode != .blackWhite {
            mask = DeepRestorer.dilated(mask, width: w, height: h)
        }
        let inkGamma = 1.0
            + (settings.contrast - 1.0) * 2.0
            + settings.strength.extraInkGamma
        DeepRestorer.compose(
            in: ctx, gray: gray, mask: mask,
            mode: settings.mode, inkGamma: inkGamma
        )

        guard let composed = ctx.makeImage() else {
            throw RestorationEngineError.renderFailed
        }

        // 7. Enfoque final (no en B/N puro: ya es binario).
        if settings.sharpness > 0 && settings.mode != .blackWhite {
            return try sharpened(composed, settings: settings)
        }
        return composed
    }

    private static func sharpened(_ image: CGImage, settings: RestorationSettings) throws -> CGImage {
        var ci = CIImage(cgImage: image)
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = ci
        unsharp.radius = Float(max(1.5, settings.dpi / 160.0))
        unsharp.intensity = Float(settings.sharpness)
        ci = (unsharp.outputImage ?? ci).cropped(to: ci.extent)
        guard let out = context.createCGImage(ci, from: ci.extent) else {
            throw RestorationEngineError.renderFailed
        }
        return out
    }

    // MARK: - Camino suave (realce Core Image)

    private static func lightEnhance(_ input: CGImage, skewAngle: Double, settings: RestorationSettings) throws -> CGImage {
        var image = CIImage(cgImage: input)
        let extent = image.extent

        if settings.deskew, abs(skewAngle) >= SkewDetector.step / 2 {
            image = desheared(image, bitmapAngleDegrees: skewAngle)
        }

        if settings.noiseReduction > 0 {
            let noise = CIFilter.noiseReduction()
            noise.inputImage = image
            noise.noiseLevel = Float(settings.noiseReduction)
            noise.sharpness = 0.6
            image = noise.outputImage ?? image
        }

        if settings.flattenBackground {
            let sigma = max(20.0, settings.dpi / 8.0)
            let blurred = image
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: image.extent)
            // División: original / fondo estimado -> papel ~ blanco uniforme.
            let divide = CIFilter.divideBlendMode()
            divide.backgroundImage = image
            divide.inputImage = blurred
            image = (divide.outputImage ?? image).cropped(to: image.extent)
        }

        let color = CIFilter.colorControls()
        color.inputImage = image
        color.contrast = Float(settings.contrast)
        color.brightness = 0
        color.saturation = settings.mode == .color ? 1.0 : 0.0
        image = color.outputImage ?? image

        if settings.sharpness > 0 {
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = image
            unsharp.radius = Float(max(1.5, settings.dpi / 160.0))
            unsharp.intensity = Float(settings.sharpness)
            image = unsharp.outputImage ?? image
        }

        if settings.mode == .blackWhite {
            let otsu = CIFilter.colorThresholdOtsu()
            otsu.inputImage = image
            image = otsu.outputImage ?? image
        }

        image = image.cropped(to: extent)

        guard let output = context.createCGImage(image, from: image.extent) else {
            throw RestorationEngineError.renderFailed
        }
        return output
    }

    /// Aplica la cizalla inversa a la inclinación detectada.
    ///
    /// `SkewDetector` trabaja en coordenadas de bitmap (y hacia abajo); CIImage
    /// usa y hacia arriba, por eso el signo de `b` se invierte. El término `ty`
    /// mantiene fijo el centro horizontal de la página.
    static func desheared(_ image: CIImage, bitmapAngleDegrees angle: Double) -> CIImage {
        let t = CGFloat(tan(angle * .pi / 180))
        let extent = image.extent
        let transform = CGAffineTransform(a: 1, b: -t, c: 0, d: 1, tx: 0, ty: t * extent.midX)
        let sheared = image.transformed(by: transform)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        return sheared.composited(over: white).cropped(to: extent)
    }
}
