import CoreGraphics
import Foundation

/// Detección de inclinación por perfil de proyección: se prueba un abanico de
/// ángulos pequeños y se elige el que maximiza la varianza de las sumas por
/// fila (las líneas de texto bien alineadas concentran la tinta en pocas filas).
///
/// El ángulo devuelto es el parámetro de la cizalla y' = y + x·tan(θ) (en
/// coordenadas de bitmap, origen arriba-izquierda) que mejor alinea el texto;
/// `RestorationEngine.desheared` aplica exactamente esa misma transformación,
/// de modo que detección y corrección son consistentes por construcción.
enum SkewDetector {

    static let maxAngle = 3.0 // grados
    static let step = 0.25

    static func detectAngle(in image: CGImage) -> Double {
        let maxDim = 900
        let w0 = image.width
        let h0 = image.height
        let k = Double(maxDim) / Double(max(w0, h0))
        let w = k < 1 ? Int(Double(w0) * k) : w0
        let h = k < 1 ? Int(Double(h0) * k) : h0

        // Volcado a escala de grises de 8 bits.
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)

        // Umbral de tinta relativo al brillo medio de la página.
        var total = 0
        for i in stride(from: 0, to: w * h, by: 7) { total += Int(pixels[i]) }
        let mean = Double(total) / Double((w * h + 6) / 7)
        let threshold = UInt8(max(10, min(245, mean * 0.78)))

        var bestAngle = 0.0
        var bestScore = -1.0
        let halfW = Double(w) / 2

        var angle = -maxAngle
        while angle <= maxAngle + 1e-9 {
            let t = tan(angle * .pi / 180)
            var rows = [Int](repeating: 0, count: h)
            for y in 0..<h {
                let rowBase = y * w
                for x in stride(from: 0, to: w, by: 2) {
                    if pixels[rowBase + x] < threshold {
                        let yy = y + Int((Double(x) - halfW) * t)
                        if yy >= 0 && yy < h { rows[yy] += 1 }
                    }
                }
            }
            // Varianza de las sumas por fila.
            let n = Double(h)
            let sum = Double(rows.reduce(0, +))
            let meanRow = sum / n
            var variance = 0.0
            for r in rows {
                let d = Double(r) - meanRow
                variance += d * d
            }
            variance /= n

            if variance > bestScore {
                bestScore = variance
                bestAngle = angle
            }
            angle += step
        }

        return bestAngle
    }
}
