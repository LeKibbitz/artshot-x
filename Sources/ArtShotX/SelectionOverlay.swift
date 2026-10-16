import AppKit
import ArtShotCore

@MainActor
final class SelectionOverlayController {
    private var window: SelectionWindow?
    private var completion: ((CGRect?) -> Void)?
    private var screenObserver: NSObjectProtocol?

    /// Returns a rectangle in AppKit global points, or nil exactly once on cancellation.
    func begin(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        cancel()
        self.completion = completion
        let overlay = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.level = .screenSaver
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.acceptsMouseMovedEvents = true
        overlay.sharingType = .none
        overlay.animationBehavior = .none
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                 screenFrame: screen.frame, scale: screen.backingScaleFactor)
        view.didFinish = { [weak self] rect in self?.finish(rect) }
        overlay.contentView = view
        window = overlay
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            // A changed arrangement invalidates the coordinate contract of an in-progress drag.
            Task { @MainActor [weak self] in self?.cancel() }
        }
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKeyAndOrderFront(nil)
        overlay.makeFirstResponder(view)
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        let callback = completion
        completion = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        callback?(rect)
    }
}

@MainActor
private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SelectionView: NSView {
    private enum Style {
        static let accent = NSColor(calibratedRed: 0.52, green: 0.93, blue: 0.74, alpha: 1)
        static let dim = NSColor.black.withAlphaComponent(0.38)
        static let pill = NSColor(calibratedWhite: 0.08, alpha: 0.96)
        static let secondary = NSColor(calibratedWhite: 0.78, alpha: 1)
        static let radius: CGFloat = 12
        static let minimumSide: CGFloat = 2
    }

    var didFinish: ((CGRect?) -> Void)?
    private let screenFrame: CGRect
    private let scale: CGFloat
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var pointer: CGPoint?
    private var tracking: NSTrackingArea?

    init(frame: CGRect, screenFrame: CGRect, scale: CGFloat) {
        self.screenFrame = screenFrame
        self.scale = scale
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sélection de capture. Tracez une zone, Entrée pour capturer, Échap pour annuler.")
    }

    required init?(coder: NSCoder) { return nil }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseExited(with event: NSEvent) { pointer = nil; needsDisplay = true }

    override func mouseMoved(with event: NSEvent) {
        pointer = point(for: event)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = point(for: event)
        dragStart = point
        pointer = point
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = point(for: event)
        pointer = point
        selection = CaptureGeometry.rectangle(from: dragStart, to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let dragStart {
            selection = CaptureGeometry.rectangle(from: dragStart, to: point(for: event))
        }
        dragStart = nil
        if !hasValidSelection { selection = nil }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: didFinish?(nil)
        case 36, 76:
            guard hasValidSelection, let selection else { NSSound.beep(); return }
            didFinish?(CaptureGeometry.globalRect(fromLocal: selection, screenFrame: screenFrame))
        default: break
        }
    }

    override func cancelOperation(_ sender: Any?) { didFinish?(nil) }

    private var hasValidSelection: Bool {
        guard let selection else { return false }
        return selection.width >= Style.minimumSide && selection.height >= Style.minimumSide
    }

    private func point(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                       y: min(bounds.maxY, max(bounds.minY, point.y)))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let mask = NSBezierPath(rect: bounds)
        if let selection, !selection.isEmpty { mask.appendRect(selection) }
        mask.windingRule = .evenOdd
        Style.dim.setFill()
        mask.fill()

        if let pointer, selection == nil {
            NSColor.white.withAlphaComponent(0.45).setStroke()
            let crosshair = NSBezierPath()
            crosshair.move(to: CGPoint(x: bounds.minX, y: pointer.y))
            crosshair.line(to: CGPoint(x: bounds.maxX, y: pointer.y))
            crosshair.move(to: CGPoint(x: pointer.x, y: bounds.minY))
            crosshair.line(to: CGPoint(x: pointer.x, y: bounds.maxY))
            crosshair.lineWidth = 0.5
            crosshair.stroke()
        }

        if let selection, !selection.isEmpty {
            Style.accent.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1.5
            border.stroke()
            drawHandles(around: selection)
            let global = CaptureGeometry.globalRect(fromLocal: selection, screenFrame: screenFrame)
            let aligned = CaptureGeometry.pixelAlignedSourceRect(for: global, screenFrame: screenFrame, scale: scale)
            let pixels = CaptureGeometry.pixelSize(for: aligned?.size ?? selection.size, scale: scale) ?? .zero
            let dimensions = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
            let labelSize = textSize(dimensions, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
            let width = labelSize.width + 24
            let x = min(max(12, selection.midX - width / 2), max(12, bounds.width - width - 12))
            let y = selection.minY >= 48 ? selection.minY - 38 : min(bounds.height - 38, selection.maxY + 10)
            drawPill(text: dimensions, rect: CGRect(x: x, y: y, width: width, height: 28),
                     font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium), color: .white)
        }

        let instruction = hasValidSelection
            ? "Entrée pour capturer  ·  Retracez pour modifier  ·  Échap pour annuler"
            : "Tracez une zone  ·  Entrée pour capturer  ·  Échap pour annuler"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = min(bounds.width - 32, textSize(instruction, font: font).width + 36)
        drawPill(text: instruction, rect: CGRect(x: (bounds.width - width) / 2, y: 28, width: width, height: 42),
                 font: font, color: Style.secondary)
    }

    private func drawHandles(around rect: CGRect) {
        Style.accent.setFill()
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
    }

    private func textSize(_ text: String, font: NSFont) -> CGSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private func drawPill(text: String, rect: CGRect, font: NSFont, color: NSColor) {
        Style.pill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Style.radius, yRadius: Style.radius).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let size = textSize(text, font: font)
        (text as NSString).draw(in: CGRect(x: rect.minX + 10, y: rect.midY - size.height / 2,
                                          width: rect.width - 20, height: size.height),
                               withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
