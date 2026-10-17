import AppKit
import ArtShotCore

@MainActor
final class SelectionOverlayController {
    private var window: SelectionWindow?
    private var completion: ((CGRect?) -> Void)?
    private var screenObserver: NSObjectProtocol?
    private var onChange: ((CGRect?) -> Void)?
    private var onCancel: (() -> Void)?
    private(set) var isPreparing = false
    var currentPreparedRect: CGRect? { (window?.contentView as? SelectionView)?.globalSelection }

    func beginPreparation(on screen: NSScreen, initialRect: CGRect? = nil,
                          onChange: @escaping (CGRect?) -> Void, onCancel: @escaping () -> Void) {
        cancel()
        begin(on: screen) { _ in }
        completion = nil
        window?.level = .statusBar
        isPreparing = true
        self.onChange = onChange
        self.onCancel = onCancel
        let view = window?.contentView as? SelectionView
        view?.isPreparing = true
        view?.didChange = { [weak self] rect in self?.onChange?(rect) }
        view?.setGlobalSelection(initialRect)
    }

    func closePreparation() {
        guard isPreparing else { return }
        onCancel = nil
        finish(nil)
    }

    func setPreparedRect(_ rect: CGRect?) {
        guard isPreparing, let view = window?.contentView as? SelectionView else { return }
        view.setGlobalSelection(rect)
        onChange?(view.globalSelection)
    }

    func revealPreparation() {
        guard isPreparing else { return }
        window?.orderFrontRegardless()
    }

    /// Returns a rectangle in AppKit global points, or nil exactly once on cancellation.
    func begin(on screen: NSScreen, confirmation: String = "capturer", completion: @escaping (CGRect?) -> Void) {
        cancel()
        self.completion = completion
        let overlay = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.hidesOnDeactivate = false
        overlay.isFloatingPanel = true
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.level = .screenSaver
        overlay.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        overlay.acceptsMouseMovedEvents = true
        overlay.sharingType = .none
        overlay.animationBehavior = .none
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                 screenFrame: screen.frame, scale: screen.backingScaleFactor, confirmation: confirmation)
        view.didFinish = { [weak self] rect in self?.finish(rect) }
        overlay.contentView = view
        window = overlay
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            // A changed arrangement invalidates the coordinate contract of an in-progress drag.
            Task { @MainActor [weak self] in self?.cancel() }
        }
        // A nonactivating panel can own selection keystrokes while the source app
        // remains frontmost in its current Space (including native fullscreen).
        overlay.orderFrontRegardless()
        overlay.makeKey()
        overlay.makeFirstResponder(view)
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        let callback = completion
        let cancellation = rect == nil ? onCancel : nil
        completion = nil
        onCancel = nil
        onChange = nil
        isPreparing = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        callback?(rect)
        cancellation?()
    }
}

