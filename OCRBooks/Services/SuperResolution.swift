import CoreML
import CoreGraphics
import Foundation
import Accelerate

/// Variantes del modelo Real-ESRGAN convertidas a Core ML
/// (huggingface.co/VincentGOURBIN/RealESRGAN-CoreML, licencia BSD-3).
enum SRVariant: String, CaseIterable, Identifiable, Codable {
    case x4plus = "RealESRGAN-x4plus"
    case x4v3Denoise = "RealESRGAN-x4v3-denoise"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .x4plus: return "Máxima calidad (x4plus)"
        case .x4v3Denoise: return "Rápida + antirruido (x4v3)"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/VincentGOURBIN/RealESRGAN-CoreML/resolve/main/\(rawValue).mlpackage.zip")!
    }
}

enum SRState: Equatable {
    case notDownloaded
    case downloading
    case compiling
    case ready
    case failed(String)
}

enum SRError: Error, LocalizedError {
    case notReady
    case downloadFailed
    case unzipFailed
    case modelNotFoundInArchive
    case badModelIO
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .notReady: return "El modelo de IA no está cargado."
        case .downloadFailed: return "No se pudo descargar el modelo."
        case .unzipFailed: return "No se pudo descomprimir el modelo."
        case .modelNotFoundInArchive: return "El archivo descargado no contiene un .mlpackage."
        case .badModelIO: return "El modelo no tiene las entradas/salidas esperadas."
        case .inferenceFailed: return "Falló la inferencia del modelo."
        }
    }
}

/// Reconstrucción de trazos por IA: Real-ESRGAN ×4 ejecutado 100 % en el Mac
/// (Neural Engine/GPU vía Core ML). La página se procesa en mosaicos de
/// 256×256 con solapamiento para evitar costuras; la salida ×4 se integra a
/// ×2, doblando la resolución efectiva de la página con trazos reconstruidos
/// sin disparar la memoria del resto de la cadena.
final class SuperResolution {

    static let tile = 256
    static let overlap = 24
    static let modelScale = 4  // factor del modelo
    static let outputScale = 2 // factor con el que se integra al flujo

    private var model: MLModel?
    private var inputName = ""
    private var outputName = ""
    private var wantsFloat16Input = false
    private(set) var loadedVariant: SRVariant?

    var isReady: Bool { model != nil }

    // MARK: - Almacenamiento del modelo

    static func modelsDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("OCRBooks/Modelos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func compiledURL(for variant: SRVariant) -> URL {
        modelsDirectory().appendingPathComponent("\(variant.rawValue).mlmodelc", isDirectory: true)
    }

