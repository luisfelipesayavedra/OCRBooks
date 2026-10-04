import SwiftUI
import AppKit

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

/// Vista AppKit que dibuja la imagen a resolución completa (1 punto = 1 píxel
/// de imagen) y los trazos del borrador encima. No está volteada: sus
/// coordenadas coinciden con las de CoreGraphics/PDF (origen abajo-izquierda),
/// así los trazos se guardan directamente en coordenadas de imagen.
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

    var tool: EditorTool = .pan {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    var brushSize: CGFloat = 30
    var onStrokeFinished: ((EraserStroke) -> Void)?

    private var activeStroke: EraserStroke?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
        ctx.fill(dirtyRect)

        if let image {
            // Con mucho zoom se muestran los píxeles reales, sin suavizar:
            // es lo que permite inspeccionar los detalles más mínimos.
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
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

    // MARK: - Borrador

    override func mouseDown(with event: NSEvent) {
        guard tool == .eraser else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        activeStroke = EraserStroke(points: [point], width: brushSize)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool == .eraser, activeStroke != nil else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        activeStroke?.points.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard tool == .eraser, let stroke = activeStroke else {
            super.mouseUp(with: event)
            return
        }
        activeStroke = nil
        onStrokeFinished?(stroke)
    }

    override func resetCursorRects() {
        if tool == .eraser {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// Envoltura SwiftUI: NSScrollView con magnificación libre (2 % – 6400 %),
/// pellizco del trackpad incluido.
struct ZoomableCanvas: NSViewRepresentable {

    let image: CGImage?
    let strokes: [EraserStroke]
    let tool: EditorTool
    let brushSize: CGFloat
    @Binding var magnification: CGFloat
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

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let canvas = scroll.documentView as? ImageCanvasView else { return }

        if canvas.image !== image {
            canvas.image = image
            if let image {
                // Encaje inicial de la página en el visor.
                DispatchQueue.main.async {
                    let fit = min(
                        scroll.contentView.bounds.width * scroll.magnification / CGFloat(image.width),
                        scroll.contentView.bounds.height * scroll.magnification / CGFloat(image.height)
                    )
                    let target = min(1, max(scroll.minMagnification, fit))
                    scroll.magnification = target
                    self.magnification = target
                }
            }
        }
        if canvas.strokes != strokes { canvas.strokes = strokes }
        if canvas.tool != tool { canvas.tool = tool }
        canvas.brushSize = brushSize

        if magnification > 0, abs(scroll.magnification - magnification) > 0.001 {
            let center = CGPoint(
                x: scroll.contentView.bounds.midX,
                y: scroll.contentView.bounds.midY
            )
            scroll.setMagnification(magnification, centeredAt: center)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        var parent: ZoomableCanvas

        init(_ parent: ZoomableCanvas) {
            self.parent = parent
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard let contentView = notification.object as? NSClipView,
                  let scroll = contentView.superview as? NSScrollView else { return }
            let current = scroll.magnification
            if abs(current - parent.magnification) > 0.001 {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.magnification = current
                }
            }
        }
    }
}
