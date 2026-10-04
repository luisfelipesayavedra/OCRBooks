import Vision
import CoreGraphics

enum OCRService {

    /// Reconoce el texto de la página con el modo más preciso de Vision.
    /// Se ejecuta sobre la imagen ya restaurada: el aplanado de fondo y la
    /// nitidez recuperada mejoran notablemente la tasa de acierto en
    /// tipografías antiguas.
    static func recognize(in image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        var lines: [RecognizedLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { return nil }
            return RecognizedLine(
                text: candidate.string,
                confidence: candidate.confidence,
                bbox: observation.boundingBox
            )
        }

        // Orden de lectura: de arriba hacia abajo y de izquierda a derecha.
        lines.sort { a, b in
            if abs(a.bbox.midY - b.bbox.midY) > min(a.bbox.height, b.bbox.height) * 0.6 {
                return a.bbox.midY > b.bbox.midY
            }
            return a.bbox.minX < b.bbox.minX
        }
        return lines
    }
}
