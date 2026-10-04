import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case editor = "Editor"
    case comparison = "Comparar"
    case text = "Texto OCR"
    var id: String { rawValue }
}

struct PageDetailView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: DetailTab = .editor

    var body: some View {
        VStack(spacing: 0) {
            if let page = state.selectedPage {
                switch tab {
                case .editor:
                    EditorView(page: page, tab: $tab)
                case .comparison:
                    VStack(spacing: 0) {
                        tabPicker
                        Divider()
                        ComparisonContainer(page: page)
                    }
                case .text:
                    VStack(spacing: 0) {
                        tabPicker
                        Divider()
                        TextPanel(page: page)
                    }
                }
            } else {
                Text("Selecciona una página")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var tabPicker: some View {
        HStack {
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            Spacer()
        }
        .padding(10)
    }
}

/// Editor principal: imagen restaurada a resolución completa, zoom libre
/// (hasta 6400 %, píxel a píxel) y borrador manual de manchas.
struct EditorView: View {
    @EnvironmentObject private var state: AppState
    let page: PageItem
    @Binding var tab: DetailTab

    @State private var tool: EditorTool = .pan
    @State private var brushSize: CGFloat = 36
    @State private var fullImage: CGImage?
    @State private var loadedURL: URL?
    @State private var vectorPath: CGPath?
    @State private var loadedVectorURL: URL?
    @State private var vectorMode: VectorDisplayMode = .off
    @StateObject private var zoom = ZoomController()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: taskKey) {
            await loadFullImage()
            await loadVectors()
        }
    }

    /// Recargar cuando cambia la página o su imagen restaurada.
    private var taskKey: String {
        "\(page.id)-\(page.enhancedURL?.absoluteString ?? "none")-\(page.contoursURL?.absoluteString ?? "none")"
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Divider().frame(height: 18)

            Picker("", selection: $tool) {
                ForEach(EditorTool.allCases) { tool in
                    Label(tool.label, systemImage: tool.icon).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .disabled(displayImage == nil)

            if tool == .eraser {
                HStack(spacing: 6) {
                    Image(systemName: "circle")
                        .font(.system(size: 8))
                    Slider(value: $brushSize, in: 6...300)
                        .frame(width: 110)
                    Image(systemName: "circle")
                        .font(.system(size: 16))
                }
                .help("Tamaño del borrador (en píxeles de la imagen)")

                Button {
                    state.undoStroke(at: page.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(page.strokes.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .help("Deshacer último trazo (⌘Z)")

                Button {
                    state.clearStrokes(at: page.id)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(page.strokes.isEmpty)
                .help("Eliminar todos los trazos de esta página")
            }

            if vectorPath != nil {
                Picker("", selection: $vectorMode) {
                    ForEach(VectorDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .help("Vista previa de la recomposición vectorial: Vectorial muestra la página como quedará en el PDF; Contornos resalta en rojo lo que se vectorizó")
            }

            Spacer()

            // Controles de zoom (órdenes directas al visor, sin bindings).
            HStack(spacing: 6) {
                Button {
                    zoom.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Text("\(Int(zoom.magnification * 100)) %")
                    .font(.caption.monospacedDigit())
                    .frame(width: 52)
                Button {
                    zoom.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button("1:1") {
                    zoom.actualSize()
                }
                .help("Zoom 100 %: un punto por píxel de imagen")
                Button {
                    zoom.fit()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .help("Encajar la página en la ventana (también: doble clic)")
            }
            .disabled(displayImage == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var displayImage: CGImage? {
        fullImage ?? page.enhancedPreview
    }

    @ViewBuilder
    private var content: some View {
        if let image = displayImage {
            ZoomableCanvas(
                image: image,
                strokes: page.strokes,
                tool: tool,
                brushSize: brushSize,
                vectorPath: vectorPath,
                vectorColor: inkCGColor,
                vectorMode: vectorMode,
                controller: zoom,
                onStroke: { stroke in
                    state.addStroke(stroke, at: page.id)
                }
            )
        } else if case .processing(let step) = page.status {
            VStack(spacing: 12) {
                ProgressView()
                Text(step).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                if let thumbnail = page.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 420)
                        .shadow(radius: 4)
                }
                Text("Página sin restaurar")
                    .foregroundStyle(.secondary)
                Button {
                    state.processSelectedPage()
                } label: {
                    Label("Restaurar esta página", systemImage: "wand.and.stars")
                }
                .disabled(state.isWorking)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inkCGColor: CGColor {
        let ink = page.inkColor ?? InkColor(r: 0.05, g: 0.05, b: 0.05)
        return CGColor(red: ink.r, green: ink.g, blue: ink.b, alpha: 1)
    }

    private func loadFullImage() async {
        guard let url = page.enhancedURL else {
            fullImage = nil
            loadedURL = nil
            return
        }
        guard url != loadedURL else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageUtil.readImage(from: url)
        }.value
        fullImage = loaded
        loadedURL = url
    }

    /// Carga los contornos .vec y construye el CGPath en coordenadas del
    /// canvas (origen abajo-izquierda), todo fuera del hilo principal.
    private func loadVectors() async {
        guard let url = page.contoursURL else {
            vectorPath = nil
            loadedVectorURL = nil
            vectorMode = .off
            return
        }
        guard url != loadedVectorURL else { return }
        // Los contornos están en píxeles de la imagen a resolución completa;
        // solo tienen sentido sobre ella (nunca sobre la vista previa reducida).
        guard let full = fullImage else { return }
        let heightPx = CGFloat(full.height)
        let path = await Task.detached(priority: .userInitiated) { () -> CGPath? in
            guard let data = try? Data(contentsOf: url),
                  let loops = VectorTracer.decode(data),
                  !loops.isEmpty else { return nil }
            // Píxeles (fila 0 arriba) → coordenadas del canvas (y arriba).
            return VectorTracer.smoothPath(loops: loops) { point in
                CGPoint(x: point.x, y: heightPx - point.y)
            }
        }.value
        vectorPath = path
        loadedVectorURL = url
        if path == nil { vectorMode = .off }
    }
}

/// Contenedor del comparador antes/después (usa las vistas previas).
struct ComparisonContainer: View {
    let page: PageItem

    var body: some View {
        if let enhanced = page.enhancedPreview, let original = page.originalPreview {
            ComparisonView(original: original, enhanced: enhanced)
        } else {
            Text("Restaura la página para comparar el antes y el después.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Comparación antes/después con un divisor arrastrable.
struct ComparisonView: View {
    let original: CGImage
    let enhanced: CGImage
    @State private var fraction: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                imageView(enhanced, in: geo.size)

                imageView(original, in: geo.size)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: geo.size.width * fraction)
                            Spacer(minLength: 0)
                        }
                    )

                // Divisor.
                ZStack {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Text("Original")
                            Image(systemName: "arrow.left.and.right")
                            Text("Restaurada")
                        }
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxHeight: .infinity)
                .offset(x: geo.size.width * fraction - 1)
                .contentShape(Rectangle().inset(by: -8))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        fraction = min(0.98, max(0.02, value.location.x / geo.size.width))
                    }
            )
        }
        .padding(8)
    }

    private func imageView(_ image: CGImage, in size: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
    }
}
