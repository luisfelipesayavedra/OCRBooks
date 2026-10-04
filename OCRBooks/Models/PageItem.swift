import CoreGraphics
import Foundation

/// Estado de una página dentro del flujo de trabajo.
enum PageStatus: Equatable {
    case pending
    case processing(String)
    case done
    case failed(String)

    var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }
}

/// Una línea de texto reconocida por Vision.
/// `bbox` está en coordenadas normalizadas (0–1) con origen abajo-izquierda,
/// el mismo sistema que usa PDF, lo que simplifica la exportación.
struct RecognizedLine: Codable, Equatable {
    let text: String
    let confidence: Float
    let bbox: CGRect
}

/// Color medio de la tinta de una página, usado para rellenar los contornos
/// vectoriales con el mismo tono que el trazo impreso.
struct InkColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
}

/// Un trazo del borrador manual, en coordenadas de píxel de la imagen
/// restaurada (origen abajo-izquierda, como CoreGraphics y PDF). Se aplica
/// como pintura blanca con extremos redondeados, tanto en pantalla como al
/// exportar el PDF final.
struct EraserStroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var points: [CGPoint]
    var width: CGFloat
}

/// Una página del libro. Las imágenes a resolución completa viven en disco
/// (carpeta de caché) para que libros grandes no agoten la memoria; en memoria
/// solo se conservan miniaturas y vistas previas.
struct PageItem: Identifiable {
    let id: Int // índice de página, base 0

    var status: PageStatus = .pending
    var thumbnail: CGImage?
    var originalPreview: CGImage?
    var enhancedPreview: CGImage?
    var enhancedURL: URL? // PNG a resolución completa en disco
    var lines: [RecognizedLine] = []
    var skewAngle: Double = 0
    var strokes: [EraserStroke] = [] // borrador manual
    var contoursURL: URL? // contornos vectoriales de la tinta (.vec en disco)
    var inkColor: InkColor?

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var statusLabel: String {
        switch status {
        case .pending: return "Pendiente"
        case .processing(let step): return step
        case .done: return "Restaurada"
        case .failed(let message): return "Error: \(message)"
        }
    }
}
