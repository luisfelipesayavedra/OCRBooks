import SwiftUI
import AppKit
import Combine

enum EditorTool: String, CaseIterable, Identifiable {
    case pan
    case eraser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pan: return "Mover"
        case .eraser: return "Borrador"
        }
    }

    var icon: String {
        switch self {
        case .pan: return "hand.draw"
        case .eraser: return "eraser"
        }
    }
}

/// Cómo mostrar la capa vectorial en el editor.
enum VectorDisplayMode: String, CaseIterable, Identifiable {
    case off
    case fill
    case outline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Ráster"
        case .fill: return "Vectorial"
        case .outline: return "Contornos"
        }
    }
}

/// Controlador de zoom: la UI manda órdenes directas al NSScrollView y solo
/// LEE la magnificación para la etiqueta. Un único sentido de datos — nada de
/// bindings bidireccionales que entren en bucle con el scroll (la causa del
/// visor atascado). Todas sus llamadas llegan desde la UI (hilo principal).
final class ZoomController: ObservableObject {
    @Published private(set) var magnification: CGFloat = 1

    weak var scrollView: NSScrollView?

    func attach(_ scroll: NSScrollView) {
        scrollView = scroll
        refreshLabel()
    }

    func refreshLabel() {
        guard let scroll = scrollView else { return }
        let m = scroll.magnification
        if abs(m - magnification) > 0.0005 {
            magnification = m
        }
    }

    private func apply(_ value: CGFloat) {
        guard let scroll = scrollView else { return }
        let clamped = min(scroll.maxMagnification, max(scroll.minMagnification, value))
        let center = CGPoint(
            x: scroll.contentView.bounds.midX,
            y: scroll.contentView.bounds.midY
        )
        scroll.setMagnification(clamped, centeredAt: center)
        refreshLabel()
    }

    func zoomIn() { apply((scrollView?.magnification ?? 1) * 1.4) }
    func zoomOut() { apply((scrollView?.magnification ?? 1) / 1.4) }
    func actualSize() { apply(1) }

    func fit() {
        guard let scroll = scrollView,
              let doc = scroll.documentView,
              doc.frame.width > 1, doc.frame.height > 1 else { return }
        scroll.magnify(toFit: doc.frame)
        refreshLabel()
    }

    /// Doble clic: alternar entre encaje y 100 %.
    func toggleFitActual() {
        guard let scroll = scrollView else { return }
        if scroll.magnification < 0.97 {
            actualSize()
        } else {
            fit()
        }
    }
}

/// Vista AppKit que dibuja la imagen a resolución completa (1 punto = 1 píxel
/// de imagen), la capa vectorial y los trazos del borrador. No está volteada:
/// sus coordenadas coinciden con las de CoreGraphics/PDF (origen
/// abajo-izquierda), así los trazos se guardan directamente en coordenadas de
/// imagen.
final class ImageCanvasView: NSView {

    var image: CGImage? {
        didSet {
            if let image {
                setFrameSize(NSSize(width: image.width, height: image.height))
            }
            needsDisplay = true
        }
    }

    var strokes: [EraserStroke] = [] {
        didSet { needsDisplay = true }
    }

    /// Capa vectorial ya transformada a coordenadas del canvas (y hacia arriba).
    var vectorPath: CGPath? {
        didSet { needsDisplay = true }
    }
    var vectorColor: CGColor = CGColor(gray: 0.05, alpha: 1)
    var vectorMode: VectorDisplayMode = .off {
        didSet { needsDisplay = true }
    }

