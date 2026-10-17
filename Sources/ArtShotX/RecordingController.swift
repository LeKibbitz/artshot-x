import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class RecordingController: NSObject, NSWindowDelegate {
    var onCompleted: ((URL) -> Void)?
    var onTakeArchived: ((URL) throws -> Void)?
    var onStopped: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStateChanged: (() -> Void)?
    var isBusy: Bool { optionsWindow != nil || isSelecting || isStarting || isRecording || isFinishing }
    var isFinalizing: Bool { isFinishing }
    private(set) var isRecording = false { didSet { onStateChanged?() } }
    private(set) var isPaused = false
    private var isChangingPause = false
    private var restartAfterFinish = false
    private enum FinishAction { case save, restart, trash }
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
    private let startButton = NSButton(title: "Démarrer", target: nil, action: nil)
    private let shapeControl = NSSegmentedControl(labels: ["Rond", "Carré", "Arrondi", "Ovale vertical"], trackingMode: .selectOne, target: nil, action: nil)
    private let sizeControl = NSSlider(value: 0.23, minValue: 0.12, maxValue: 0.45, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "23 %")
    private let zoomControl = NSSlider(value: 1, minValue: CameraLayout.zoomRange.lowerBound, maxValue: CameraLayout.zoomRange.upperBound, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "1,0×")
    private let cameraStatus = NSTextField(wrappingLabelWithString: "")
    private var status = "Préparation…"
    private enum Style {
        static let optionsSize = CGSize(width: 470, height: 640)
        static let inset: CGFloat = 24
        static let spacing: CGFloat = 14
        static let sliderWidth: CGFloat = 180
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "recording.cameraLayout"),
           let saved = try? JSONDecoder().decode(CameraLayout.self, from: data) { cameraLayout = saved }
        controls.onStop = { [weak self] in self?.stop() }
        controls.onCancel = { [weak self] in self?.discardRecording() }
        controls.onPauseResume = { [weak self] in self?.togglePause() }
        controls.onRestart = { [weak self] in self?.restart() }
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
        zoomControl.target = self
        zoomControl.action = #selector(layoutChanged)
        zoomControl.isContinuous = true
        zoomControl.widthAnchor.constraint(equalToConstant: Style.sliderWidth).isActive = true
        zoomControl.setAccessibilityLabel("Zoom de la caméra")
        zoomControl.toolTip = "Recadrage numérique centré, indépendant de la taille de la vignette"
        shapeControl.setAccessibilityLabel("Forme de la vignette caméra")
        startButton.target = self
        startButton.action = #selector(startPressed)
    }

    /// The same command behind shortcut 7 reveals the active recording controls.
    @discardableResult
    func revealActiveControls() -> Bool {
        if isStarting || isRecording || isFinishing {
            showCamera(editable: false)
            if let screen { controls.show(on: screen); refreshControls() }
            return true
        }
        if let optionsWindow {
            optionsWindow.orderFrontRegardless()
            optionsWindow.makeKey()
            return true
        }
        return isSelecting
    }

    func present(on screen: NSScreen, region: CGRect? = nil) {
        if revealActiveControls() { return }
        self.screen = screen
        sourceRegion = region
        regionButton.state = region == nil ? .off : .on
        let window = RecordingOptionsPanel(contentRect: NSRect(origin: .zero, size: Style.optionsSize), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Enregistrer une vidéo"
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
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
        zoomControl.doubleValue = cameraLayout.effectiveZoom
        updateZoomLabel()
        let sizing = NSStackView(views: [NSTextField(labelWithString: "Taille"), sizeControl, sizeLabel])
        sizing.orientation = .horizontal
        let zooming = NSStackView(views: [NSTextField(labelWithString: "Zoom"), zoomControl, zoomLabel])
        zooming.orientation = .horizontal
        cameraStatus.font = .systemFont(ofSize: 12)
        cameraStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [headline, regionButton, cameraButton, shapeControl, sizing, zooming, cameraStatus, microphoneButton, systemButton, cursorButton, clicksButton, keysButton, note, buttons])
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
        let visible = screen.visibleFrame
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2,
                                      y: max(visible.minY, visible.midY - window.frame.height / 2)))
        window.orderFrontRegardless()
        window.makeKey()
        cameraToggled()
    }

    @objc private func layoutChanged() {
        guard !isStarting, !isRecording else { return }
        cameraLayout.shape = CameraShape.allCases[max(0, shapeControl.selectedSegment)]
        cameraLayout.widthFraction = sizeControl.doubleValue
        cameraLayout.zoom = zoomControl.doubleValue
        sizeLabel.stringValue = "\(Int(sizeControl.doubleValue * 100)) %"
        updateZoomLabel()
        saveCameraLayout()
        showCamera(editable: true)
    }

    private func saveCameraLayout() {
        if let data = try? JSONEncoder().encode(cameraLayout) { UserDefaults.standard.set(data, forKey: "recording.cameraLayout") }
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = String(format: "%.1f×", locale: Locale(identifier: "fr_FR"), zoomControl.doubleValue)
    }

    private func showCamera(editable: Bool) {
        guard cameraSource != nil, let screen else { return }
        cameraOverlay.show(in: sourceRegion ?? screen.frame, layout: cameraLayout, editable: editable)
    }

    @objc private func cameraToggled() {
        let enabled = cameraButton.state == .on
        shapeControl.isEnabled = enabled
        sizeControl.isEnabled = enabled
        zoomControl.isEnabled = enabled
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
        regionSelector.begin(on: screen, confirmation: "valider la zone") { [weak self] rect in
            guard let self else { return }
            self.isSelecting = false
            self.sourceRegion = rect
            if rect == nil { self.regionButton.state = .off }
            self.optionsWindow?.orderFrontRegardless()
            self.optionsWindow?.makeKey()
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
        isPaused = false
        isChangingPause = false
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

    func stop() {
        if isFinishing { restartAfterFinish = false; return }
        finish(cancel: false)
    }

    func togglePause() {
        guard isRecording, !isFinishing, !isChangingPause, let recorder else { return }
        let token = generation
        let paused = !isPaused
        isChangingPause = true
        refreshControls()
        Task {
            await recorder.setPaused(paused)
            guard generation == token, self.recorder === recorder, isRecording else { return }
            isPaused = paused
            isChangingPause = false
            updateElapsed()
        }
    }

    func restart() {
        guard isRecording, !isFinishing, !isChangingPause else { return }
        finish(cancel: false, action: .restart)
    }

    func discardRecording() {
        guard !isFinishing, !isChangingPause else { return }
        if isRecording { finish(cancel: false, action: .trash) }
        else { cancel() }
    }
    func cancel() {
        regionSelector.cancel()
        optionsWindow?.close()
        optionsWindow = nil
        stopCamera()
        finish(cancel: true)
    }
    @objc private func stopPressed() { stop() }
    @objc private func cancelPressed() { cancel() }

    private func finish(cancel: Bool, action: FinishAction = .save) {
        guard !isFinishing else { return }
        generation = UUID()
        restartAfterFinish = action == .restart
        if !restartAfterFinish { stopCamera() }
        if isStarting {
            // The startup task owns cleanup until ScreenCaptureKit has finished starting.
            closeControls()
            return
        }
        guard let recorder else { isStarting = false; closeControls(); return }
        isFinishing = true
        isRecording = false
        isPaused = false
        isChangingPause = false
        isStarting = false
        removeMonitors()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        status = cancel || action == .trash ? "Suppression…" : (action == .restart ? "Nouvelle prise…" : "Finalisation…")
        refreshControls()
        Task {
            do {
                // Leave the live camera running across takes, but detach the previous writer.
                if restartAfterFinish { await cameraSource?.setBufferHandler(nil) }
                let url = try await recorder.finish(cancel: cancel)
                self.recorder = nil
                if action == .restart, restartAfterFinish, let screen {
                    if let url {
                        do { try onTakeArchived?(url) }
                        catch { throw RecordingFailure.message("La prise est conservée à \(url.path), mais son ajout à l’historique a échoué : \(error.localizedDescription)") }
                    }
                    restartAfterFinish = false
                    isFinishing = false
                    beginRecording(on: screen)
                    return
                }
                restartAfterFinish = false
                stopCamera()
                if let url {
                    if action == .trash {
                        // The current take stays recoverable in the macOS Trash.
                        do { try FileManager.default.trashItem(at: url.deletingLastPathComponent(), resultingItemURL: nil) }
                        catch { throw RecordingFailure.message("La prise est conservée à \(url.path). Impossible de la déplacer dans la corbeille : \(error.localizedDescription)") }
                    }
                    isFinishing = false
                    closeControls()
                    if action != .trash { onCompleted?(url) }
                    if let warning = recorder.completionWarning ?? RecordingMetadata.read(url)?.warning {
                        if action == .trash { onStopped?(); return }
                        let alert = NSAlert()
                        alert.messageText = "Vidéo conservée avec un avertissement"
                        alert.informativeText = warning
                        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: nil) }
                        else { alert.runModal() }
                    }
                }
                isFinishing = false
                closeControls()
                onStopped?()
            } catch {
                self.recorder = nil
                restartAfterFinish = false
                stopCamera()
                isFinishing = false
                closeControls()
                if action == .trash, recorder.url.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
                    onStopped?()
                } else { onError?(error) }
            }
        }
    }

    private func refreshControls() {
        let enabled = isRecording && !isFinishing && !isChangingPause
        controls.update(status: status, canStop: enabled, canCancel: !isFinishing && !isChangingPause,
                        canRestart: enabled, canPause: enabled, isPaused: isPaused)
    }

    private func closeControls() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        controls.close()
    }

    private func updateElapsed() {
        guard isRecording, let recorder else { return }
        let token = generation
        Task {
            let elapsed = await recorder.elapsedDuration()
            guard generation == token, self.recorder === recorder, isRecording else { return }
            status = Self.elapsedLabel(elapsed)
            refreshControls()
        }
    }

    static func elapsedLabel(_ elapsed: Double) -> String {
        let seconds = max(0, Int(elapsed.isFinite ? elapsed : 0))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func installMonitors(screen: NSScreen) {
        guard options.clicks || options.keys else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.record(event, screen: screen) }) { monitors.append(monitor) }
        // Events in ArtShot X itself are intentionally excluded with its windows.
    }
    private func removeMonitors() { monitors.forEach(NSEvent.removeMonitor); monitors.removeAll() }

    private func record(_ event: NSEvent, screen: NSScreen) {
        guard isRecording, !isPaused, !isChangingPause else { return }
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

@MainActor
private final class RecordingOptionsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
