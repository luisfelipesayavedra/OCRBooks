import CoreGraphics
import Foundation

/// Recomposición vectorial de la tinta (estilo potrace):
///
/// 1. **Marching squares** sobre la máscara de tinta: extrae los contornos
///    cerrados de cada letra con resolución de medio píxel, agujeros incluidos
///    (el relleno par-impar los respeta sin tratarlos aparte).
/// 2. **Simplificación Douglas-Peucker**: elimina el dentado de píxel
///    conservando la forma real del trazo.
/// 3. **Suavizado Bézier con detección de esquinas**: los tramos suaves se
///    convierten en curvas cuadráticas por los puntos medios; las esquinas
///    reales de la tipografía se conservan afiladas.
///
/// El resultado son las letras del libro como vectores: nítidas a cualquier
/// zoom o impresión, con la tipografía original intacta.
enum VectorTracer {

    // MARK: - Filtrado: solo componentes con tamaño de glifo

    /// Devuelve una máscara con los componentes aptos para vectorizar:
    /// los que tocan una zona de texto (si las hay) y no superan `maxArea`
    /// (las ilustraciones y grabados se quedan en ráster, donde conservan
    /// su tramado).
    static func textOnlyMask(
        _ mask: [UInt8], width: Int, height: Int,
        keepRects: [CGRect], maxArea: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: mask.count)
        var visited = [Bool](repeating: false, count: mask.count)
        var stack = [Int]()
        var component = [Int]()
        let total = width * height

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

