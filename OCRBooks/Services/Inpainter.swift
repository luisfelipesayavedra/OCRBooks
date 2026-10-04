import CoreGraphics
import Foundation
import opencv2

/// Inpainting con OpenCV (algoritmo de Telea): reconstruye regiones de la
/// página rellenándolas con la textura del papel circundante, en vez de
/// pintarlas de blanco. Se usa en dos sitios:
///
/// - el modo de salida "Papel restaurado": las manchas detectadas por el
///   despeckle se rellenan con papel real, conservando la textura y el tono
///   originales del libro;
/// - el borrador en modo "Reconstruir": el trazo del usuario se rellena con
///   el papel de alrededor (y se aplica solo sobre el recorte afectado, no
///   sobre toda la página).
enum Inpainter {

    private static let INPAINT_TELEA: Int32 = 1 // cv::INPAINT_TELEA

    /// Rellena los píxeles donde `holeMask` != 0 con textura circundante.
    /// `holeMask` tiene `width*height` bytes, fila 0 arriba (mismo sistema
    /// que los buffers de DeepRestorer y que las filas de memoria de CGImage).
    static func inpaint(image: CGImage, holeMask: [UInt8], radius: Double) -> CGImage? {
        let w = image.width
        let h = image.height
        guard holeMask.count == w * h else { return nil }

        // CGImage → bytes RGB compactos.
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let row = y * bpr
            let out = y * w * 3
            for x in 0..<w {
                let o = row + x * 4
                let q = out + x * 3
                rgb[q] = px[o]
                rgb[q + 1] = px[o + 1]
                rgb[q + 2] = px[o + 2]
            }
        }

        // OpenCV: inpaint Telea.
        let src = Mat(rows: Int32(h), cols: Int32(w), type: CvType.CV_8UC3)
        let mask = Mat(rows: Int32(h), cols: Int32(w), type: CvType.CV_8UC1)
        let dst = Mat()
        do {
            try src.put(row: 0, col: 0, data: rgb)
            try mask.put(row: 0, col: 0, data: holeMask)
            Photo.inpaint(
                src: src, inpaintMask: mask, dst: dst,
                inpaintRadius: radius, flags: INPAINT_TELEA
            )
            try dst.get(row: 0, col: 0, data: &rgb)
        } catch {
            return nil
        }

        // RGB → CGImage.
        for y in 0..<h {
            let row = y * bpr
            let input = y * w * 3
            for x in 0..<w {
                let o = row + x * 4
                let q = input + x * 3
                px[o] = rgb[q]
                px[o + 1] = rgb[q + 1]
                px[o + 2] = rgb[q + 2]
                px[o + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    /// Aplica un trazo del borrador en modo "Reconstruir": rellena la zona del
    /// trazo con el papel circundante. Trabaja solo sobre el recorte afectado
    /// (bbox del trazo + margen), así es rápido incluso en páginas enormes.
    /// El trazo llega en coordenadas de imagen con origen abajo-izquierda
    /// (las del canvas del editor).
    static func applyStroke(_ stroke: EraserStroke, to image: CGImage) -> CGImage? {
        guard let first = stroke.points.first else { return nil }
        let w = image.width
        let h = image.height

        // BBox del trazo (y hacia arriba) + margen para que Telea tenga contexto.
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in stroke.points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let margin = stroke.width * 3 + 16
        let x0 = max(0, Int(minX - margin))
        let x1 = min(w, Int(maxX + margin))
        let yUp0 = max(0, Int(minY - margin))
        let yUp1 = min(h, Int(maxY + margin))
        let cw = x1 - x0
        let ch = yUp1 - yUp0
        guard cw > 4, ch > 4 else { return nil }

        // Recorte (CGImage.cropping usa origen arriba-izquierda).
        let topY = h - yUp1
        guard let crop = image.cropping(to: CGRect(x: x0, y: topY, width: cw, height: ch)) else {
            return nil
        }

        // Máscara del trazo dentro del recorte (contexto gris, origen
        // abajo-izquierda; sus filas de memoria coinciden con las del recorte).
        guard let maskCtx = CGContext(
            data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        maskCtx.setFillColor(CGColor(gray: 0, alpha: 1))
        maskCtx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        maskCtx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        maskCtx.setFillColor(CGColor(gray: 1, alpha: 1))
        maskCtx.setLineCap(.round)
        maskCtx.setLineJoin(.round)
        maskCtx.translateBy(x: CGFloat(-x0), y: CGFloat(-yUp0))
        if stroke.points.count == 1 {
            let r = stroke.width / 2
            maskCtx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
        } else {
            maskCtx.setLineWidth(stroke.width)
            maskCtx.beginPath()
            maskCtx.move(to: first)
            for p in stroke.points.dropFirst() { maskCtx.addLine(to: p) }
            maskCtx.strokePath()
        }
        guard let maskData = maskCtx.data else { return nil }
        let maskPtr = maskData.bindMemory(to: UInt8.self, capacity: cw * ch)
        let holeMask = [UInt8](UnsafeBufferPointer(start: maskPtr, count: cw * ch))

        let radius = max(3.0, min(20.0, Double(stroke.width) / 4))
        guard let patched = inpaint(image: crop, holeMask: holeMask, radius: radius) else {
            return nil
        }

        // Componer el parche de vuelta en la página completa.
        guard let outCtx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        outCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        outCtx.draw(patched, in: CGRect(x: x0, y: yUp0, width: cw, height: ch))
        return outCtx.makeImage()
    }
}
