import PDFKit
import CoreGraphics

enum PDFRendererError: Error {
    case contextCreationFailed
    case renderFailed
}

enum PDFRenderer {

    /// Reconstruye la página a la resolución pedida. Trabajar siempre desde el
    /// PDF original a DPI alto es lo que permite recuperar resolución y nitidez:
    /// nunca se re-escala una imagen ya degradada.
    static func render(page: PDFPage, dpi: Double) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = CGFloat(dpi / 72.0)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PDFRendererError.contextCreationFailed }

        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)

        // Respetar la rotación declarada por la página.
        if page.rotation != 0 {
            let radians = -CGFloat(page.rotation) * .pi / 180
            ctx.translateBy(x: bounds.midX, y: bounds.midY)
            ctx.rotate(by: radians)
            ctx.translateBy(x: -bounds.midX, y: -bounds.midY)
        }

        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        guard let image = ctx.makeImage() else { throw PDFRendererError.renderFailed }
        return image
    }

    /// Miniatura rápida para la barra lateral.
    static func thumbnail(page: PDFPage, maxDimension: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let k = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * k, height: bounds.height * k)
        let nsImage = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