@MainActor
private final class SelectionWindow: NSPanel {
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
        static let handleHitRadius: CGFloat = 9
        static let handleDiameter: CGFloat = 6
    }

    var didFinish: ((CGRect?) -> Void)?
    var didChange: ((CGRect?) -> Void)?
    var isPreparing = false {
        didSet {
            setAccessibilityLabel(isPreparing
                ? "Sélection de capture. Tracez, déplacez ou redimensionnez une zone. Échap pour annuler."
                : "Sélection de capture. Tracez une zone, Entrée pour \(confirmation), Échap pour annuler.")
            needsDisplay = true
        }
    }
    var globalSelection: CGRect? {
        selection.map { CaptureGeometry.globalRect(fromLocal: $0, screenFrame: screenFrame) }
    }
    func setGlobalSelection(_ rect: CGRect?) {
        dragStart = nil
        selection = rect.flatMap { rect in
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite else { return nil }
            let local = rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY).intersection(bounds)
            return local.width >= Style.minimumSide && local.height >= Style.minimumSide ? local : nil
        }
        needsDisplay = true
    }
    private enum DragMode { case draw, move(CGRect), resize(CGRect, Int) }
    private var dragMode: DragMode = .draw

    private func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    private func updateSelection(to point: CGPoint) {
        guard let start = dragStart else { return }
        switch dragMode {
        case .draw: selection = CaptureGeometry.rectangle(from: start, to: point)
        case .move(let rect):
            selection = CGRect(x: min(max(bounds.minX, rect.minX + point.x - start.x), bounds.maxX - rect.width),
                               y: min(max(bounds.minY, rect.minY + point.y - start.y), bounds.maxY - rect.height),
                               width: rect.width, height: rect.height)
        case .resize(let rect, let handle):
            var x1 = rect.minX, x2 = rect.maxX, y1 = rect.minY, y2 = rect.maxY
            if [0, 6, 7].contains(handle) { x1 = min(point.x, x2 - Style.minimumSide) }
            if [2, 3, 4].contains(handle) { x2 = max(point.x, x1 + Style.minimumSide) }
            if [0, 1, 2].contains(handle) { y1 = min(point.y, y2 - Style.minimumSide) }
            if [4, 5, 6].contains(handle) { y2 = max(point.y, y1 + Style.minimumSide) }
            selection = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        }
    }
    private let screenFrame: CGRect
    private let scale: CGFloat
    private let confirmation: String
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var pointer: CGPoint?
    private var tracking: NSTrackingArea?

    init(frame: CGRect, screenFrame: CGRect, scale: CGFloat, confirmation: String = "capturer") {
        self.screenFrame = screenFrame
        self.scale = scale
        self.confirmation = confirmation
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sélection de capture. Tracez une zone, Entrée pour \(confirmation), Échap pour annuler.")
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

    private func updateCursor(at point: CGPoint) {
        if dragStart != nil, case .move = dragMode { NSCursor.closedHand.set(); return }
        guard let selection else { NSCursor.crosshair.set(); return }
        if let handle = handles(selection).firstIndex(where: {
            abs($0.x - point.x) <= Style.handleHitRadius && abs($0.y - point.y) <= Style.handleHitRadius
        }) {
            switch handle {
            case 1, 5: NSCursor.resizeUpDown.set()
            case 3, 7: NSCursor.resizeLeftRight.set()
            default: NSCursor.crosshair.set()
            }
        } else if selection.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func mouseEntered(with event: NSEvent) { updateCursor(at: point(for: event)) }
    override func mouseExited(with event: NSEvent) { pointer = nil; needsDisplay = true }

    override func mouseMoved(with event: NSEvent) {
        pointer = point(for: event)
        updateCursor(at: point(for: event))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = point(for: event)
        dragStart = point
        pointer = point
        if let selection, let handle = handles(selection).firstIndex(where: { abs($0.x - point.x) <= Style.handleHitRadius && abs($0.y - point.y) <= Style.handleHitRadius }) {
            dragMode = .resize(selection, handle)
        } else if let selection, selection.contains(point) {
            dragMode = .move(selection)
        } else {
            dragMode = .draw
            selection = nil
        }
        updateCursor(at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let point = point(for: event)
        pointer = point
        updateSelection(to: point)
        updateCursor(at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        updateSelection(to: point(for: event))
        dragStart = nil
        updateCursor(at: point(for: event))
        if !hasValidSelection { selection = nil }
        needsDisplay = true
        didChange?(globalSelection)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: didFinish?(nil)
        case 36, 76:
            if isPreparing { didChange?(globalSelection); return }
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
            if !isPreparing {
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
        }

        guard !isPreparing else { return }
        let instruction = hasValidSelection
            ? "Entrée pour \(confirmation)  ·  Déplacez ou redimensionnez  ·  Échap pour annuler"
            : "Tracez une zone  ·  Entrée pour \(confirmation)  ·  Échap pour annuler"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = min(bounds.width - 32, textSize(instruction, font: font).width + 36)
        drawPill(text: instruction, rect: CGRect(x: (bounds.width - width) / 2, y: 28, width: width, height: 42),
                 font: font, color: Style.secondary)
    }

    private func drawHandles(around rect: CGRect) {
        Style.accent.setFill()
        for point in handles(rect) {
            NSBezierPath(ovalIn: CGRect(x: point.x - Style.handleDiameter / 2, y: point.y - Style.handleDiameter / 2,
                                       width: Style.handleDiameter, height: Style.handleDiameter)).fill()
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