            guard component.count <= maxArea else { continue }
            if !keepRects.isEmpty {
                let bbox = CGRect(
                    x: minX, y: minY,
                    width: maxX - minX + 1, height: maxY - minY + 1
                )
                guard keepRects.contains(where: { $0.intersects(bbox) }) else { continue }
            }
            for idx in component { out[idx] = 1 }
        }
        return out
    }

    // MARK: - Trazado (marching squares)

    /// Extrae los contornos cerrados de la máscara. Los puntos están en
    /// coordenadas de píxel de la imagen (fila 0 arriba), donde el centro del
    /// píxel (x, y) es (x+0.5, y+0.5).
    static func traceContours(
        mask: [UInt8], width: Int, height: Int, epsilon: CGFloat
    ) -> [[CGPoint]] {
        let keyStride = 2 * width + 6

        @inline(__always) func ink(_ x: Int, _ y: Int) -> Int {
            (x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x] == 1) ? 1 : 0
        }
        @inline(__always) func key(_ kx: Int, _ ky: Int) -> Int {
            (ky + 2) * keyStride + (kx + 2)
        }
        @inline(__always) func decode(_ k: Int) -> CGPoint {
            let kx = k % keyStride - 2
            let ky = k / keyStride - 2
            return CGPoint(x: CGFloat(kx) / 2, y: CGFloat(ky) / 2)
        }

        // 1. Segmentos por celda (celdas de -1 a width-1 para cerrar los
        // contornos que tocan el borde de la página).
        var segments: [(Int, Int)] = []
        for y in -1..<height {
            for x in -1..<width {
                let tl = ink(x, y), tr = ink(x + 1, y)
                let br = ink(x + 1, y + 1), bl = ink(x, y + 1)
                let idx = tl << 3 | tr << 2 | br << 1 | bl
                if idx == 0 || idx == 15 { continue }

                let top = key(2 * x + 2, 2 * y + 1)
                let right = key(2 * x + 3, 2 * y + 2)
                let bottom = key(2 * x + 2, 2 * y + 3)
                let left = key(2 * x + 1, 2 * y + 2)

                switch idx {
                case 1: segments.append((left, bottom))
                case 2: segments.append((bottom, right))
                case 3: segments.append((left, right))
                case 4: segments.append((top, right))
                case 5: segments.append((top, right)); segments.append((left, bottom))
                case 6: segments.append((top, bottom))
                case 7: segments.append((top, left))
                case 8: segments.append((top, left))
                case 9: segments.append((top, bottom))
                case 10: segments.append((top, left)); segments.append((bottom, right))
                case 11: segments.append((top, right))
                case 12: segments.append((left, right))
                case 13: segments.append((bottom, right))
                case 14: segments.append((left, bottom))
                default: break
                }
            }
        }
        guard !segments.isEmpty else { return [] }

        // 2. Encadenado: cada extremo pertenece exactamente a dos segmentos,
        // así que seguir el vecino no visitado recorre el contorno completo.
        var adjacency = [Int: [Int32]](minimumCapacity: segments.count)
        for (i, seg) in segments.enumerated() {
            adjacency[seg.0, default: []].append(Int32(i))
            adjacency[seg.1, default: []].append(Int32(i))
        }

        var visited = [Bool](repeating: false, count: segments.count)
        var loops: [[CGPoint]] = []

        for start in 0..<segments.count where !visited[start] {
            visited[start] = true
            let startKey = segments[start].0
            var current = segments[start].1
            var keys = [startKey, current]

            while current != startKey {
                guard let candidates = adjacency[current],
                      let nextIndex = candidates.first(where: { !visited[Int($0)] })
                else { break }
                let seg = segments[Int(nextIndex)]
                visited[Int(nextIndex)] = true
                current = seg.0 == current ? seg.1 : seg.0
                keys.append(current)
            }

            guard keys.count >= 4, keys.last == startKey else { continue }
            keys.removeLast()
            var loop = keys.map(decode)
            loop = simplifyClosed(loop, epsilon: epsilon)
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    // MARK: - Simplificación (Douglas-Peucker, contorno cerrado)

    static func simplifyClosed(_ loop: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard loop.count > 6 else { return loop }
        var pts = loop
        pts.append(loop[0])
        var keep = [Bool](repeating: false, count: pts.count)
        let mid = pts.count / 2
        keep[0] = true
        keep[mid] = true
        keep[pts.count - 1] = true
        dpMark(pts, 0, mid, &keep, epsilon)
        dpMark(pts, mid, pts.count - 1, &keep, epsilon)

        var out: [CGPoint] = []
        out.reserveCapacity(64)
        for i in 0..<(pts.count - 1) where keep[i] {
            out.append(pts[i])
        }
        return out
    }

    private static func dpMark(
        _ pts: [CGPoint], _ lo: Int, _ hi: Int,
        _ keep: inout [Bool], _ epsilon: CGFloat
    ) {
        var stack = [(lo, hi)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let pa = pts[a], pb = pts[b]
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let len = max(1e-6, (dx * dx + dy * dy).squareRoot())
            var maxDistance: CGFloat = -1
            var maxIndex = a
            for i in (a + 1)..<b {
                let d = abs((pts[i].x - pa.x) * dy - (pts[i].y - pa.y) * dx) / len
                if d > maxDistance {
                    maxDistance = d
                    maxIndex = i
                }
            }
            if maxDistance > epsilon {
                keep[maxIndex] = true
                stack.append((a, maxIndex))
                stack.append((maxIndex, b))
            }
        }
    }

    // MARK: - Construcción del CGPath suavizado

    /// Convierte los contornos en un camino: curvas cuadráticas por los puntos
    /// medios en tramos suaves, esquinas afiladas donde la tipografía las
    /// tiene. `transform` lleva cada punto de coordenadas de píxel (fila 0
    /// arriba) al sistema de destino.
    static func smoothPath(
        loops: [[CGPoint]],
        transform: (CGPoint) -> CGPoint
    ) -> CGPath {
        let path = CGMutablePath()
        for loop in loops {
            let n = loop.count
            guard n >= 3 else { continue }
            let p = loop.map(transform)

            func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }

            path.move(to: mid(p[n - 1], p[0]))
            for i in 0..<n {
                let prev = p[(i + n - 1) % n]
                let cur = p[i]
                let next = p[(i + 1) % n]
                let m = mid(cur, next)
                if isCorner(prev, cur, next) {
                    path.addLine(to: cur)
                    path.addLine(to: m)
                } else {
                    path.addQuadCurve(to: m, control: cur)
                }
            }
            path.closeSubpath()
        }
        return path
    }

    private static func isCorner(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        let v1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let l1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
        let l2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
        guard l1 > 0.0001, l2 > 0.0001 else { return true }
        let cosAngle = (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)
        return cosAngle < 0.55 // giro mayor de ~57° = esquina real
    }

    // MARK: - Serialización binaria (.vec)

    /// [UInt32 nLoops] { [UInt32 nPoints] [Float32 x, Float32 y] × n } …
    /// little-endian; compacto y rápido para páginas con miles de glifos.
    static func encode(_ loops: [[CGPoint]]) -> Data {
        var data = Data()
        appendU32(&data, UInt32(loops.count))
        for loop in loops {
            appendU32(&data, UInt32(loop.count))
            for point in loop {
                appendU32(&data, Float32(point.x).bitPattern)
                appendU32(&data, Float32(point.y).bitPattern)
            }
        }
        return data
    }

    static func decode(_ data: Data) -> [[CGPoint]]? {
        var offset = 0
        guard let loopCount = readU32(data, &offset) else { return nil }
        var loops: [[CGPoint]] = []
        loops.reserveCapacity(Int(loopCount))
        for _ in 0..<loopCount {
            guard let n = readU32(data, &offset) else { return nil }
            var loop: [CGPoint] = []
            loop.reserveCapacity(Int(n))
            for _ in 0..<n {
                guard let xb = readU32(data, &offset),
                      let yb = readU32(data, &offset) else { return nil }
                loop.append(CGPoint(
                    x: CGFloat(Float32(bitPattern: xb)),
                    y: CGFloat(Float32(bitPattern: yb))
                ))
            }
            loops.append(loop)
        }
        return loops
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readU32(_ data: Data, _ offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { buffer in
            data.copyBytes(to: buffer, from: offset..<(offset + 4))
        }
        offset += 4
        return UInt32(littleEndian: v)
    }
}