    var tool: EditorTool = .pan {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    var brushSize: CGFloat = 30
    var onStrokeFinished: ((EraserStroke) -> Void)?
    var onToggleZoom: (() -> Void)?

    private var activeStroke: EraserStroke?
    private var lastPanPoint: NSPoint?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
        ctx.fill(dirtyRect)

        if let image {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }

        // Capa vectorial: tal como quedará en el PDF (relleno) o como
        // contornos de inspección.
        if let path = vectorPath, vectorMode != .off {
            ctx.saveGState()
            ctx.addPath(path)
            switch vectorMode {
            case .fill:
                ctx.setFillColor(vectorColor)
                ctx.fillPath(using: .evenOdd)
            case .outline:
                let m = enclosingScrollView?.magnification ?? 1
                ctx.setStrokeColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 0.9))
                ctx.setLineWidth(max(0.4, 1.2 / m))
                ctx.strokePath()
            case .off:
                break
            }
            ctx.restoreGState()
        }

        // Trazos del borrador (pintura blanca, extremos redondeados).
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes + (activeStroke.map { [$0] } ?? []) {
            drawStroke(stroke, in: ctx)
        }
    }

    private func drawStroke(_ stroke: EraserStroke, in ctx: CGContext) {
        guard let first = stroke.points.first else { return }
        if stroke.points.count == 1 {
            let r = stroke.width / 2
            ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
            return
        }
        ctx.setLineWidth(stroke.width)
        ctx.beginPath()
        ctx.move(to: first)
        for point in stroke.points.dropFirst() {
            ctx.addLine(to: point)
        }
        ctx.strokePath()
    }

    // MARK: - Ratón: borrador, arrastre para mover y doble clic

    override func mouseDown(with event: NSEvent) {
        switch tool {
        case .eraser:
            let point = convert(event.locationInWindow, from: nil)
            activeStroke = EraserStroke(points: [point], width: brushSize)
            needsDisplay = true
        case .pan:
            if event.clickCount == 2 {
                onToggleZoom?()
                return
            }
            lastPanPoint = event.locationInWindow
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch tool {
        case .eraser:
            guard activeStroke != nil else { return }
            let point = convert(event.locationInWindow, from: nil)
            activeStroke?.points.append(point)
            needsDisplay = true
        case .pan:
            guard let last = lastPanPoint,
                  let scroll = enclosingScrollView else { return }
            let m = max(0.0001, scroll.magnification)
            let dx = (event.locationInWindow.x - last.x) / m
            let dy = (event.locationInWindow.y - last.y) / m
            let clip = scroll.contentView
            var origin = clip.bounds.origin
            origin.x -= dx
            origin.y -= dy
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
            lastPanPoint = event.locationInWindow
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .eraser:
            guard let stroke = activeStroke else { return }
            activeStroke = nil
            onStrokeFinished?(stroke)
        case .pan:
            lastPanPoint = nil
            NSCursor.openHand.set()
        }
    }

    /// ⌘ + rueda / desplazamiento del trackpad = zoom centrado en el cursor.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              let scroll = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        let factor = max(0.8, min(1.25, 1 + event.scrollingDeltaY * 0.01))
        let target = min(
            scroll.maxMagnification,
            max(scroll.minMagnification, scroll.magnification * factor)
        )
        let cursor = scroll.contentView.convert(event.locationInWindow, from: nil)
        scroll.setMagnification(target, centeredAt: cursor)
    }

    override func resetCursorRects() {
        switch tool {
        case .eraser:
            addCursorRect(bounds, cursor: .crosshair)
        case .pan:
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// Envoltura SwiftUI: NSScrollView con magnificación libre (2 % – 6400 %),
/// pellizco del trackpad, ⌘+rueda, arrastre para mover y doble clic.
/// El flujo de zoom es unidireccional: los botones actúan sobre el scroll a
/// través de `ZoomController`; la etiqueta solo lee.
struct ZoomableCanvas: NSViewRepresentable {

    let image: CGImage?
    let strokes: [EraserStroke]
    let tool: EditorTool
    let brushSize: CGFloat
    let vectorPath: CGPath?
    let vectorColor: CGColor
    let vectorMode: VectorDisplayMode
    let controller: ZoomController
    let onStroke: (EraserStroke) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = ImageCanvasView()
        canvas.onStrokeFinished = { stroke in
            context.coordinator.parent.onStroke(stroke)
        }

        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 64
        scroll.backgroundColor = NSColor(white: 0.35, alpha: 1)
        scroll.usesPredominantAxisScrolling = false

        canvas.onToggleZoom = { [weak controller] in
            controller?.toggleFitActual()
        }
        controller.attach(scroll)

        // Solo para refrescar la etiqueta de porcentaje; nunca se escribe la
        // magnificación de vuelta desde aquí.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollChanged(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let canvas = scroll.documentView as? ImageCanvasView else { return }

        if controller.scrollView !== scroll {
            controller.attach(scroll)
        }

        if canvas.image !== image {
            canvas.image = image
            if image != nil {
                // Encajar la nueva página cuando el layout esté listo.
                DispatchQueue.main.async { [weak controller] in
                    controller?.fit()
                }
            }
        }
        if canvas.strokes != strokes { canvas.strokes = strokes }
        if canvas.tool != tool { canvas.tool = tool }
        canvas.brushSize = brushSize
        if canvas.vectorPath !== vectorPath { canvas.vectorPath = vectorPath }
        if canvas.vectorMode != vectorMode { canvas.vectorMode = vectorMode }
        canvas.vectorColor = vectorColor
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        var parent: ZoomableCanvas

        init(_ parent: ZoomableCanvas) {
            self.parent = parent
        }

        @objc func scrollChanged(_ notification: Notification) {
            // Lectura unidireccional: solo actualiza la etiqueta.
            let controller = parent.controller
            DispatchQueue.main.async {
                controller.refreshLabel()
            }
        }
    }
}
