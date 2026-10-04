import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum RestorationEngineError: Error {
    case renderFailed
}

/// Motor de restauración. Toda la cadena trabaja sobre la página reconstruida
/// a DPI alto desde el PDF, en este orden:
///
/// 1. Corrección de inclinación (cizalla equivalente a la detectada).
/// 2. Reducción de ruido y grano del escaneo.
/// 3. Aplanado de iluminación: se divide la imagen entre una versión muy
///    desenfocada de sí misma, lo que blanquea el papel y elimina sombras de
///    encuadernación y amarilleo irregular sin tocar la tinta.
/// 4. Contraste / modo de color.
/// 5. Máscara de enfoque para recuperar el perfil de las letras.
/// 6. Binarización Otsu opcional (modo blanco y negro).
enum RestorationEngine {

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func enhance(_ input: CGImage, skewAngle: Double, settings: RestorationSettings) throws -> CGImage {
        var image = CIImage(cgImage: input)
        let extent = image.extent

        // 1. Deskew (cizalla consistente con SkewDetector; para ángulos < 3°
        // la diferencia con una rotación pura es despreciable).
        if settings.deskew, abs(skewAngle) >= SkewDetector.step / 2 {
            image = desheared(image, bitmapAngleDegrees: skewAngle)
        }

        // 2. Reducción de ruido.
        if settings.noiseReduction > 0 {
            let noise = CIFilter.noiseReduction()
            noise.inputImage = image
            noise.noiseLevel = Float(settings.noiseReduction)
            noise.sharpness = 0.6
            image = noise.outputImage ?? image
        }

        // 3. Aplanado de iluminación y blanqueo del papel.
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

        // 4. Contraste y color.
        let color = CIFilter.colorControls()
        color.inputImage = image
        color.contrast = Float(settings.contrast)
        color.brightness = 0
        color.saturation = settings.mode == .color ? 1.0 : 0.0
        image = color.outputImage ?? image

        // 5. Nitidez de las letras.
        if settings.sharpness > 0 {
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = image
            unsharp.radius = Float(max(1.5, settings.dpi / 160.0))
            unsharp.intensity = Float(settings.sharpness)
            image = unsharp.outputImage ?? image
        }

        // 6. Binarización para texto puro.
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
