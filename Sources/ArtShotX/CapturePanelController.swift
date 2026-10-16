import AppKit

@MainActor
final class CapturePanelController: NSWindowController {
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
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "Autoriser la capture…", target: nil, action: nil)
    private var captureButtons: [NSButton] = []
    private var lastImageButton: NSButton!
    private var lastVideoButton: NSButton!
    private var stopButton: NSButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 530),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ArtShot X · Capturer"
        window.isReleasedWhenClosed = false
        window.center()
        let heading = NSTextField(labelWithString: "Que voulez-vous capturer ?")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        let fullscreen = button("Plein écran                         ⌘⌥⇧5", symbol: "rectangle.dashed", action: #selector(captureDisplay))
        let region = button("Sélection de zone                  ⌘⌥⇧6", symbol: "viewfinder", action: #selector(captureRegion))
        let scroll = button("Capture défilante", symbol: "arrow.down.to.line", action: #selector(captureScroll))
        let video = button("Enregistrer l’écran…", symbol: "record.circle", action: #selector(recordVideo))
        captureButtons = [fullscreen, region, scroll, video]
        stopButton = button("Arrêter l’enregistrement", symbol: "stop.circle.fill", action: #selector(stopRecording))
        lastImageButton = button("Dernière capture", symbol: "photo", action: #selector(lastImage))
        lastVideoButton = button("Dernière vidéo", symbol: "film", action: #selector(lastVideo))
        let recent = NSStackView(views: [lastImageButton, lastVideoButton])
        recent.distribution = .fillEqually
        recent.spacing = 10
        let open = button("Ouvrir une image…", symbol: "folder", action: #selector(openImage))
        let sample = button("Image d’essai", symbol: "sparkles", action: #selector(showSample))
        let images = NSStackView(views: [open, sample])
        images.distribution = .fillEqually
        images.spacing = 10
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        let stack = NSStackView(views: [heading, fullscreen, region, scroll, video, stopButton, recent, images, statusLabel, permissionButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recent.widthAnchor.constraint(equalTo: stack.widthAnchor),
            images.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for button in captureButtons + [stopButton].compactMap({ $0 }) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    func refresh(hasPermission: Bool, busy: Bool, shortcutFailures: [String], hasImage: Bool, hasVideo: Bool, isRecording: Bool) {
        var text = hasPermission ? "L’app reste en arrière-plan. ⌘⌥⇧7 ouvre ce menu."
            : "Autorisez la capture dans macOS. L’éditeur fonctionne aussi avec une image existante."
        if !shortcutFailures.isEmpty { text += "\nRaccourci indisponible : " + shortcutFailures.joined(separator: ", ") + ". Fermez l’app qui l’utilise, puis relancez ArtShot X." }
        statusLabel.stringValue = text
        permissionButton.isHidden = hasPermission
        captureButtons.forEach { $0.isEnabled = !busy && !isRecording }
        lastImageButton.isEnabled = hasImage && !busy
        lastVideoButton.isEnabled = hasVideo && !busy
        stopButton.isHidden = !isRecording
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(title.trimmingCharacters(in: .whitespaces))
        return button
    }

    @objc private func captureDisplay() { onDisplay?() }
    @objc private func captureRegion() { onRegion?() }
    @objc private func captureScroll() { onScroll?() }
    @objc private func recordVideo() { onRecord?() }
    @objc private func stopRecording() { onStopRecording?() }
    @objc private func lastImage() { onLastImage?() }
    @objc private func lastVideo() { onLastVideo?() }
    @objc private func openImage() { onOpenImage?() }
    @objc private func showSample() { onSample?() }
    @objc private func requestPermission() { onPermission?() }
}
