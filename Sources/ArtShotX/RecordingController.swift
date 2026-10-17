import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class RecordingController: NSObject, NSWindowDelegate {
    var onCompleted: ((URL) -> Void)?
    var onError: ((Error) -> Void)?
    var onStateChanged: (() -> Void)?
    var isBusy: Bool { optionsWindow != nil || isSelecting || isStarting || isRecording || isFinishing }
    var isFinalizing: Bool { isFinishing }
    private(set) var isRecording = false { didSet { onStateChanged?() } }
    private var isStarting = false { didSet { onStateChanged?() } }
    private var isFinishing = false { didSet { onStateChanged?() } }
    private var isSelecting = false { didSet { onStateChanged?() } }
    private var generation = UUID()
    private var startupFailure: Error?
    private var recorder: ScreenRecorder?
    private var optionsWindow: NSWindow?
    private let controls = RecordingControlBar()
    private let cameraOverlay = CameraOverlayController()
    private var cameraSource: LiveCameraSource?
    private var cameraGeneration = UUID()
    private var cameraReady = false
    private var cameraLayout = CameraLayout.default
    private var screen: NSScreen?
    private let regionSelector = SelectionOverlayController()
    private var monitors: [Any] = []
    private var options = RecordingOptions()
    private var sourceRegion: CGRect?
    private let regionButton = NSButton(checkboxWithTitle: "Sélectionner une zone", target: nil, action: nil)
    private let cameraButton = NSButton(checkboxWithTitle: "Caméra en incrustation", target: nil, action: nil)
    private let microphoneButton = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)
    private let systemButton = NSButton(checkboxWithTitle: "Son du système", target: nil, action: nil)
    private let cursorButton = NSButton(checkboxWithTitle: "Afficher le curseur", target: nil, action: nil)
    private let clicksButton = NSButton(checkboxWithTitle: "Mettre en évidence les clics", target: nil, action: nil)
    private let keysButton = NSButton(checkboxWithTitle: "Afficher les raccourcis et touches spéciales", target: nil, action: nil)
    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private let startButton = NSButton(title: "Démarrer", target: nil, action: nil)
    private let shapeControl = NSSegmentedControl(labels: ["Rond", "Carré", "Arrondi"], trackingMode: .selectOne, target: nil, action: nil)
    private let sizeControl = NSSlider(value: 0.23, minValue: 0.12, maxValue: 0.45, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "23 %")
    private let cameraStatus = NSTextField(wrappingLabelWithString: "")
    private var status = "Préparation…"
    private enum Style {
        static let optionsSize = CGSize(width: 470, height: 590)
        static let inset: CGFloat = 24
        static let spacing: CGFloat = 14
        static let sliderWidth: CGFloat = 180
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "recording.cameraLayout"),
           let saved = try? JSONDecoder().decode(CameraLayout.self, from: data) { cameraLayout = saved }
        controls.onStop = { [weak self] in self?.stop() }
        controls.onCancel = { [weak self] in self?.cancel() }
        controls.onShowCamera = { [weak self] in self?.showCamera(editable: false) }
        cameraOverlay.onLayoutChanged = { [weak self] layout in
            guard let self, !self.isRecording, !self.isStarting else { return }
            self.cameraLayout = layout
            self.saveCameraLayout()
        }
        cameraButton.target = self
        cameraButton.action = #selector(cameraToggled)
        regionButton.target = self
        regionButton.action = #selector(regionToggled)
        shapeControl.target = self
        shapeControl.action = #selector(layoutChanged)
        sizeControl.target = self
        sizeControl.action = #selector(layoutChanged)
        sizeControl.isContinuous = true
        sizeControl.widthAnchor.constraint(equalToConstant: Style.sliderWidth).isActive = true
        sizeControl.setAccessibilityLabel("Taille de la vignette caméra")
        shapeControl.setAccessibilityLabel("Forme de la vignette caméra")
        startButton.target = self
        startButton.action = #selector(startPressed)
    }

    /// The same command behind shortcut 7 reveals the active recording controls.
    @discardableResult
    func revealActiveControls() -> Bool {
        if isStarting || isRecording || isFinishing {
            if let screen { controls.show(on: screen); refreshControls() }
            showCamera(editable: false)
            return true
        }
        if let optionsWindow {
            optionsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return isSelecting
    }

    func present(on screen: NSScreen) {
        if revealActiveControls() { return }
        self.screen = screen
        sourceRegion = nil
        regionButton.state = .off
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Style.optionsSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Enregistrer une vidéo"
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.delegate = self
        let headline = NSTextField(labelWithString: "Écran : \(screen.localizedName)")
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        cursorButton.state = .on
        let note = NSTextField(wrappingLabelWithString: "Caméra, sons, clics et raccourcis restent modifiables dans l’éditeur. Le curseur est intégré à la vidéo. Aucun texte saisi n’est enregistré.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, startButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        shapeControl.selectedSegment = CameraShape.allCases.firstIndex(of: cameraLayout.shape) ?? 2
        sizeControl.doubleValue = cameraLayout.widthFraction
        sizeLabel.stringValue = "\(Int(sizeControl.doubleValue * 100)) %"
        let sizing = NSStackView(views: [NSTextField(labelWithString: "Taille"), sizeControl, sizeLabel])
        sizing.orientation = .horizontal
        cameraStatus.font = .systemFont(ofSize: 12)
        cameraStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [headline, regionButton, cameraButton, shapeControl, sizing, cameraStatus, microphoneButton, systemButton, cursorButton, clicksButton, keysButton, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Style.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: Style.inset),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -Style.inset),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: Style.inset),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -Style.inset)
        ])
        optionsWindow = window
        onStateChanged?()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        cameraToggled()
    }

    @objc private func layoutChanged() {
        guard !isStarting, !isRecording else { return }
        cameraLayout.shape = CameraShape.allCases[max(0, shapeControl.selectedSegment)]
        cameraLayout.widthFraction = sizeControl.doubleValue
        sizeLabel.stringValue = "\(Int(sizeControl.doubleValue * 100)) %"
        saveCameraLayout()
        showCamera(editable: true)
    }

    private func saveCameraLayout() {
        if let data = try? JSONEncoder().encode(cameraLayout) { UserDefaults.standard.set(data, forKey: "recording.cameraLayout") }
    }

    private func showCamera(editable: Bool) {
        guard cameraSource != nil, let screen else { return }
        cameraOverlay.show(in: sourceRegion ?? screen.frame, layout: cameraLayout, editable: editable)
    }

    @objc private func cameraToggled() {
        let enabled = cameraButton.state == .on
        shapeControl.isEnabled = enabled
        sizeControl.isEnabled = enabled
        stopCamera()
        startButton.isEnabled = !enabled
        cameraStatus.stringValue = enabled ? "Ouverture de la caméra…" : "Activez la caméra pour régler sa vignette avant de démarrer."
        guard enabled, optionsWindow != nil else { return }
        let token = UUID()
        cameraGeneration = token
        let source = LiveCameraSource(onImage: { [weak self] image in
            guard let self, self.cameraGeneration == token else { return }
            self.cameraReady = true
            self.cameraOverlay.update(image: image)
            self.startButton.isEnabled = true
            self.cameraStatus.stringValue = "Déplacez la vignette à l’endroit souhaité. Ce réglage sera conservé dans toute la vidéo."
        }, onFailure: { [weak self] error in
            guard let self, self.cameraGeneration == token else { return }
            self.cameraReady = false
            self.startButton.isEnabled = false
            self.cameraStatus.stringValue = error.localizedDescription
            if self.isRecording || self.isStarting { self.recorder?.cameraFailed(error) }
            self.stopCamera()
        })
        cameraSource = source
        showCamera(editable: true)
        Task {
            do {
                try await authorize(.video, name: "caméra")
                guard cameraGeneration == token else { return }
                try await source.start()
                if cameraGeneration != token { await source.stop() }
            } catch {
                guard cameraGeneration == token else { return }
                cameraStatus.stringValue = error.localizedDescription
                stopCamera()
            }
        }
    }

    private func stopCamera() {
        cameraGeneration = UUID()
        cameraReady = false
        let source = cameraSource
        cameraSource = nil
        cameraOverlay.close()
        if let source { Task { await source.stop() } }
    }

    @objc private func regionToggled() {
        guard let screen else { return }
        guard regionButton.state == .on else { sourceRegion = nil; showCamera(editable: true); return }
        isSelecting = true
        optionsWindow?.orderOut(nil)
        cameraOverlay.close()
        regionSelector.begin(on: screen) { [weak self] rect in
            guard let self else { return }
            self.isSelecting = false
            self.sourceRegion = rect
            if rect == nil { self.regionButton.state = .off }
            self.optionsWindow?.makeKeyAndOrderFront(nil)
            self.showCamera(editable: true)
        }
    }

    @objc private func startPressed() {
        guard let screen, !isStarting, cameraButton.state != .on || cameraReady else { return }
        options = RecordingOptions(camera: cameraButton.state == .on, microphone: microphoneButton.state == .on, systemAudio: systemButton.state == .on, cursor: cursorButton.state == .on, clicks: clicksButton.state == .on, keys: keysButton.state == .on)
        options.cameraLayout = cameraLayout
        let window = optionsWindow
        optionsWindow = nil
        window?.close()
        showCamera(editable: false)
        beginRecording(on: screen)
    }

    private func beginRecording(on screen: NSScreen) {
        let token = UUID()
        generation = token
        startupFailure = nil
        isStarting = true
        status = "Préparation…"
        controls.show(on: screen)
        refreshControls()
        Task {
            let recorder = ScreenRecorder()
            self.recorder = recorder
            do {
                if options.microphone { try await authorize(.audio, name: "microphone") }
                guard generation == token else {
                    isStarting = false
                    self.recorder = nil
                    return
                }
                if options.keys || options.clicks {
                    // NSEvent global key monitoring requires Accessibility. Request only when selected.
                    if !AXIsProcessTrusted() {
                        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(prompt)
                        throw RecordingFailure.message("Autorisez ArtShot X dans Réglages Système → Confidentialité et sécurité → Accessibilité, puis relancez l’enregistrement avec clics ou raccourcis.")
                    }
                }
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    throw RecordingFailure.message("Impossible d’identifier l’écran.")
                }
                var rect: CGRect?
                if let region = sourceRegion {
                    rect = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
                }
                recorder.onFailure = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == token, !self.isFinishing else { return }
                        if self.isStarting { self.startupFailure = error; return }
                        self.finish(cancel: false)
                    }
                }
                if options.camera {
                    guard cameraReady, let cameraSource else { throw RecordingFailure.message("La caméra n’est plus disponible.") }
                    await cameraSource.setBufferHandler { [weak recorder] frame in recorder?.receiveCameraFrame(frame) }
                }
                try await recorder.start(displayID: id.uint32Value, sourceRect: rect, options: options, externalCamera: options.camera)
                guard generation == token else {
                    _ = try? await recorder.finish(cancel: true)
                    isStarting = false
                    self.recorder = nil
                    return
                }
                if let startupFailure { throw startupFailure }
                isStarting = false
                isRecording = true
                startedAt = Date()
                installMonitors(screen: screen)
                updateElapsed()
                elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateElapsed() }
                }
            } catch {
                _ = try? await recorder.finish(cancel: true)
                isStarting = false
                self.recorder = nil
                closeControls()
                stopCamera()
                if generation == token { onError?(error) }
            }
        }
    }

    private func authorize(_ media: AVMediaType, name: String) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: media)
        let allowed: Bool
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: media) }
        else { allowed = status == .authorized }
        guard allowed else {
            throw RecordingFailure.message("Accès au \(name) refusé. Autorisez ArtShot X dans Réglages Système → Confidentialité et sécurité.")
        }
    }

    func stop() { finish(cancel: false) }
    func cancel() {
        regionSelector.cancel()
        optionsWindow?.close()
        optionsWindow = nil
        stopCamera()
        finish(cancel: true)
    }
    @objc private func stopPressed() { stop() }
    @objc private func cancelPressed() { cancel() }

    private func finish(cancel: Bool) {
        guard !isFinishing else { return }
        generation = UUID()
        stopCamera()
        if isStarting {
            // The startup task owns cleanup until ScreenCaptureKit has finished starting.
            closeControls()
            return
        }
        guard let recorder else { isStarting = false; closeControls(); return }
        isFinishing = true
        isRecording = false
        isStarting = false
        removeMonitors()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        status = cancel ? "Annulation…" : "Finalisation…"
        refreshControls()
        Task {
            do {
                let url = try await recorder.finish(cancel: cancel)
                self.recorder = nil
                isFinishing = false
                closeControls()
                if let url {
                    onCompleted?(url)
                    if let warning = recorder.completionWarning ?? RecordingMetadata.read(url)?.warning {
                        let alert = NSAlert()
                        alert.messageText = "Vidéo conservée avec un avertissement"
                        alert.informativeText = warning
                        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: nil) }
                        else { alert.runModal() }
                    }
                }
            } catch {
                self.recorder = nil
                isFinishing = false
                closeControls()
                onError?(error)
            }
        }
    }

    private func refreshControls() {
        controls.update(status: status, canStop: isRecording, canCancel: !isFinishing,
                        cameraEnabled: cameraSource != nil)
    }

    private func closeControls() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        controls.close()
    }

    private func updateElapsed() {
        let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
        status = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        refreshControls()
    }

    private func installMonitors(screen: NSScreen) {
        guard options.clicks || options.keys else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.record(event, screen: screen) }) { monitors.append(monitor) }
        // Events in ArtShot X itself are intentionally excluded with its windows.
    }
    private func removeMonitors() { monitors.forEach(NSEvent.removeMonitor); monitors.removeAll() }

    private func record(_ event: NSEvent, screen: NSScreen) {
        guard isRecording else { return }
        if event.type == .keyDown, options.keys {
            if let label = Self.safeKeyLabel(event) { recorder?.addEvent(label: label) }
        } else if options.clicks, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            let point = NSEvent.mouseLocation
            let region = sourceRegion ?? screen.frame
            guard region.contains(point) else { return }
            recorder?.addEvent(x: (point.x - region.minX) / region.width, y: (region.maxY - point.y) / region.height)
        }
    }

    static func safeKeyLabel(_ event: NSEvent) -> String? { RecordingShortcutLabel.make(event) }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === optionsWindow {
            optionsWindow = nil
            stopCamera()
            onStateChanged?()
        }
    }
}
