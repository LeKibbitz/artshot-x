import AppKit

/// The visible camera uses the same fixed layout and top-left coordinate contract as the video export.
@MainActor
final class CameraOverlayController {
    var onLayoutChanged: ((CameraLayout) -> Void)?
    private(set) var currentLayout = CameraLayout()
    let window: NSPanel
    private let cameraView = CameraOverlayView()
    private var captureRect = CGRect.zero
    private var editable = false

    init() {
        window = CameraOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = cameraView
        cameraView.onDrag = { [weak self] delta in self?.move(by: delta) }
    }

    func show(in captureRect: CGRect, layout: CameraLayout, editable: Bool) {
        guard captureRect.width > 0, captureRect.height > 0 else { return }
        self.captureRect = captureRect
        currentLayout = layout
        self.editable = editable
        window.ignoresMouseEvents = !editable
        cameraView.editable = editable
        cameraView.shape = layout.shape
        positionWindow()
        window.orderFrontRegardless()
    }

    func update(image: CGImage) { cameraView.image = image }

    func close() {
        window.orderOut(nil)
        cameraView.image = nil
    }

    private func positionWindow() {
        let frame = currentLayout.frame(in: captureRect.size)
        window.setFrame(CGRect(x: captureRect.minX + frame.minX,
                               y: captureRect.maxY - frame.maxY,
                               width: frame.width, height: frame.height), display: true)
    }

    private func move(by delta: CGSize) {
        guard editable, captureRect.width > 0, captureRect.height > 0 else { return }
        let frame = currentLayout.frame(in: captureRect.size)
        var moved = currentLayout
        moved.centerX = (frame.midX + delta.width) / captureRect.width
        moved.centerY = (frame.midY - delta.height) / captureRect.height
        // Store the clamped center, so dragging back from an edge has no invisible overshoot.
        let clamped = moved.frame(in: captureRect.size)
        moved.centerX = clamped.midX / captureRect.width
        moved.centerY = clamped.midY / captureRect.height
        currentLayout = moved
        positionWindow()
        onLayoutChanged?(moved)
    }
}

@MainActor
private final class CameraOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CameraOverlayView: NSView {
    private enum Style {
        static let background = NSColor(white: 0.10, alpha: 0.96)
        static let placeholder = NSColor(white: 0.80, alpha: 1)
        static let placeholderFont: CGFloat = 12
        static let symbolSize: CGFloat = 28
        static let roundedRadiusFraction: CGFloat = 0.16
    }

    var onDrag: ((CGSize) -> Void)?
    var image: CGImage? { didSet { needsDisplay = true } }
    var shape: CameraShape = .roundedRectangle { didSet { needsDisplay = true } }
    var editable = false {
        didSet {
            dragAnchor = nil
            setAccessibilityLabel(editable ? "Aperçu caméra, faites glisser pour placer" : "Caméra pendant l’enregistrement")
            window?.invalidateCursorRects(for: self)
        }
    }
    private var dragAnchor: CGPoint?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if editable { addCursorRect(bounds, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        context.saveGState()
        let path: CGPath
        switch shape {
        case .circle: path = CGPath(ellipseIn: bounds, transform: nil)
        case .square: path = CGPath(rect: bounds, transform: nil)
        case .roundedRectangle:
            let radius = min(bounds.width, bounds.height) * Style.roundedRadiusFraction
            path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        context.addPath(path)
        context.clip()
        context.setFillColor(Style.background.cgColor)
        context.fill(bounds)
        if let image {
            let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        } else {
            let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
            let symbolRect = CGRect(x: bounds.midX - Style.symbolSize / 2, y: bounds.midY,
                                    width: Style.symbolSize, height: Style.symbolSize)
            symbol?.draw(in: symbolRect)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: Style.placeholderFont), .foregroundColor: Style.placeholder
            ]
            let text = "Caméra"
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height - 6),
                      withAttributes: attributes)
        }
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        guard editable else { return }
        dragAnchor = window?.convertPoint(toScreen: event.locationInWindow)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard editable, let anchor = dragAnchor,
              let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        onDrag?(CGSize(width: point.x - anchor.x, height: point.y - anchor.y))
        dragAnchor = point
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        if editable { NSCursor.openHand.set() }
    }
}
