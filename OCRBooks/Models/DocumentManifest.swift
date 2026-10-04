import Foundation

/// Registro persistente de una página restaurada. Junto con los PNG/.vec en
/// disco permite cerrar la app (o que se vaya la luz) y reanudar el libro
/// exactamente donde quedó: imprescindible en corridas de días o semanas.
struct PageRecord: Codable {
    var index: Int
    var done: Bool
    var skewAngle: Double
    var renderDPI: Double
    var lines: [RecognizedLine]
    var inkColor: InkColor?
    var strokes: [EraserStroke]
    var hasContours: Bool
    var editVersion: Int
}

/// Manifiesto del documento, guardado de forma atómica tras cada página.
struct DocumentManifest: Codable {
    var version: Int = 1
    var pdfPath: String
    var pageCount: Int
    var pages: [PageRecord]

    static func load(from url: URL) -> DocumentManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DocumentManifest.self, from: data)
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
