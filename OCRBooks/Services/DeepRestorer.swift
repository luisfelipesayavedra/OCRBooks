import CoreGraphics
import Foundation

enum DeepRestorerError: Error {
    case contextCreationFailed
}

/// Restauración profunda en CPU. A diferencia de los filtros globales de
/// Core Image, aquí se decide píxel a píxel qué es tinta y qué es papel:
///
/// - **Aplanado de iluminación**: se estima el fondo (papel) con un desenfoque
///   de caja multi-pasada por canal y se normaliza cada píxel contra él.
///   Sombra de encuadernación, amarilleo y manchas de luz desaparecen.
/// - **Binarización adaptativa de Sauvola**: el umbral tinta/papel se calcula
///   localmente (media y desviación en una ventana alrededor de cada píxel),
///   el equivalente a decidir "palabra por palabra" qué trazos son reales.
/// - **Despeckle por componentes conexas**: cada mancha, mota o punto del
///   escaneo se identifica como un grupo de píxeles; se elimina según su
///   tamaño y según esté o no dentro de una zona de texto detectada por OCR.
/// - **Composición final**: papel blanco puro; la tinta conserva el detalle
///   del trazo original (antialiasing incluido) con densidad ajustable.
enum DeepRestorer {

    // MARK: - Buffer RGBA

    /// Contexto bitmap RGBA de 8 bits con la imagen dibujada; la memoria se
    /// manipula directamente (fila 0 = parte superior de la imagen).
    static func rgbaContext(from image: CGImage) throws -> CGContext {
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw DeepRestorerError.contextCreationFailed }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    // MARK: - Aplanado de iluminación

    /// Normaliza cada canal contra una estimación del fondo (papel), calculada
    /// con submuestreo 8× + desenfoque de caja multi-pasada + interpolación
    /// bilineal. El papel queda blanco uniforme sin tocar el detalle de la tinta.
    static func flattenIllumination(in ctx: CGContext, dpi: Double) {
        guard let data = ctx.data else { return }
        let w = ctx.width
        let h = ctx.height
        let bpr = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)

        let block = 8
        let sw = max(1, (w + block - 1) / block)
        let sh = max(1, (h + block - 1) / block)

        // Fondo reducido por canal (media de bloques, sesgada hacia lo claro
        // tomando el máximo entre media y percentil alto aproximado).
        var small = [[Float]](repeating: [Float](repeating: 0, count: sw * sh), count: 3)
        for sy in 0..<sh {
            for sx in 0..<sw {
                var sums = [Float](repeating: 0, count: 3)
                var maxs = [Float](repeating: 0, count: 3)
                var count: Float = 0
                let y0 = sy * block, y1 = min(h, y0 + block)
                let x0 = sx * block, x1 = min(w, x0 + block)
                for y in y0..<y1 {
                    let row = y * bpr
                    for x in x0..<x1 {
                        let o = row + x * 4
                        for c in 0..<3 {
                            let v = Float(px[o + c])
                            sums[c] += v
                            if v > maxs[c] { maxs[c] = v }
                        }
                        count += 1
                    }
                }
                let idx = sy * sw + sx
                for c in 0..<3 {
                    // El fondo es lo claro del bloque: mezclar media y máximo
                    // evita que la tinta oscurezca la estimación del papel.
                    small[c][idx] = 0.35 * (sums[c] / max(1, count)) + 0.65 * maxs[c]
                }
            }
        }

        let radius = max(3, Int(dpi / 64.0))
        for c in 0..<3 {
            small[c] = boxFiltered(small[c], width: sw, height: sh, radius: radius)
            small[c] = boxFiltered(small[c], width: sw, height: sh, radius: radius)
            small[c] = boxFiltered(small[c], width: sw, height: sh, radius: radius)
        }

