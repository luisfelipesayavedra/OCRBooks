import SwiftUI
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers

/// Estado central de la aplicación. Orquesta el flujo completo:
/// abrir PDF → procesar página por página → exportar PDF restaurado con OCR.
@MainActor
final class AppState: ObservableObject {

    @Published var pages: [PageItem] = []
    @Published var selection: Int?
    @Published var settings = RestorationSettings()
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var progressLabel = ""
    @Published var errorMessage: String?
    @Published var documentURL: URL?

    private var pdf: PDFDocument?
    private var cacheDir: URL?
    private var batchTask: Task<Void, Never>?

    var hasDocument: Bool { pdf != nil }

    var selectedPage: PageItem? {
        guard let selection, pages.indices.contains(selection) else { return nil }
        return pages[selection]
    }

    // MARK: - Abrir documento

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Elige el PDF del libro escaneado"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        batchTask?.cancel()
        guard let document = PDFDocument(url: url) else {
            errorMessage = "No se pudo abrir el PDF."
            return
        }
        pdf = document
        documentURL = url
        errorMessage = nil
        progress = 0
        progressLabel = ""

        // Caché en disco para las páginas restauradas a resolución completa.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("OCRBooks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = dir

        pages = (0..<document.pageCount).map { PageItem(id: $0) }
        selection = pages.isEmpty ? nil : 0
        loadThumbnails()
    }

    private func loadThumbnails() {
        guard let pdf else { return }
        let count = pdf.pageCount
        Task.detached(priority: .utility) { [weak self] in
            for index in 0..<count {
                guard let self else { return }
                guard let page = await self.page(at: index) else { continue }
                let thumb = PDFRenderer.thumbnail(page: page, maxDimension: 220)
                await MainActor.run {
                    guard self.pages.indices.contains(index) else { return }
                    self.pages[index].thumbnail = thumb
                }
            }
        }
    }

    private func page(at index: Int) -> PDFPage? {
        pdf?.page(at: index)
    }

    // MARK: - Procesamiento

    func processSelectedPage() {
        guard let selection else { return }
        Task { await processPage(selection) }
    }

    func processAllPages() {
        guard !isWorking else { return }
        isWorking = true
        progress = 0
        batchTask = Task { [weak self] in
            guard let self else { return }
            let total = await self.pages.count
            for index in 0..<total {
                if Task.isCancelled { break }
                let alreadyDone = await MainActor.run { self.pages[index].status == .done }
                if !alreadyDone {
                    await self.processPage(index)
                }
                await MainActor.run {
                    self.progress = Double(index + 1) / Double(total)
                    self.progressLabel = "Página \(index + 1) de \(total)"
                }
            }
            await MainActor.run {
                self.isWorking = false
                self.progressLabel = ""
            }
        }
    }

    func cancelBatch() {
        batchTask?.cancel()
        isWorking = false
        progressLabel = ""
    }

    /// Procesa una página completa: render a DPI alto → deskew → restauración
    /// → OCR → persistencia en disco. Cada página se trabaja de forma íntegra
    /// e independiente, priorizando la calidad de reconstrucción.
    func processPage(_ index: Int) async {
        guard pages.indices.contains(index),
              !pages[index].status.isProcessing,
              let page = page(at: index),
              let cacheDir else { return }

        let currentSettings = settings
        let stepLabel = currentSettings.strength == .light
            ? "Realzando a \(Int(currentSettings.dpi)) ppp…"
            : "Reconstrucción profunda a \(Int(currentSettings.dpi)) ppp…"
        pages[index].status = .processing(stepLabel)

        let result: Result<ProcessedPage, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let original = try PDFRenderer.render(page: page, dpi: currentSettings.dpi)

                let angle = currentSettings.deskew ? SkewDetector.detectAngle(in: original) : 0
                let output = try RestorationEngine.enhance(
                    original,
                    skewAngle: angle,
                    settings: currentSettings
                )
                let enhanced = output.image

                let lines = try OCRService.recognize(
                    in: enhanced,
                    languages: currentSettings.recognitionLanguages
                )

                let fileURL = cacheDir.appendingPathComponent(
                    String(format: "page-%04d.png", index)
                )
                try ImageUtil.writePNG(enhanced, to: fileURL)

                // Contornos vectoriales de la tinta, serializados en disco.
                var contoursURL: URL?
                if let data = output.contoursData {
                    let vecURL = cacheDir.appendingPathComponent(
                        String(format: "page-%04d.vec", index)
                    )
                    try data.write(to: vecURL)
                    contoursURL = vecURL
                }

                let processed = ProcessedPage(
                    originalPreview: ImageUtil.scaled(original, maxDimension: 1800),
                    enhancedPreview: ImageUtil.scaled(enhanced, maxDimension: 1800),
                    enhancedURL: fileURL,
                    lines: lines,
                    skewAngle: angle,
                    contoursURL: contoursURL,
                    inkColor: output.inkColor
                )
                return .success(processed)
            } catch {
                return .failure(error)
            }
        }.value

        guard pages.indices.contains(index) else { return }
        switch result {
        case .success(let processed):
            pages[index].originalPreview = processed.originalPreview
            pages[index].enhancedPreview = processed.enhancedPreview
            pages[index].enhancedURL = processed.enhancedURL
            pages[index].lines = processed.lines
            pages[index].skewAngle = processed.skewAngle
            pages[index].strokes = [] // la imagen cambió: los trazos antiguos ya no aplican
            pages[index].contoursURL = processed.contoursURL
            pages[index].inkColor = processed.inkColor
            pages[index].status = .done
        case .failure(let error):
            pages[index].status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Borrador manual

    func addStroke(_ stroke: EraserStroke, at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages[index].strokes.append(stroke)
    }

    func undoStroke(at index: Int) {
        guard pages.indices.contains(index), !pages[index].strokes.isEmpty else { return }
        pages[index].strokes.removeLast()
    }

    func clearStrokes(at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages[index].strokes.removeAll()
    }

    // MARK: - Exportar

    func presentExportPanel() {
        guard hasDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (documentURL?
            .deletingPathExtension()
            .lastPathComponent ?? "libro") + "-restaurado.pdf"
        panel.message = "Guardar el PDF restaurado con OCR"
        if panel.runModal() == .OK, let url = panel.url {
            exportDocument(to: url)
        }
    }

    private func exportDocument(to url: URL) {
        guard !isWorking else { return }
        isWorking = true
        progress = 0
        batchTask = Task { [weak self] in
            guard let self else { return }

            // Asegurar que todas las páginas estén restauradas antes de exportar.
            let total = await self.pages.count
            for index in 0..<total {
                if Task.isCancelled { break }
                let alreadyDone = await MainActor.run { self.pages[index].status == .done }
                if !alreadyDone {
                    await self.processPage(index)
                }
                await MainActor.run {
                    self.progress = Double(index + 1) / Double(total + 1)
                    self.progressLabel = "Página \(index + 1) de \(total)"
                }
            }
            if Task.isCancelled {
                await MainActor.run { self.isWorking = false; self.progressLabel = "" }
                return
            }

            let (exportPages, dpi): ([PDFExporter.ExportPage], Double) = await MainActor.run {
                let items = self.pages.compactMap { page -> PDFExporter.ExportPage? in
                    guard let imageURL = page.enhancedURL else { return nil }
                    return PDFExporter.ExportPage(
                        index: page.id,
                        imageURL: imageURL,
                        lines: page.lines,
                        strokes: page.strokes,
                        contoursURL: page.contoursURL,
                        inkColor: page.inkColor
                    )
                }
                self.progressLabel = "Escribiendo PDF…"
                return (items, self.settings.dpi)
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try PDFExporter.export(pages: exportPages, dpi: dpi, to: url)
                }.value
                await MainActor.run {
                    self.progress = 1
                    self.progressLabel = "Exportado: \(url.lastPathComponent)"
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isWorking = false
                    self.progressLabel = ""
                }
            }
        }
    }
}

private struct ProcessedPage {
    let originalPreview: CGImage
    let enhancedPreview: CGImage
    let enhancedURL: URL
    let lines: [RecognizedLine]
    let skewAngle: Double
    let contoursURL: URL?
    let inkColor: InkColor?
}
