import AppKit

@MainActor
final class RecordingControlBar: NSObject {
    var onStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onRestart: (() -> Void)?
    var onCancel: (() -> Void)?
    let window: NSPanel
    private let statusLabel = NSTextField(labelWithString: "Préparation…")
    private var stopButton: NSButton!
    private var pauseButton: NSButton!
    private var restartButton: NSButton!
    private var cancelButton: NSButton!

    private enum Style {
        static let size = CGSize(width: 370, height: 66)
        static let padding: CGFloat = 16
        static let spacing: CGFloat = 12
        static let buttonSize: CGFloat = 34
        static let timerWidth: CGFloat = 76
        static let cornerRadius: CGFloat = 33
        static let background = NSColor(white: 0.10, alpha: 0.97)
        static let foreground = NSColor(white: 0.94, alpha: 1)
        static let secondary = NSColor(white: 0.55, alpha: 1)
        static let separator = NSColor(white: 0.28, alpha: 1)
        static let stop = NSColor(srgbRed: 1, green: 0.30, blue: 0.32, alpha: 1)
    }

    override init() {
        window = RecordingBarPanel(contentRect: CGRect(origin: .zero, size: Style.size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "ArtShot X · Télécommande"
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
        handle.image = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "Déplacer la télécommande")
        handle.contentTintColor = Style.secondary
        handle.toolTip = "Déplacer la télécommande"
        handle.setAccessibilityLabel("Déplacer la télécommande d’enregistrement")
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.widthAnchor.constraint(equalToConstant: 18).isActive = true
        handle.heightAnchor.constraint(equalToConstant: Style.buttonSize).isActive = true
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        statusLabel.textColor = Style.stop
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Durée et état de l’enregistrement")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.widthAnchor.constraint(equalToConstant: Style.timerWidth).isActive = true
        stopButton = makeButton(symbol: "stop.circle", label: "Arrêter l’enregistrement", action: #selector(stop))
        stopButton.contentTintColor = Style.stop
        let recording = NSStackView(views: [stopButton, statusLabel])
        recording.orientation = .horizontal
        recording.alignment = .centerY
        recording.spacing = 8
        pauseButton = makeButton(symbol: "pause.circle", label: "Pause", action: #selector(pauseResume))
        restartButton = makeButton(symbol: "arrow.counterclockwise", label: "Recommencer l’enregistrement", action: #selector(restart))
        cancelButton = makeButton(symbol: "trash", label: "Supprimer l’enregistrement", action: #selector(cancel))
        let stack = NSStackView(views: [recording, makeSeparator(), pauseButton, makeSeparator(),
                                        restartButton, makeSeparator(), cancelButton, makeSeparator(), handle])
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
        update(status: "Préparation…", canStop: false, canCancel: true,
               canRestart: false, canPause: false, isPaused: false)
        stopButton.nextKeyView = pauseButton
        pauseButton.nextKeyView = restartButton
        restartButton.nextKeyView = cancelButton
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

    func update(status: String, canStop: Bool, canCancel: Bool, canRestart: Bool, canPause: Bool, isPaused: Bool) {
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        stopButton.isEnabled = canStop
        cancelButton.isEnabled = canCancel
        restartButton.isEnabled = canRestart
        pauseButton.isEnabled = canPause
        let pauseLabel = isPaused ? "Reprendre" : "Pause"
        pauseButton.image = symbol(isPaused ? "play.circle" : "pause.circle", label: pauseLabel)
        pauseButton.toolTip = pauseLabel
        pauseButton.setAccessibilityLabel(pauseLabel)
        window.initialFirstResponder = [stopButton!, pauseButton!, restartButton!, cancelButton!].first { $0.isEnabled }
    }

    func close() { window.orderOut(nil) }

    private func makeButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = RecordingBarButton(image: self.symbol(symbol, label: label),
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

    private func symbol(_ name: String, label: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 25, weight: .regular)) ?? image
    }

    private func makeSeparator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Style.separator.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return view
    }

    @objc private func stop() { onStop?() }
    @objc private func cancel() { onCancel?() }
    @objc private func pauseResume() { onPauseResume?() }
    @objc private func restart() { onRestart?() }
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
