import AppKit

@MainActor
final class RecordingControlBar: NSObject {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onShowCamera: (() -> Void)?
    let window: NSPanel
    private let statusLabel = NSTextField(labelWithString: "Préparation…")
    private var stopButton: NSButton!
    private var cameraButton: NSButton!
    private var cancelButton: NSButton!

    private enum Style {
        static let size = CGSize(width: 350, height: 54)
        static let padding: CGFloat = 12
        static let spacing: CGFloat = 10
        static let buttonSize: CGFloat = 32
        static let cornerRadius: CGFloat = 15
        static let background = NSColor(white: 0.10, alpha: 0.97)
        static let foreground = NSColor(white: 0.94, alpha: 1)
        static let secondary = NSColor(white: 0.55, alpha: 1)
        static let stop = NSColor(srgbRed: 1, green: 0.30, blue: 0.32, alpha: 1)
    }

    override init() {
        window = RecordingBarPanel(contentRect: CGRect(origin: .zero, size: Style.size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.autorecalculatesKeyViewLoop = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = Style.background.cgColor
        background.layer?.cornerRadius = Style.cornerRadius
        background.layer?.masksToBounds = true
        window.contentView = background

        let handle = RecordingDragHandle()
        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Déplacer la barre")
        handle.contentTintColor = Style.secondary
        handle.toolTip = "Déplacer la barre"
        handle.setAccessibilityLabel("Déplacer la barre d’enregistrement")
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.widthAnchor.constraint(equalToConstant: 18).isActive = true
        handle.heightAnchor.constraint(equalToConstant: Style.buttonSize).isActive = true
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = Style.foreground
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Durée et état de l’enregistrement")
        stopButton = makeButton(symbol: "stop.fill", label: "Arrêter l’enregistrement", action: #selector(stop))
        stopButton.contentTintColor = Style.stop
        cameraButton = makeButton(symbol: "video.fill", label: "Afficher la caméra", action: #selector(showCamera))
        cancelButton = makeButton(symbol: "xmark", label: "Annuler l’enregistrement", action: #selector(cancel))
        let stack = NSStackView(views: [handle, statusLabel, stopButton, cameraButton, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Style.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Style.padding),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Style.padding),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: Style.buttonSize)
        ])
        update(status: "Préparation…", canStop: false, canCancel: true, cameraEnabled: false)
        stopButton.nextKeyView = cameraButton
        cameraButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = stopButton
    }

    func show(on screen: NSScreen) {
        if !window.isVisible {
            let frame = screen.visibleFrame
            let x = min(max(frame.minX, frame.midX - Style.size.width / 2), frame.maxX - Style.size.width)
            window.setFrameOrigin(CGPoint(x: x, y: frame.maxY - Style.size.height - 16))
        }
        window.orderFrontRegardless()
    }

    func update(status: String, canStop: Bool, canCancel: Bool, cameraEnabled: Bool) {
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        stopButton.isEnabled = canStop
        cancelButton.isEnabled = canCancel
        cameraButton.isEnabled = cameraEnabled
        window.initialFirstResponder = canStop ? stopButton : (canCancel ? cancelButton : cameraButton)
    }

    func close() { window.orderOut(nil) }

    private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = RecordingBarButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = Style.foreground
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Style.buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: Style.buttonSize).isActive = true
        return button
    }

    @objc private func stop() { onStop?() }
    @objc private func cancel() { onCancel?() }
    @objc private func showCamera() { onShowCamera?() }
}

@MainActor
private final class RecordingBarButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}

@MainActor
private final class RecordingBarPanel: NSPanel {
    // A click can give keyboard focus to this nonactivating panel without changing the active app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingDragHandle: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
