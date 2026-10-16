import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class VideoPreviewWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var isExporting: Bool { exportTask != nil }
    private let url: URL
    private let metadata: RecordingMetadata?
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let effects = VideoPreviewEffectsView()
    private let camera = NSButton(checkboxWithTitle: "Caméra", target: nil, action: nil)
    private let system = NSButton(checkboxWithTitle: "Son système", target: nil, action: nil)
    private let mic = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)
    private let clicks = NSButton(checkboxWithTitle: "Clics", target: nil, action: nil)
    private let keys = NSButton(checkboxWithTitle: "Raccourcis", target: nil, action: nil)
    private let start = NSTextField(string: "0.00")
    private let end = NSTextField(string: "0.00")
    private let status = NSTextField(labelWithString: "Chargement…")
    private var saveButton: NSButton!
    private var applyButton: NSButton!
    private var duration = 0.0
    private var observer: Any?
    private var reloadID = UUID()
    private var exportTask: Task<Void, Never>?
    private var currentEdit = RecordingEdit()
    private var isClosed = false

    init(url: URL) {
        self.url = url
        self.metadata = RecordingMetadata.read(url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ArtShot X · Vidéo"
        window.subtitle = "Aperçu et montage"
        window.minSize = NSSize(width: 780, height: 480)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.center()
        configure()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.effects.time = time.seconds + self.currentEdit.start
                self.effects.needsDisplay = true
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.duration = try await AVURLAsset(url: url).load(.duration).seconds
                guard self.duration.isFinite, self.duration > 0 else { throw RecordingFailure.message("Cette vidéo est vide ou illisible.") }
                self.end.stringValue = String(format: "%.2f", self.duration)
                self.currentEdit.end = self.duration
                self.reload()
            } catch { self.showError(error); self.status.stringValue = "Vidéo indisponible" }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func configure() {
        let content = window!.contentView!
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)
        effects.translatesAutoresizingMaskIntoConstraints = false
        effects.events = metadata?.events ?? []
        playerView.addSubview(effects)
        let toggles = [camera, system, mic, clicks, keys]
        for button in toggles {
            button.state = .on
            button.target = self
            button.action = #selector(changed)
        }
        camera.isHidden = metadata?.hasCamera != true
        system.isHidden = metadata?.hasSystemAudio != true
        mic.isHidden = metadata?.hasMicrophone != true
        clicks.isHidden = metadata?.options.clicks != true
        keys.isHidden = metadata?.options.keys != true
        let options = NSStackView(views: toggles)
        options.orientation = .horizontal
        options.spacing = 18
        options.alignment = .centerY
        let cursorNote = NSTextField(labelWithString: metadata?.options.cursor == true ? "Curseur intégré à l’image" : "")
        cursorNote.font = .systemFont(ofSize: 11)
        cursorNote.textColor = .secondaryLabelColor
        for field in [start, end] {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        }
        start.setAccessibilityLabel("Début en secondes")
        end.setAccessibilityLabel("Fin en secondes")
        applyButton = NSButton(title: "Appliquer la coupe", target: self, action: #selector(applyTrim))
        applyButton.bezelStyle = .rounded
        saveButton = NSButton(title: "Enregistrer MP4…", target: self, action: #selector(saveDocument(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.isEnabled = false
        let trim = NSStackView(views: [NSTextField(labelWithString: "Début (s)"), start, NSTextField(labelWithString: "Fin (s)"), end, applyButton, NSView(), saveButton])
        trim.orientation = .horizontal
        trim.spacing = 10
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [options, cursorNote, trim, status])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            trim.widthAnchor.constraint(equalTo: footer.widthAnchor),
            effects.topAnchor.constraint(equalTo: playerView.topAnchor),
            effects.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            effects.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            effects.trailingAnchor.constraint(equalTo: playerView.trailingAnchor)
        ])
    }

    private func readEdit() throws -> RecordingEdit {
        let startValue = Double(start.stringValue.replacingOccurrences(of: ",", with: "."))
        let endValue = Double(end.stringValue.replacingOccurrences(of: ",", with: "."))
        guard let startValue, let endValue, startValue.isFinite, endValue.isFinite, startValue >= 0, endValue > startValue, startValue < duration, endValue <= duration + 0.02 else {
            throw RecordingFailure.message("Indiquez un début et une fin valides, en secondes, entre 0 et \(String(format: "%.2f", duration)).")
        }
        return RecordingEdit(camera: camera.state == .on, systemAudio: system.state == .on, microphone: mic.state == .on, clicks: clicks.state == .on, keys: keys.state == .on, start: startValue, end: min(endValue, duration))
    }

    @objc private func changed() { reload() }
    @objc private func applyTrim() { reload() }

    private func reload() {
        let absolutePosition = currentEdit.start + player.currentTime().seconds
        do { currentEdit = try readEdit() } catch { showError(error); return }
        let edit = currentEdit
        let token = UUID()
        reloadID = token
        let position = CMTime(seconds: max(0, absolutePosition - edit.start), preferredTimescale: 600)
        let wasPlaying = player.rate > 0
        player.pause()
        status.stringValue = "Préparation de l’aperçu…"
        saveButton.isEnabled = false
        Task {
            do {
                let (composition, videoComposition) = try await RecordingComposition.make(url: url, edit: edit)
                guard !isClosed, reloadID == token else { return }
                // Core Animation overlays are rendered for exports; native view draws them during playback.
                videoComposition.animationTool = nil
                let item = AVPlayerItem(asset: composition)
                item.videoComposition = videoComposition
                player.replaceCurrentItem(with: item)
                effects.videoSize = videoComposition.renderSize
                effects.showClicks = edit.clicks
                effects.showKeys = edit.keys
                await player.seek(to: min(position, composition.duration), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
                status.stringValue = metadata?.warning ?? String(format: "%.2f s · Les pistes originales sont conservées", edit.end - edit.start)
                saveButton.isEnabled = true
            } catch {
                guard !isClosed, reloadID == token else { return }
                status.stringValue = "Impossible de préparer l’aperçu"
                showError(error)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let window, exportTask == nil else { return }
        let edit: RecordingEdit
        do { edit = try readEdit() } catch { showError(error); return }
        let panel = NSSavePanel()
        panel.title = "Enregistrer la vidéo"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ArtShot X \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")).mp4"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let destination = panel.url else { return }
            guard destination.standardizedFileURL != self.url.standardizedFileURL else {
                self.showError(RecordingFailure.message("Choisissez un autre fichier pour conserver l’original.")); return
            }
            self.player.pause()
            self.saveButton.isEnabled = false
            self.status.stringValue = "Export MP4 en cours…"
            self.exportTask = Task {
                defer { self.exportTask = nil }
                do {
                    try await RecordingComposition.export(url: self.url, edit: edit, to: destination)
                    self.status.stringValue = "Enregistré : \(destination.lastPathComponent)"
                    self.saveButton.isEnabled = true
                } catch {
                    self.status.stringValue = "L’export a échoué"
                    self.saveButton.isEnabled = true
                    if !self.isClosed { self.showError(error) }
                }
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        onClose?()
    }
}

@MainActor
private final class VideoPreviewEffectsView: NSView {
    var events: [RecordingEvent] = []
    var time = 0.0
    var videoSize = CGSize(width: 1920, height: 1080)
    var showClicks = true
    var showKeys = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let rect = CGRect(x: (bounds.width - videoSize.width * scale) / 2, y: (bounds.height - videoSize.height * scale) / 2, width: videoSize.width * scale, height: videoSize.height * scale)
        for event in events.reversed() {
            let age = time - event.time
            guard age >= 0, age <= (event.label == nil ? 0.6 : 1.25) else { continue }
            if let x = event.x, let y = event.y, showClicks {
                let radius = 24 * scale
                let ring = NSBezierPath(ovalIn: CGRect(x: rect.minX + x * rect.width - radius, y: rect.minY + (1-y) * rect.height - radius, width: radius * 2, height: radius * 2))
                NSColor.systemYellow.withAlphaComponent(0.25).setFill()
                ring.fill()
                NSColor.systemYellow.setStroke()
                ring.lineWidth = max(1, 4 * scale)
                ring.stroke()
            } else if let label = event.label, showKeys {
                let box = CGRect(x: rect.midX - 130 * scale, y: rect.minY + 40 * scale, width: 260 * scale, height: 48 * scale)
                NSColor.black.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: box, xRadius: 12 * scale, yRadius: 12 * scale).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                (label as NSString).draw(in: box.insetBy(dx: 4, dy: 5 * scale), withAttributes: [.font: NSFont.systemFont(ofSize: max(11, 27 * scale)), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            }
        }
    }
}
