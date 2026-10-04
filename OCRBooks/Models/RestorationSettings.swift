import Foundation

/// Modo de salida de la página restaurada.
enum OutputMode: String, CaseIterable, Identifiable, Codable {
    case color
    case grayscale
    case blackWhite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: return "Color restaurado"
        case .grayscale: return "Escala de grises"
        case .blackWhite: return "Blanco y negro (texto)"
        }
    }
}

/// Idiomas soportados por Vision para el reconocimiento.
enum OCRLanguage: String, CaseIterable, Identifiable, Codable {
    case spanish = "es-ES"
    case english = "en-US"
    case french = "fr-FR"
    case italian = "it-IT"
    case portuguese = "pt-PT"
    case german = "de-DE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spanish: return "Español"
        case .english: return "Inglés"
        case .french: return "Francés"
        case .italian: return "Italiano"
        case .portuguese: return "Portugués"
        case .german: return "Alemán"
        }
    }
}

/// Parámetros del motor de restauración. Todos ajustables desde el panel lateral.
struct RestorationSettings: Equatable, Codable {
    /// Resolución de reconstrucción de la página (píxeles por pulgada).
    var dpi: Double = 400

    /// Corrige la inclinación del escaneo (deskew).
    var deskew: Bool = true

    /// Aplana la iluminación y blanquea el fondo del papel
    /// (elimina sombras de encuadernación y amarilleo irregular).
    var flattenBackground: Bool = true

    /// Nivel de reducción de ruido/grano del escaneo (0 = ninguno).
    var noiseReduction: Double = 0.02

    /// Contraste final (1.0 = sin cambio).
    var contrast: Double = 1.15

    /// Intensidad del realce de nitidez de las letras.
    var sharpness: Double = 1.4

    /// Modo de salida.
    var mode: OutputMode = .grayscale

    /// Idioma principal del libro.
    var language: OCRLanguage = .spanish

    /// Idiomas que se pasan a Vision (el principal primero, inglés como apoyo).
    var recognitionLanguages: [String] {
        language == .english ? ["en-US"] : [language.rawValue, "en-US"]
    }
}