    /// Carga el modelo si ya está compilado en disco (sin red).
    @discardableResult
    func loadIfCached(variant: SRVariant) -> Bool {
        let url = Self.compiledURL(for: variant)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try load(compiledAt: url, variant: variant)
            return true
        } catch {
            return false
        }
    }

    /// Descarga (si hace falta), compila y carga el modelo. Informa del estado
    /// por el closure (puede llamarse desde cualquier hilo).
    func prepare(variant: SRVariant, status: @escaping (SRState) -> Void) async {
        if loadedVariant == variant, isReady {
            status(.ready)
            return
        }
        if loadIfCached(variant: variant) {
            status(.ready)
            return
        }
        do {
            status(.downloading)
            let (zipURL, response) = try await URLSession.shared.download(from: variant.downloadURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SRError.downloadFailed
            }

            status(.compiling)
            let workDir = Self.modelsDirectory()
                .appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            try Self.unzip(zipURL, to: workDir)
            guard let package = try FileManager.default
                .contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "mlpackage" })
            else { throw SRError.modelNotFoundInArchive }

            let compiled = try await MLModel.compileModel(at: package)
            let destination = Self.compiledURL(for: variant)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: compiled, to: destination)

            try load(compiledAt: destination, variant: variant)
            status(.ready)
        } catch {
            status(.failed(error.localizedDescription))
        }
    }

    private static func unzip(_ zip: URL, to dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SRError.unzipFailed }
    }

    private func load(compiledAt url: URL, variant: SRVariant) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all // Neural Engine + GPU + CPU
        let loaded = try MLModel(contentsOf: url, configuration: config)
        guard let input = loaded.modelDescription.inputDescriptionsByName.first,
              let output = loaded.modelDescription.outputDescriptionsByName.keys.first
        else { throw SRError.badModelIO }
        inputName = input.key
        outputName = output
        wantsFloat16Input = input.value.multiArrayConstraint?.dataType == .float16
        model = loaded
        loadedVariant = variant
    }

    // MARK: - Reconstrucción por mosaicos

    /// Devuelve la imagen reconstruida al doble de tamaño (resolución efectiva
    /// ×2 con trazos reparados por la red). `progress` recibe la fracción de
    /// mosaicos completados y puede llamarse desde el hilo de trabajo.
    func reconstruct(_ image: CGImage, progress: ((Double) -> Void)? = nil) throws -> CGImage {
        guard let model else { throw SRError.notReady }
        let w = image.width
        let h = image.height
        let T = Self.tile
        let ov = Self.overlap
        let step = T - 2 * ov
        let S = T * Self.modelScale // lado del mosaico de salida (1024)
        guard w >= T, h >= T else { return image } // página minúscula: sin IA

        // Fuente a memoria.
        guard let srcCtx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw SRError.inferenceFailed }
        srcCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let srcData = srcCtx.data else { throw SRError.inferenceFailed }
        let bprS = srcCtx.bytesPerRow
        let src = srcData.bindMemory(to: UInt8.self, capacity: bprS * h)

        // Destino ×2.
        let outW = w * Self.outputScale
        let outH = h * Self.outputScale
        guard let dstCtx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let dstData = dstCtx.data else { throw SRError.inferenceFailed }
        let bprD = dstCtx.bytesPerRow
        let dst = dstData.bindMemory(to: UInt8.self, capacity: bprD * outH)

        // Buffers reutilizables.
        let inArray = try MLMultiArray(
            shape: [1, 3, NSNumber(value: T), NSNumber(value: T)],
            dataType: wantsFloat16Input ? .float16 : .float32
        )
        var tileFloats = [Float](repeating: 0, count: 3 * T * T)
        var outFloats = [Float](repeating: 0, count: 3 * S * S)

        let tilesX = Int(ceil(Double(w - 2 * ov) / Double(step)))
        let tilesY = Int(ceil(Double(h - 2 * ov) / Double(step)))
        let totalTiles = max(1, tilesX * tilesY)
        var doneTiles = 0

        var ty = 0
        while ty < h {
            var tx = 0
            while tx < w {
                try autoreleasepool {
                    let ox = max(0, min(w - T, tx - ov))
                    let oy = max(0, min(h - T, ty - ov))

                    // Mosaico fuente → floats [0,1] por canal.
                    for c in 0..<3 {
                        let cBase = c * T * T
                        for y in 0..<T {
                            let row = (oy + y) * bprS
                            let fBase = cBase + y * T
                            for x in 0..<T {
                                tileFloats[fBase + x] = Float(src[row + (ox + x) * 4 + c]) / 255
                            }
                        }
                    }
                    try Self.fill(inArray, from: tileFloats, asFloat16: wantsFloat16Input)

                    // Inferencia.
                    let provider = try MLDictionaryFeatureProvider(
                        dictionary: [inputName: MLFeatureValue(multiArray: inArray)]
                    )
                    let result = try model.prediction(from: provider)
                    guard let outArray = result.featureValue(for: outputName)?.multiArrayValue else {
                        throw SRError.inferenceFailed
                    }
                    try Self.read(outArray, into: &outFloats)

                    // Núcleo del mosaico (sin solape) → destino ×2, integrando
                    // la salida ×4 por bloques de 2×2.
                    let coreX1 = min(tx + step, w)
                    let coreY1 = min(ty + step, h)
                    for Y2 in (ty * 2)..<(coreY1 * 2) {
                        let srY = (Y2 - oy * 2) * 2
                        let dstRow = Y2 * bprD
                        for X2 in (tx * 2)..<(coreX1 * 2) {
                            let srX = (X2 - ox * 2) * 2
                            let o = dstRow + X2 * 4
                            for c in 0..<3 {
                                let base = c * S * S + srY * S + srX
                                let v = (outFloats[base] + outFloats[base + 1]
                                    + outFloats[base + S] + outFloats[base + S + 1]) * 0.25
                                dst[o + c] = UInt8(max(0, min(255, v * 255)))
                            }
                            dst[o + 3] = 255
                        }
                    }
                }

                doneTiles += 1
                progress?(Double(doneTiles) / Double(totalTiles))
                tx += step
            }
            ty += step
        }

        guard let output = dstCtx.makeImage() else { throw SRError.inferenceFailed }
        return output
    }

    // MARK: - Conversión float32 ↔ float16 (portátil, vía Accelerate)

    private static func fill(_ array: MLMultiArray, from floats: [Float], asFloat16: Bool) throws {
        let count = floats.count
        if asFloat16 {
            try floats.withUnsafeBufferPointer { fp in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: fp.baseAddress!),
                    height: 1, width: vImagePixelCount(count), rowBytes: count * 4
                )
                var dstBuf = vImage_Buffer(
                    data: array.dataPointer,
                    height: 1, width: vImagePixelCount(count), rowBytes: count * 2
                )
                guard vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, 0) == kvImageNoError else {
                    throw SRError.inferenceFailed
                }
            }
        } else {
            floats.withUnsafeBufferPointer { fp in
                array.dataPointer.bindMemory(to: Float.self, capacity: count)
                    .update(from: fp.baseAddress!, count: count)
            }
        }
    }

    private static func read(_ array: MLMultiArray, into floats: inout [Float]) throws {
        let count = floats.count
        guard array.count >= count else { throw SRError.inferenceFailed }
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            floats.withUnsafeMutableBufferPointer { out in
                out.baseAddress!.update(from: p, count: count)
            }
        case .float16:
            try floats.withUnsafeMutableBufferPointer { out in
                var srcBuf = vImage_Buffer(
                    data: array.dataPointer,
                    height: 1, width: vImagePixelCount(count), rowBytes: count * 2
                )
                var dstBuf = vImage_Buffer(
                    data: out.baseAddress!,
                    height: 1, width: vImagePixelCount(count), rowBytes: count * 4
                )
                guard vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0) == kvImageNoError else {
                    throw SRError.inferenceFailed
                }
            }
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { floats[i] = Float(p[i]) }
        default:
            throw SRError.inferenceFailed
        }
    }
}
