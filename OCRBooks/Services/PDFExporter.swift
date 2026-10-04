import CoreGraphics
import CoreText
import Foundation

enum PDFExporterError: Error, LocalizedError {
    case contextCreationFailed
    case missingImage(page: Int)

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "No se pudo crear el PDF de salida."
        case .missingImage(let page):
            return "Falta la imagen restaurada de la página \(page + 1)."
        }
    }
}

/// Exporta un PDF con cada página restaurada y una capa de texto invisible
/// (OCR) perfectamente alineada, de modo que el resultado se puede buscar,
/// seleccionar y copiar conservando la estética original del libro.
enum PDFExporter {

    struct ExportPage {
        let index: Int
        let imageURL: URL
        let lines: [RecognizedLine]
    }

    static func export(pages: [ExportPage], dpi: Double, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw PDFExporterError.contextCreationFailed
        }

        for page in pages {
            try autoreleasepool {
                guard let image = ImageUtil.readImage(from: page.imageURL) else {
                    throw PDFExporterError.missingImage(page: page.index)
                }

                // Tamaño físico en puntos: se conserva el tamaño real del libro.
                let widthPt = CGFloat(image.width) / CGFloat(dpi) * 72.0
                let heightPt = CGFloat(image.height) / CGFloat(dpi) * 72.0
                var mediaBox = CGRect(x: 0, y: 0, width: widthPt, height: heightPt)

                let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
                let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
                ctx.beginPDFPage(pageInfo)

                ctx.interpolationQuality = .high
                ctx.draw(image, in: mediaBox)

                drawInvisibleTextLayer(page.lines, in: ctx, pageWidth: widthPt, pageHeight: heightPt)

                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }

    /// Dibuja cada línea reconocida como texto invisible sobre su posición
    /// exacta (las cajas de Vision y las coordenadas PDF comparten origen
    /// abajo-izquierda).
    private static func drawInvisibleTextLayer(
        _ lines: [RecognizedLine],
        in ctx: CGContext,
        pageWidth: CGFloat,
        pageHeight: CGFloat
    ) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)

        for line in lines {
            let rect = CGRect(
                x: line.bbox.minX * pageWidth,
                y: line.bbox.minY * pageHeight,
                width: line.bbox.width * pageWidth,
                height: line.bbox.height * pageHeight
            )
            guard rect.width > 0.1, rect.height > 0.1 else { continue }

            let fontSize = rect.height * 0.85
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            let attributed = NSAttributedString(string: line.text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)

            let naturalWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard naturalWidth > 0 else { continue }

            // Estirar/encoger horizontalmente para cubrir el ancho real de la
            // línea impresa: la selección en el PDF coincide con la imagen.
            let sx = rect.width / naturalWidth
            ctx.textMatrix = CGAffineTransform(scaleX: sx, y: 1)
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.18)
            CTLineDraw(ctLine, ctx)
        }

        ctx.textMatrix = .identity
        ctx.restoreGState()
    }
}
