import AppKit

private final class CaptureToolbarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class CapturePanelController: NSWindowController {
    var onDismiss: (() -> Void)?
    var onSnapshot: (() -> Void)?
    var onDisplay: (() -> Void)?
    var onRegion: (() -> Void)?
    var onScroll: (() -> Void)?
    var onRecord: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onLastImage: (() -> Void)?
    var onLastVideo: (() -> Void)?
    var onOpenImage: (() -> Void)?
    var onSample: (() -> Void)?
    var onPermission: (() -> Void)?

    private enum Style {
        static let size = NSSize(width: 644, height: 94)
        static let foreground = NSColor(calibratedWhite: 0.94, alpha: 1)
        static let background = NSColor(calibratedWhite: 0.12, alpha: 0.98)
    }
    private let selectionLabel = NSTextField(labelWithString: "Choisir une zone ou un écran")
    private var captureButtons: [NSButton] = []
    private var videoButton: NSButton!
    private var statusButton: NSButton!
    private var lastImageItem: NSMenuItem!
    private var lastVideoItem: NSMenuItem!
    private let moreMenu = NSMenu()
    private let statusPopover = NSPopover()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var recording = false
    private var selectionReady = true
    private var captureBusy = false

    init() {
        let panel = CaptureToolbarPanel(contentRect: NSRect(origin: .zero, size: Style.size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "ArtShot X · Capture"
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Set this after isFloatingPanel, which resets NSPanel's level to floating.
        // Keep the actions above the selection overlay, below native menus and popovers.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let content = NSView(frame: NSRect(origin: .zero, size: Style.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Style.background.cgColor
        content.layer?.cornerRadius = 18
        panel.contentView = content
        let grip = NSTextField(labelWithString: "⠿")
        grip.frame = NSRect(x: 10, y: 47, width: 15, height: 22)
        grip.textColor = .secondaryLabelColor
        grip.setAccessibilityLabel("Déplacer la barre")
        content.addSubview(grip)
        let definitions: [(String, String, Selector, CGFloat)] = [
            ("Zone", "viewfinder", #selector(captureRegion), 76),
            ("Écran", "rectangle.dashed", #selector(captureDisplay), 76),
            ("Photo", "camera", #selector(captureSnapshot), 76),
            ("Défilement", "arrow.down.to.line", #selector(captureScroll), 108),
            ("Vidéo", "record.circle", #selector(recordVideo), 86)
        ]
        var x: CGFloat = 30
        for (title, symbol, action, width) in definitions {
            let control = button(title, symbol: symbol, action: action)
            control.frame = NSRect(x: x, y: 36, width: width, height: 44)
            content.addSubview(control)
            captureButtons.append(control)
            x += width + 3
        }
        videoButton = captureButtons.last!
        let separator = NSBox(frame: NSRect(x: x + 3, y: 42, width: 1, height: 32))
        separator.boxType = .separator
        content.addSubview(separator)
        let more = button("Plus", symbol: "ellipsis", action: #selector(showMore))
        more.frame = NSRect(x: x + 12, y: 36, width: 62, height: 44)
        content.addSubview(more)
        statusButton = button("", symbol: "info.circle", action: #selector(showStatus))
        statusButton.frame = NSRect(x: 566, y: 42, width: 28, height: 32)
        statusButton.setAccessibilityLabel("État et autorisations")
        content.addSubview(statusButton)
        let close = button("", symbol: "xmark", action: #selector(dismiss))
        close.frame = NSRect(x: 606, y: 42, width: 28, height: 32)
        close.setAccessibilityLabel("Fermer la barre")
        close.keyEquivalent = "\u{1b}"
        content.addSubview(close)
        selectionLabel.frame = NSRect(x: 30, y: 10, width: 580, height: 18)
        selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.textColor = .secondaryLabelColor
        content.addSubview(selectionLabel)
        lastImageItem = menuItem("Dernière capture", action: #selector(lastImage))
        lastVideoItem = menuItem("Dernière vidéo", action: #selector(lastVideo))
        moreMenu.addItem(.separator())
        _ = menuItem("Ouvrir une image…", action: #selector(openImage))
        _ = menuItem("Image d’essai", action: #selector(showSample))
        moreMenu.addItem(.separator())
        _ = menuItem("Autoriser la capture…", action: #selector(requestPermission))
        moreMenu.autoenablesItems = false
        let statusController = NSViewController()
        statusController.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 210))
        statusLabel.frame = NSRect(x: 14, y: 48, width: 372, height: 148)
        statusLabel.font = .systemFont(ofSize: 12)
        statusController.view.addSubview(statusLabel)
        let permission = NSButton(title: "Autoriser la capture…", target: self, action: #selector(requestPermission))
        permission.frame = NSRect(x: 14, y: 10, width: 220, height: 30)
        statusController.view.addSubview(permission)
        statusPopover.contentViewController = statusController
        statusPopover.behavior = .transient
        refresh(hasPermission: true, busy: false, shortcutFailures: [], hasImage: false, hasVideo: false, isRecording: false)
    }

    required init?(coder: NSCoder) { nil }

    func setSelection(isRegion: Bool, pixelSize: CGSize) {
        for (index, control) in captureButtons.prefix(2).enumerated() {
            let selected = isRegion ? index == 0 : index == 1
            control.state = selected ? .on : .off
            control.contentTintColor = selected ? .systemBlue : Style.foreground
        }
        selectionLabel.stringValue = "\(isRegion ? "Zone" : "Écran") · \(Int(pixelSize.width)) × \(Int(pixelSize.height)) px"
    }

    func setSelectionReady(_ ready: Bool) {
        selectionReady = ready
        if !ready {
            selectionLabel.stringValue = "Tracez une zone ou choisissez Écran"
            captureButtons.prefix(2).forEach { $0.state = .off; $0.contentTintColor = Style.foreground }
        }
        updateCaptureButtons()
    }

    private func updateCaptureButtons() {
        captureButtons.prefix(2).forEach { $0.isEnabled = !captureBusy && !recording }
        captureButtons.dropFirst(2).forEach { $0.isEnabled = selectionReady && !captureBusy && !recording }
        if recording { videoButton.isEnabled = true }
    }

    func present(on screen: NSScreen, avoiding region: CGRect? = nil, takeKeyboard: Bool = true) {
        guard let window else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let size = window.frame.size
        var origin = NSPoint(x: max(visible.minX, visible.midX - size.width / 2), y: visible.minY + 34)
        if let region {
            origin.x = max(visible.minX, min(visible.maxX - size.width, region.midX - size.width / 2))
            if region.minY - size.height - margin >= visible.minY {
                origin.y = region.minY - size.height - margin
            } else if region.maxY + margin + size.height <= visible.maxY {
                origin.y = region.maxY + margin
            } else {
                origin.y = min(visible.maxY - size.height, max(visible.minY, region.minY + margin))
            }
        }
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        if takeKeyboard { window.makeKey() }
    }

    func refresh(hasPermission: Bool, busy: Bool, shortcutFailures: [String], hasImage: Bool, hasVideo: Bool, isRecording: Bool) {
        recording = isRecording
        captureBusy = busy
        updateCaptureButtons()
        videoButton.title = isRecording ? "Arrêter" : "Vidéo"
        videoButton.image = NSImage(systemSymbolName: isRecording ? "stop.circle.fill" : "record.circle", accessibilityDescription: nil)
        videoButton.setAccessibilityLabel(isRecording ? "Arrêter l’enregistrement" : "Vidéo")
        lastImageItem.isEnabled = hasImage && !busy
        lastVideoItem.isEnabled = hasVideo && !busy
        var messages = [String]()
        if !hasPermission { messages.append("Autorisez la capture dans les réglages macOS.") }
        if !shortcutFailures.isEmpty { messages.append("Raccourci indisponible : " + shortcutFailures.joined(separator: ", ") + ". Fermez l’app qui l’utilise, puis relancez ArtShot X.") }
        if isRecording { messages.append("Enregistrement en cours.") }
        else if busy { messages.append("Capture en cours…") }
        if messages.isEmpty { messages.append("⌘⌥⇧7 ouvre cette barre.") }
        statusLabel.stringValue = messages.joined(separator: "\n")
        statusButton.toolTip = statusLabel.stringValue
        statusButton.image = NSImage(systemSymbolName: !hasPermission || !shortcutFailures.isEmpty ? "exclamationmark.circle.fill" : "info.circle", accessibilityDescription: nil)
        statusButton.contentTintColor = !hasPermission || !shortcutFailures.isEmpty ? .systemOrange : Style.foreground
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        control.isBordered = false
        control.font = .systemFont(ofSize: 12, weight: .medium)
        control.contentTintColor = Style.foreground
        control.imagePosition = title.isEmpty ? .imageOnly : .imageAbove
        control.setAccessibilityLabel(title)
        return control
    }
    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        moreMenu.addItem(item)
        return item
    }
    @objc private func showMore(_ sender: NSButton) { moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender) }
    @objc private func showStatus(_ sender: NSButton) { statusPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY) }
    func hide() { statusPopover.close(); window?.orderOut(nil) }
    @objc private func dismiss() { hide(); onDismiss?() }
    @objc private func captureSnapshot() { onSnapshot?() }
    @objc private func captureDisplay() { onDisplay?() }
    @objc private func captureRegion() { onRegion?() }
    @objc private func captureScroll() { onScroll?() }
    @objc private func recordVideo() { if recording { onStopRecording?() } else { onRecord?() } }
    @objc private func lastImage() { onLastImage?() }
    @objc private func lastVideo() { onLastVideo?() }
    @objc private func openImage() { onOpenImage?() }
    @objc private func showSample() { onSample?() }
    @objc private func requestPermission() { onPermission?() }
}
