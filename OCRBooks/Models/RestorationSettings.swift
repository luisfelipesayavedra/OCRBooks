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

/// Intensidad de la restauración.
enum RestorationStrength: String, CaseIterable, Identifiable, Codable {
    /// Solo realce (cadena Core Image ligera, sin reconstrucción).
    case light
    /// Reconstrucción profunda: binarización adaptativa Sauvola palabra por
    /// palabra, papel 100 % blanco, eliminación de manchas y motas.
    case deep
    /// Igual que la profunda pero con umbrales más duros, tinta más densa y
    /// despeckle más estricto.
    case maximum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Suave (solo realce)"
        case .deep: return "Profunda (reconstrucción)"
        case .maximum: return "Máxima (agresiva)"
        }
    }

    /// Parámetro k de Sauvola: más alto = umbral más exigente (más agresivo).
    var sauvolaK: Double {
        switch self {
        case .light: return 0
        case .deep: return 0.15
        case .maximum: return 0.22
        }
    }

    var despeckleMultiplier: Double {
        switch self {
        case .light: return 0
        case .deep: return 1.0
        case .maximum: return 2.5
        }
    }

    var extraInkGamma: Double {
        switch self {
        case .light: return 0
        case .deep: return 0.1
        case .maximum: return 0.45
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

    /// Intensidad de restauración. Por defecto, reconstrucción profunda.
    var strength: RestorationStrength = .deep

    /// Corrige la inclinación del escaneo (deskew).
    var deskew: Bool = true

    /// Aplana la iluminación y blanquea el fondo del papel
    /// (elimina sombras de encuadernación y amarilleo irregular).
    var flattenBackground: Bool = true

    /// Nivel de reducción de ruido/grano del escaneo (0 = ninguno).
    var noiseReduction: Double = 0.02

    /// Contraste / densidad de la tinta (1.0 = sin cambio).
    var contrast: Double = 1.15

    /// Intensidad del realce de nitidez de las letras.
    var sharpness: Double = 1.4

    /// Tamaño relativo de motas/puntos a eliminar (0 = no eliminar).
    var despeckleLevel: Double = 1.0

    /// Elimina por completo manchas y marcas que estén fuera de las zonas de
    /// texto detectadas por el OCR (limpieza guiada por el texto).
    var removeStainsOutsideText: Bool = true

    /// Conserva elementos grandes fuera del texto (grabados, ilustraciones,
    /// capitulares) aunque la limpieza de manchas esté activa.
    var protectIllustrations: Bool = true

    /// Modo de salida.
    var mode: OutputMode = .grayscale

    /// Idioma principal del libro.
    var language: OCRLanguage = .spanish

    /// Idiomas que se pasan a Vision (el principal primero, inglés como apoyo).
    var recognitionLanguages: [String] {
        language == .english ? ["en-US"] : [language.rawValue, "en-US"]
    }
}
