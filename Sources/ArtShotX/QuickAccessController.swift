import AppKit
import AVFoundation

@MainActor
final class QuickAccessController: NSWindowController {
    var onEdit: ((CaptureItem) -> Void)?
    var onSave: ((CaptureItem) -> Void)?
    var onCopy: ((CaptureItem) -> Void)?
    var onDiscard: ((CaptureItem) -> Void)?
    private var item: CaptureItem?
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "Capture prête")
    private var copyButton: NSButton!
    private var posterTask: Task<Void, Never>?

    init() {
        let panel = ThumbnailPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 264),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Dernière capture")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(editCapture))
        imageView.addGestureRecognizer(gesture)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        let delete = button("Supprimer", symbol: "trash", action: #selector(discardCapture))
        let edit = button("Modifier", symbol: "pencil", action: #selector(editCapture))
        let save = button("Enregistrer", symbol: "square.and.arrow.down", action: #selector(saveCapture))
        copyButton = button("Copier", symbol: "doc.on.doc", action: #selector(copyCapture))
        let buttons = NSStackView(views: [delete, edit, save, copyButton])
        buttons.distribution = .fillEqually
        buttons.spacing = 4
        let stack = NSStackView(views: [imageView, caption, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 154),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func present(_ item: CaptureItem, on screen: NSScreen) {
        self.item = item
        posterTask?.cancel()
        caption.stringValue = item.kind == .image ? "Capture prête · cliquez pour modifier" : "Vidéo prête · cliquez pour modifier"
        copyButton.title = "Copier"
        copyButton.isEnabled = item.kind == .image
        imageView.image = item.kind == .image ? NSImage(contentsOf: item.url)
            : NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Vidéo")
        if item.kind == .video {
            posterTask = Task { [weak self] in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                if let result = try? await generator.image(at: .zero), !Task.isCancelled, self?.item?.id == item.id {
                    self?.imageView.image = NSImage(cgImage: result.image, size: .zero)
                }
            }
        }
        let frame = screen.visibleFrame
        window?.setFrameOrigin(CGPoint(x: frame.minX + 18, y: frame.minY + 18))
        window?.orderFrontRegardless()
    }

    func dismiss() { window?.orderOut(nil) }
    func showCopied() { copyButton.title = "Copié" }
    func showSaving() { caption.stringValue = "Enregistrement du fichier…" }
    func showSaved() { caption.stringValue = "Fichier enregistré" }
    func showSaveFailed() { caption.stringValue = "Échec de l’enregistrement · réessayez" }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .recessed
        button.imagePosition = .imageAbove
        button.font = .systemFont(ofSize: 10)
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func editCapture() { if let item { onEdit?(item) } }
    @objc private func saveCapture() { if let item { onSave?(item) } }
    @objc private func copyCapture() { if let item { onCopy?(item) } }
    @objc private func discardCapture() { if let item { onDiscard?(item) } }
}

@MainActor
private final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
