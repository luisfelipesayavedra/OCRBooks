import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageUtilError: Error {
    case contextCreationFailed
    case encodingFailed
}

enum ImageUtil {

    /// Copia reducida de la imagen limitada a `maxDimension` en su lado mayor.
    /// Devuelve la misma imagen si ya es más pequeña.
    static func scaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let k = maxDimension / max(w, h)
        guard k < 1 else { return image }

        let nw = max(1, Int(w * k))
        let nh = max(1, Int(h * k))
        guard let ctx = CGContext(
            data: nil,
            width: nw,
            height: nh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    /// Guarda la imagen como PNG (sin pérdida) en `url`.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ImageUtilError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageUtilError.encodingFailed
        }
    }

    /// Carga una imagen desde disco.
    static func readImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
