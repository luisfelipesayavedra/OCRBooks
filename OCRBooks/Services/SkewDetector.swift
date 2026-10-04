import CoreGraphics
import Foundation

/// Detección de inclinación por perfil de proyección: se prueba un abanico de
/// ángulos y se elige el que maximiza la varianza de las sumas por fila (las
/// líneas de texto bien alineadas concentran la tinta en pocas filas).
///
/// Robustez:
/// - solo se analiza la zona central de la página (se descartan los bordes,
///   donde las sombras de escaneo y los filos del papel engañan al detector);
/// - búsqueda en dos pasadas: gruesa (±5°, pasos de 0,5°) y fina
///   (±0,5° alrededor del mejor, pasos de 0,1°).
///
/// El ángulo devuelto es el parámetro de la cizalla y' = y + x·tan(θ) (en
/// coordenadas de bitmap, origen arriba-izquierda) que mejor alinea el texto;
/// `RestorationEngine.desheared` aplica exactamente esa misma transformación,
/// de modo que detección y corrección son consistentes por construcción.
enum SkewDetector {

    static let maxAngle = 5.0 // grados
    static let step = 0.1     // resolución final

    static func detectAngle(in image: CGImage) -> Double {
        let maxDim = 1000
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

        // Zona central: descartar un 8 % por cada lado (bordes del escaneo).
        let x0 = w * 8 / 100, x1 = w - x0
        let y0 = h * 8 / 100, y1 = h - y0
        guard x1 - x0 > 32, y1 - y0 > 32 else { return 0 }

        // Umbral de tinta relativo al brillo medio de la zona analizada.
        var total = 0
        var samples = 0
        var y = y0
        while y < y1 {
            let row = y * w
            var x = x0
            while x < x1 {
                total += Int(pixels[row + x])
                samples += 1
                x += 7
            }
            y += 3
        }
        guard samples > 0 else { return 0 }
        let mean = Double(total) / Double(samples)
        let threshold = UInt8(max(10, min(245, mean * 0.78)))

        // Puntuación de un ángulo: varianza de las sumas de tinta por fila
        // tras proyectar con la cizalla y' = y + (x - centro)·tan(θ).
        let centerX = Double(x0 + x1) / 2
        func score(_ angle: Double) -> Double {
            let t = tan(angle * .pi / 180)
            var rows = [Int](repeating: 0, count: h)
            for y in y0..<y1 {
                let rowBase = y * w
                var x = x0
                while x < x1 {
                    if pixels[rowBase + x] < threshold {
                        let yy = y + Int((Double(x) - centerX) * t)
                        if yy >= 0 && yy < h { rows[yy] += 1 }
                    }
                    x += 2
                }
            }
            let n = Double(h)
            let sum = Double(rows.reduce(0, +))
            let meanRow = sum / n
            var variance = 0.0
            for r in rows {
                let d = Double(r) - meanRow
                variance += d * d
            }
            return variance / n
        }

        // Pasada gruesa.
        var bestAngle = 0.0
        var bestScore = -1.0
        var angle = -maxAngle
        while angle <= maxAngle + 1e-9 {
            let s = score(angle)
            if s > bestScore {
                bestScore = s
                bestAngle = angle
            }
            angle += 0.5
        }

        // Pasada fina alrededor del mejor.
        let coarseBest = bestAngle
        angle = coarseBest - 0.5
        while angle <= coarseBest + 0.5 + 1e-9 {
            let s = score(angle)
            if s > bestScore {
                bestScore = s
                bestAngle = angle
            }
            angle += step
        }

        return bestAngle
    }
}
