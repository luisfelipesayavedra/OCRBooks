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
    @Published var srState: SRState = .notDownloaded
    @Published var inpaintingPages: Set<Int> = []

    /// Etapa actual y hora de inicio de cada página en proceso: alimentan el
    /// cronómetro visible que confirma que el proceso sigue vivo.
    private var processingStages: [Int: (stage: String, start: Date)] = [:]

    let superRes = SuperResolution()

    private var pdf: PDFDocument?
    private var cacheDir: URL?
    private var batchTask: Task<Void, Never>?

    init() {
        // Si el modelo de IA ya está compilado en disco, cargarlo sin red.
        if superRes.loadIfCached(variant: settings.aiVariant) {
            srState = .ready
        }
    }

    // MARK: - Modelo de IA (Real-ESRGAN)

    /// Descarga/compila/carga la variante elegida del modelo.
    func prepareAIModel() {
        let variant = settings.aiVariant
        srState = .downloading
        Task.detached(priority: .userInitiated) { [superRes, weak self] in
            await superRes.prepare(variant: variant) { state in
                Task { @MainActor [weak self] in
                    self?.srState = state
                    if case .failed = state {
                        self?.settings.aiReconstruction = false
                    }
                }
            }
        }
    }

    /// Al cambiar de variante en el panel: usar la caché si existe.
    func aiVariantChanged() {
        if superRes.loadedVariant == settings.aiVariant, superRes.isReady {
            srState = .ready
        } else if superRes.loadIfCached(variant: settings.aiVariant) {
            srState = .ready
        } else {
            srState = .notDownloaded
            settings.aiReconstruction = false
        }
    }

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
        processingStages[index] = ("Renderizando a \(Int(currentSettings.dpi)) ppp…", Date())
        pages[index].status = .processing("Renderizando a \(Int(currentSettings.dpi)) ppp…")

        // Cronómetro: refresca el estado cada segundo mientras se procesa,
        // para que siempre se vea que el proceso sigue vivo.
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.refreshProcessingStatus(index) }
            }
        }
        defer {
            ticker.cancel()
            processingStages[index] = nil
        }

        let resolver: SuperResolution? =
            (currentSettings.aiReconstruction && superRes.isReady) ? superRes : nil

        // Las etapas llegan desde hilos de trabajo: se reenvían al MainActor.
        let stageReporter: (String) -> Void = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.updateStage(index, text)
            }
        }

        let result: Result<ProcessedPage, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let original = try PDFRenderer.render(page: page, dpi: currentSettings.dpi)

                let angle = currentSettings.deskew ? SkewDetector.detectAngle(in: original) : 0
                var lastShown = -1
                let output = try RestorationEngine.enhance(
                    original,
                    skewAngle: angle,
                    settings: currentSettings,
                    superResolver: resolver,
                    srProgress: { fraction in
                        let percent = Int(fraction * 100)
                        guard percent != lastShown, percent % 2 == 0 else { return }
                        lastShown = percent
                        stageReporter("IA reconstruyendo trazos… \(percent) %")
                    },
                    stage: stageReporter
                )
                let enhanced = output.image

                stageReporter("Reconociendo texto (OCR final)…")
                let lines = try OCRService.recognize(
                    in: enhanced,
                    languages: currentSettings.recognitionLanguages
                )

                stageReporter("Guardando página restaurada…")
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
                    inkColor: output.inkColor,
                    renderDPI: currentSettings.dpi * output.scaleFactor
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
            pages[index].renderDPI = processed.renderDPI
            pages[index].status = .done
        case .failure(let error):
            pages[index].status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Progreso con cronómetro

    /// Actualiza la etapa visible de una página y refresca su estado con el
    /// tiempo transcurrido ("Binarizando… · 1:42"). El cronómetro avanza cada
    /// segundo aunque la etapa no cambie: si el reloj corre, el proceso vive.
    private func updateStage(_ index: Int, _ text: String) {
        guard let entry = processingStages[index] else { return }
        processingStages[index] = (text, entry.start)
        refreshProcessingStatus(index)
    }

    private func refreshProcessingStatus(_ index: Int) {
        guard pages.indices.contains(index),
              pages[index].status.isProcessing,
              let entry = processingStages[index] else { return }
        let elapsed = Int(Date().timeIntervalSince(entry.start))
        let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        pages[index].status = .processing("\(entry.stage) · \(clock)")
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

    /// Borrador en modo "Reconstruir": rellena la zona del trazo con el papel
    /// circundante (inpainting OpenCV) y guarda el resultado en la imagen de
    /// la página. Es destructivo: deshacer = reprocesar la página.
    func applyInpaintStroke(_ stroke: EraserStroke, at index: Int) async {
        guard pages.indices.contains(index),
              let url = pages[index].enhancedURL,
              !inpaintingPages.contains(index) else { return }
        inpaintingPages.insert(index)
        defer { inpaintingPages.remove(index) }

        let preview: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let full = ImageUtil.readImage(from: url),
                  let patched = Inpainter.applyStroke(stroke, to: full) else { return nil }
            do {
                try ImageUtil.writePNG(patched, to: url)
            } catch {
                return nil
            }
            return ImageUtil.scaled(patched, maxDimension: 1800)
        }.value

        guard pages.indices.contains(index) else { return }
        if let preview {
            pages[index].enhancedPreview = preview
            pages[index].editVersion += 1 // fuerza la recarga del editor
        } else {
            errorMessage = "No se pudo reconstruir esa zona (inpainting)."
        }
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

            let exportPages: [PDFExporter.ExportPage] = await MainActor.run {
                let fallbackDPI = self.settings.dpi
                let items = self.pages.compactMap { page -> PDFExporter.ExportPage? in
                    guard let imageURL = page.enhancedURL else { return nil }
                    return PDFExporter.ExportPage(
                        index: page.id,
                        imageURL: imageURL,
                        lines: page.lines,
                        strokes: page.strokes,
                        contoursURL: page.contoursURL,
                        inkColor: page.inkColor,
                        dpi: page.renderDPI > 0 ? page.renderDPI : fallbackDPI
                    )
                }
                self.progressLabel = "Escribiendo PDF…"
                return items
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try PDFExporter.export(pages: exportPages, to: url)
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
    let renderDPI: Double
}
