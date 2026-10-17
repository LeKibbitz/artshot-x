import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class VideoPreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private enum Style {
        static let initialSize = NSSize(width: 1060, height: 800)
        static let minimumSize = NSSize(width: 940, height: 650)
        static let fieldWidth: CGFloat = 76
        static let volumeWidth: CGFloat = 150
        static let gap: CGFloat = 10
        static let margin: CGFloat = 20
    }
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
    private let cutStart = NSTextField(string: "0.00")
    private let cutEnd = NSTextField(string: "0.00")
    private let systemVolume = NSSlider(value: 100, minValue: 0, maxValue: 200, target: nil, action: nil)
    private let micVolume = NSSlider(value: 100, minValue: 0, maxValue: 200, target: nil, action: nil)
    private let systemVolumeLabel = NSTextField(labelWithString: "100 %")
    private let micVolumeLabel = NSTextField(labelWithString: "100 %")
    private let playhead = NSTextField(labelWithString: "Original : 0,00 s")
    private let cutsSummary = NSTextField(labelWithString: "Aucun passage retiré")
    private var undoButton: NSButton!
    private var cutButtons: [NSButton] = []
    private var cuts: [RecordingCut] = []
    private var cutHistory: [[RecordingCut]] = []
    private var timeline: RecordingEditTimeline?
    private let status = NSTextField(labelWithString: "Chargement…")
    private var saveButton: NSButton!
    private var applyButton: NSButton!
    private var duration = 0.0
    private var observer: Any?
    private var reloadID = UUID()
    private var exportTask: Task<Void, Never>?
    private var currentEdit = RecordingEdit()
    private var isClosed = false
    private var isPreparing = true
    private var resumeAfterReload = false

    init(url: URL) {
        self.url = url
        self.metadata = RecordingMetadata.read(url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Style.initialSize.width, height: Style.initialSize.height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ArtShot X · Vidéo"
        window.subtitle = "Aperçu et montage"
        window.minSize = Style.minimumSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.center()
        configure()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.effects.time = time.seconds
                self.playhead.stringValue = "Original : \(self.seconds(self.sourcePosition)) s"
                self.effects.needsDisplay = true
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.duration = try await AVURLAsset(url: url).load(.duration).seconds
                guard self.duration.isFinite, self.duration > 0 else { throw RecordingFailure.message("Cette vidéo est vide ou illisible.") }
                guard !self.isClosed else { return }
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
        for field in [start, end, cutStart, cutEnd] {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: Style.fieldWidth).isActive = true
        }
        start.setAccessibilityLabel("Début conservé en secondes")
        end.setAccessibilityLabel("Fin conservée en secondes")
        cutStart.setAccessibilityLabel("Début du passage à retirer, dans l’original")
        cutEnd.setAccessibilityLabel("Fin du passage à retirer, dans l’original")
        applyButton = button("Appliquer", #selector(applyTrim))
        saveButton = button("Enregistrer MP4…", #selector(saveDocument(_:)))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.isEnabled = false
        let audio = row([
            volumeGroup("Son du Mac", slider: systemVolume, value: systemVolumeLabel, available: metadata?.hasSystemAudio == true),
            volumeGroup("Microphone", slider: micVolume, value: micVolumeLabel, available: metadata?.hasMicrophone == true)
        ])
        audio.isHidden = metadata?.hasSystemAudio != true && metadata?.hasMicrophone != true
        let trim = row([label("Conserver de"), start, label("à"), end, label("s"), applyButton])
        let markStart = button("Début ici", #selector(markCutStart))
        let markEnd = button("Fin ici", #selector(markCutEnd))
        let remove = button("Retirer ce passage", #selector(removePassage))
        cutButtons = [markStart, markEnd, remove]
        let cut = row([label("Retirer de"), cutStart, markStart, label("à"), cutEnd, markEnd, label("s"), remove])
        undoButton = button("Annuler le retrait", #selector(undo(_:)))
        undoButton.isEnabled = false
        cutsSummary.lineBreakMode = .byTruncatingMiddle
        cutsSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let history = row([cutsSummary, NSView(), undoButton])
        let help = label("Les temps sont ceux de l’original. Placez la lecture, marquez le début et la fin, puis retirez le passage.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        playhead.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let actions = row([playhead, NSView(), saveButton])
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [options, audio, trim, cut, help, history, actions, status])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = Style.gap
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Style.gap),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Style.margin),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Style.margin),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Style.gap),
            history.widthAnchor.constraint(equalTo: footer.widthAnchor),
            actions.widthAnchor.constraint(equalTo: footer.widthAnchor),
            status.widthAnchor.constraint(equalTo: footer.widthAnchor),
            effects.topAnchor.constraint(equalTo: playerView.topAnchor),
            effects.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            effects.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            effects.trailingAnchor.constraint(equalTo: playerView.trailingAnchor)
        ])
        setPreparing(true)
    }

    private func label(_ title: String) -> NSTextField { NSTextField(labelWithString: title) }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Style.gap
        return stack
    }
    private func volumeGroup(_ title: String, slider: NSSlider, value: NSTextField, available: Bool) -> NSView {
        slider.target = self
        slider.action = #selector(volumeChanged)
        slider.isContinuous = false
        slider.widthAnchor.constraint(equalToConstant: Style.volumeWidth).isActive = true
        slider.setAccessibilityLabel("Volume \(title), de 0 à 200 pour cent")
        slider.toolTip = "100 % = volume enregistré ; au-delà, le son peut saturer."
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let group = row([label(title), slider, value])
        group.isHidden = !available
        return group
    }
    private func seconds(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "fr_FR"), value.isFinite ? value : 0)
    }
    private var sourcePosition: Double {
        let time = player.currentTime().seconds
        return timeline?.sourceTime(forOutputTime: time.isFinite ? time : 0) ?? 0
    }
    private func setPreparing(_ preparing: Bool) {
        isPreparing = preparing
        let editable = !preparing && exportTask == nil && duration > 0
        saveButton.isEnabled = editable
        applyButton.isEnabled = editable
        cutButtons.forEach { $0.isEnabled = editable }
        undoButton.isEnabled = editable && !cutHistory.isEmpty
        [start, end, cutStart, cutEnd].forEach { $0.isEnabled = editable }
        [camera, system, mic, clicks, keys].forEach { $0.isEnabled = editable }
        systemVolume.isEnabled = editable && system.state == .on
        micVolume.isEnabled = editable && mic.state == .on
    }

    private func readEdit() throws -> RecordingEdit {
        let startValue = Double(start.stringValue.replacingOccurrences(of: ",", with: "."))
        let endValue = Double(end.stringValue.replacingOccurrences(of: ",", with: "."))
        guard let startValue, let endValue, startValue.isFinite, endValue.isFinite, startValue >= 0, endValue > startValue, startValue < duration, endValue <= duration + 0.02 else {
            throw RecordingFailure.message("Indiquez un début et une fin valides, en secondes, entre 0 et \(String(format: "%.2f", duration)).")
        }
        return RecordingEdit(camera: camera.state == .on, systemAudio: system.state == .on, microphone: mic.state == .on, clicks: clicks.state == .on, keys: keys.state == .on, start: startValue, end: min(endValue, duration),
                             systemAudioVolume: systemVolume.doubleValue / 100,
                             microphoneVolume: micVolume.doubleValue / 100, cuts: cuts)
    }

    @objc private func changed() { reload() }
    @objc private func applyTrim() { reload() }

    @objc private func volumeChanged() {
        systemVolumeLabel.stringValue = "\(Int(systemVolume.doubleValue.rounded())) %"
        micVolumeLabel.stringValue = "\(Int(micVolume.doubleValue.rounded())) %"
        reload()
    }
    @objc private func markCutStart() { cutStart.stringValue = seconds(sourcePosition) }
    @objc private func markCutEnd() { cutEnd.stringValue = seconds(sourcePosition) }
    @objc private func removePassage() {
        guard let from = Double(cutStart.stringValue.replacingOccurrences(of: ",", with: ".")),
              let to = Double(cutEnd.stringValue.replacingOccurrences(of: ",", with: ".")),
              from.isFinite, to.isFinite, from >= 0, to > from, to <= duration + 0.02 else {
            showError(RecordingFailure.message("Le passage à retirer doit avoir un début et une fin valides dans l’original.")); return
        }
        do {
            var edit = try readEdit()
            edit.cuts.append(RecordingCut(start: from, end: min(to, duration)))
            let candidate = try RecordingEditTimeline(duration: duration, edit: edit)
            let previous = try RecordingEditTimeline(duration: duration, edit: readEdit())
            guard candidate.duration < previous.duration - 0.001 else {
                throw RecordingFailure.message("Ce passage est déjà retiré ou se trouve hors de la partie conservée.")
            }
            cutHistory.append(cuts)
            cuts = edit.cuts
            refreshCuts()
            reload()
        } catch { showError(error) }
    }
    @objc func undo(_ sender: Any?) {
        guard !isPreparing, exportTask == nil, let previous = cutHistory.popLast() else { return }
        cuts = previous
        refreshCuts()
        reload()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return !isPreparing && exportTask == nil && !cutHistory.isEmpty }
        if menuItem.action == #selector(saveDocument(_:)) { return saveButton.isEnabled }
        return true
    }
    private func refreshCuts() {
        let ranges = cuts.map { "\(seconds($0.start))–\(seconds($0.end)) s" }.joined(separator: " · ")
        cutsSummary.stringValue = cuts.isEmpty ? "Aucun passage retiré" : "Passages retirés : \(ranges)"
        cutsSummary.toolTip = cutsSummary.stringValue
        undoButton.isEnabled = !cutHistory.isEmpty
    }

    private func reload() {
        let token = UUID()
        reloadID = token
        let absolutePosition = sourcePosition
        let edit: RecordingEdit
        do {
            edit = try readEdit()
            _ = try RecordingEditTimeline(duration: duration, edit: edit)
        } catch {
            setPreparing(false)
            saveButton.isEnabled = false
            showError(error)
            return
        }
        resumeAfterReload = resumeAfterReload || player.rate > 0
        player.pause()
        status.stringValue = "Préparation de l’aperçu…"
        setPreparing(true)
        Task {
            do {
                let prepared = try await RecordingComposition.prepare(url: url, edit: edit)
                guard !isClosed, reloadID == token else { return }
                let composition = prepared.composition
                let videoComposition = prepared.videoComposition
                let outputPosition = prepared.timeline.outputTime(forSourceTime: absolutePosition)
                    ?? prepared.timeline.segments.first(where: { $0.sourceStart >= absolutePosition })?.outputStart
                    ?? prepared.timeline.duration
                let position = CMTime(seconds: max(0, outputPosition), preferredTimescale: 600)
                timeline = prepared.timeline
                currentEdit = edit
                // Core Animation overlays are rendered for exports; native view draws them during playback.
                videoComposition.animationTool = nil
                let item = AVPlayerItem(asset: composition)
                item.videoComposition = videoComposition
                item.audioMix = prepared.audioMix
                player.replaceCurrentItem(with: item)
                effects.events = prepared.events
                effects.videoSize = videoComposition.renderSize
                effects.showClicks = edit.clicks
                effects.showKeys = edit.keys
                await player.seek(to: min(position, composition.duration), toleranceBefore: .zero, toleranceAfter: .zero)
                guard !isClosed, reloadID == token else { return }
                if resumeAfterReload { player.play() }
                resumeAfterReload = false
                status.stringValue = metadata?.warning ?? "\(seconds(prepared.timeline.duration)) s après montage · Original conservé"
                setPreparing(false)
            } catch {
                guard !isClosed, reloadID == token else { return }
                setPreparing(false)
                saveButton.isEnabled = false
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
            self.setPreparing(true)
            self.status.stringValue = "Export MP4 en cours…"
            self.exportTask = Task {
                defer {
                    self.exportTask = nil
                    self.setPreparing(false)
                }
                do {
                    try await RecordingComposition.export(url: self.url, edit: edit, to: destination)
                    self.status.stringValue = "Enregistré : \(destination.lastPathComponent)"
                } catch {
                    self.status.stringValue = "L’export a échoué"
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
            guard age >= 0, age < (event.duration ?? (event.label == nil ? 0.6 : 1.25)) else { continue }
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
