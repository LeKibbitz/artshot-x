import AppKit

@MainActor
final class CapturePanelController: NSWindowController {
    var onDisplay: (() -> Void)?
    var onRegion: (() -> Void)?
    var onOpenImage: (() -> Void)?
    var onSample: (() -> Void)?
    var onPermission: (() -> Void)?

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "Autoriser la capture…", target: nil, action: nil)
    private let shortcutLabel = NSTextField(wrappingLabelWithString: "")
    private var captureButtons: [NSButton] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ArtShot X"
        window.isReleasedWhenClosed = false
        window.center()
        let heading = NSTextField(labelWithString: "Capturez. Annotez. C’est à vous.")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Une première version locale et open source pour vos captures d’écran.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)

        let fullscreen = button("Plein écran", symbol: "rectangle.dashed", action: #selector(captureDisplay))
        let region = button("Sélection de zone", symbol: "viewfinder", action: #selector(captureRegion))
        captureButtons = [fullscreen, region]
        let captures = NSStackView(views: [fullscreen, region])
        captures.distribution = .fillEqually
        captures.spacing = 12
        let open = button("Ouvrir une image…", symbol: "photo", action: #selector(openImage))
        let sample = button("Essayer une image", symbol: "sparkles", action: #selector(showSample))
        let images = NSStackView(views: [open, sample])
        images.distribution = .fillEqually
        images.spacing = 12

        let separator = NSBox()
        separator.boxType = .separator
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, subtitle, captures, images, separator, statusLabel, permissionButton, shortcutLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captures.widthAnchor.constraint(equalTo: stack.widthAnchor),
            images.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captures.heightAnchor.constraint(equalToConstant: 40),
            images.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func refresh(hasPermission: Bool, busy: Bool, shortcutsAvailable: Bool) {
        statusLabel.stringValue = hasPermission
            ? "Capture autorisée. Les images restent sur votre Mac."
            : "Pour capturer l’écran, autorisez ArtShot X dans les réglages macOS. Vous pouvez déjà essayer l’éditeur avec une image."
        permissionButton.isHidden = hasPermission
        captureButtons.forEach { $0.isEnabled = !busy }
        shortcutLabel.stringValue = shortcutsAvailable
            ? "⌃⌥⌘5 Plein écran   ·   ⌃⌥⌘6 Zone   ·   ⌃⌥⌘7 Ce panneau"
            : "Un raccourci est déjà utilisé. Les boutons et le menu de la barre des menus restent disponibles."
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        return button
    }

    @objc private func captureDisplay() { onDisplay?() }
    @objc private func captureRegion() { onRegion?() }
    @objc private func openImage() { onOpenImage?() }
    @objc private func showSample() { onSample?() }
    @objc private func requestPermission() { onPermission?() }
}