        // Normalización bilineal por píxel: out = in / fondo * 250.
        let fb = Float(block)
        for y in 0..<h {
            let fy = (Float(y) + 0.5) / fb - 0.5
            let sy0 = max(0, min(sh - 1, Int(floor(fy))))
            let sy1 = min(sh - 1, sy0 + 1)
            let wy = max(0, min(1, fy - Float(sy0)))
            let row = y * bpr
            for x in 0..<w {
                let fx = (Float(x) + 0.5) / fb - 0.5
                let sx0 = max(0, min(sw - 1, Int(floor(fx))))
                let sx1 = min(sw - 1, sx0 + 1)
                let wx = max(0, min(1, fx - Float(sx0)))
                let o = row + x * 4
                for c in 0..<3 {
                    let s = small[c]
                    let top = s[sy0 * sw + sx0] * (1 - wx) + s[sy0 * sw + sx1] * wx
                    let bottom = s[sy1 * sw + sx0] * (1 - wx) + s[sy1 * sw + sx1] * wx
                    let bg = max(8, top * (1 - wy) + bottom * wy)
                    let v = Float(px[o + c]) / bg * 250
                    px[o + c] = UInt8(max(0, min(255, v)))
                }
            }
        }
    }

    /// Desenfoque de caja separable con acumulador en Double (sin deriva).
    static func boxFiltered(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0, width > 0, height > 0 else { return src }
        var tmp = [Float](repeating: 0, count: src.count)
        var dst = [Float](repeating: 0, count: src.count)
        let span = Float(2 * radius + 1)

        // Horizontal
        for y in 0..<height {
            let row = y * width
            var sum: Double = 0
            for x in -radius...radius {
                sum += Double(src[row + min(width - 1, max(0, x))])
            }
            for x in 0..<width {
                tmp[row + x] = Float(sum) / span
                let add = src[row + min(width - 1, x + radius + 1)]
                let sub = src[row + max(0, x - radius)]
                sum += Double(add) - Double(sub)
            }
        }
        // Vertical
        for x in 0..<width {
            var sum: Double = 0
            for y in -radius...radius {
                sum += Double(tmp[min(height - 1, max(0, y)) * width + x])
            }
            for y in 0..<height {
                dst[y * width + x] = Float(sum) / span
                let add = tmp[min(height - 1, y + radius + 1) * width + x]
                let sub = tmp[max(0, y - radius) * width + x]
                sum += Double(add) - Double(sub)
            }
        }
        return dst
    }

    // MARK: - Luminancia

    static func grayArray(from ctx: CGContext) -> [Float] {
        guard let data = ctx.data else { return [] }
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        var gray = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * bpr
            let grow = y * w
            for x in 0..<w {
                let o = row + x * 4
                gray[grow + x] = 0.299 * Float(px[o]) + 0.587 * Float(px[o + 1]) + 0.114 * Float(px[o + 2])
            }
        }
        return gray
    }

    // MARK: - Binarización adaptativa (Sauvola)

    /// Máscara de tinta (1 = tinta) con umbral local de Sauvola:
    /// T = m · (1 + k · (s/R − 1)), ventana proporcional al DPI.
    static func sauvolaMask(
        gray: [Float], width: Int, height: Int,
        window: Int, k: Double
    ) -> [UInt8] {
        let radius = max(8, window / 2)
        var graySq = [Float](repeating: 0, count: gray.count)
        for i in 0..<gray.count { graySq[i] = gray[i] * gray[i] }

        let mean = boxFiltered(gray, width: width, height: height, radius: radius)
        let meanSq = boxFiltered(graySq, width: width, height: height, radius: radius)

        let kf = Float(k)
        let invR: Float = 1.0 / 128.0
        var mask = [UInt8](repeating: 0, count: gray.count)
        for i in 0..<gray.count {
            let m = mean[i]
            let variance = max(0, meanSq[i] - m * m)
            let s = variance.squareRoot()
            let threshold = m * (1 + kf * (s * invR - 1))
            mask[i] = gray[i] < threshold ? 1 : 0
        }
        return mask
    }

    // MARK: - Despeckle por componentes conexas

    /// Elimina manchas y motas:
    /// - componentes con área menor que `minSpeck` se borran siempre
    ///   (motas de polvo, puntos del escáner), estén donde estén;
    /// - si `removeOutsideText` está activo, cualquier componente que no toque
    ///   una zona de texto (`keepRects`, en píxeles con fila 0 arriba) se borra
    ///   salvo que supere `protectArea` (ilustraciones y grabados).
    static func despeckle(
        mask: inout [UInt8],
        width: Int, height: Int,
        keepRects: [CGRect],
        minSpeck: Int,
        removeOutsideText: Bool,
        protectArea: Int
    ) {
        guard minSpeck > 0 || removeOutsideText else { return }
        let total = width * height
        var visited = [Bool](repeating: false, count: total)
        var stack = [Int]()
        stack.reserveCapacity(4096)
        var component = [Int]()
        component.reserveCapacity(4096)

        for start in 0..<total {
            guard mask[start] == 1, !visited[start] else { continue }

            component.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min

            while let idx = stack.popLast() {
                component.append(idx)
                let y = idx / width
                let x = idx % width
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }

                // Vecindad 8-conexa.
                let y0 = max(0, y - 1), y1 = min(height - 1, y + 1)
                let x0 = max(0, x - 1), x1 = min(width - 1, x + 1)
                for ny in y0...y1 {
                    let nrow = ny * width
                    for nx in x0...x1 {
                        let n = nrow + nx
                        if mask[n] == 1 && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }

            let area = component.count
            var remove = false

            if area < minSpeck {
                remove = true
            } else if removeOutsideText && !keepRects.isEmpty {
                let bbox = CGRect(
                    x: minX, y: minY,
                    width: maxX - minX + 1, height: maxY - minY + 1
                )
                let touchesText = keepRects.contains { $0.intersects(bbox) }
                if !touchesText && area < protectArea {
                    remove = true
                }
            }

            if remove {
                for idx in component { mask[idx] = 0 }
            }
        }
    }

    /// Dilata la máscara 1 píxel (8-conexa) para conservar el borde
    /// antialiasado de los trazos originales.
    static func dilated(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = mask
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] == 1 {
                let y0 = max(0, y - 1), y1 = min(height - 1, y + 1)
                let x0 = max(0, x - 1), x1 = min(width - 1, x + 1)
                for ny in y0...y1 {
                    let nrow = ny * width
                    for nx in x0...x1 {
                        out[nrow + nx] = 1
                    }
                }
            }
        }
        return out
    }

    // MARK: - Composición final

    /// Escribe el resultado sobre el contexto: papel blanco puro y tinta con
    /// la densidad pedida. En gris/color la tinta conserva los valores del
    /// trazo original (gamma aplicada); en blanco y negro es tinta pura.
    static func compose(
        in ctx: CGContext,
        gray: [Float],
        mask: [UInt8],
        mode: OutputMode,
        inkGamma: Double
    ) {
        guard let data = ctx.data else { return }
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        let gamma = Float(max(0.3, inkGamma))

        for y in 0..<h {
            let row = y * bpr
            let grow = y * w
            for x in 0..<w {
                let o = row + x * 4
                if mask[grow + x] == 0 {
                    px[o] = 255; px[o + 1] = 255; px[o + 2] = 255
                } else {
                    switch mode {
                    case .blackWhite:
                        px[o] = 0; px[o + 1] = 0; px[o + 2] = 0
                    case .grayscale:
                        let v = powf(min(1, max(0, gray[grow + x] / 255)), gamma) * 255
                        let u = UInt8(max(0, min(255, v)))
                        px[o] = u; px[o + 1] = u; px[o + 2] = u
                    case .color:
                        for c in 0..<3 {
                            let v = powf(min(1, max(0, Float(px[o + c]) / 255)), gamma) * 255
                            px[o + c] = UInt8(max(0, min(255, v)))
                        }
                    }
                }
                px[o + 3] = 255
            }
        }
    }
}
