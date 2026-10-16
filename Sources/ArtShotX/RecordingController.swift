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
    private var recorder: ScreenRecorder?
    private var optionsWindow: NSWindow?
    private var controlsWindow: NSPanel?
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
    private let statusLabel = NSTextField(labelWithString: "Préparation…")

    func present(on screen: NSScreen) {
        if isRecording { controlsWindow?.orderFrontRegardless(); return }
        guard !isStarting, !isFinishing else { return }
        self.screen = screen
        if let optionsWindow { optionsWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        let start = NSButton(title: "Démarrer", target: self, action: #selector(startPressed))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, start])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let stack = NSStackView(views: [headline, regionButton, cameraButton, microphoneButton, systemButton, cursorButton, clicksButton, keysButton, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        optionsWindow = window
        onStateChanged?()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func startPressed() {
        guard let screen, !isStarting else { return }
        options = RecordingOptions(camera: cameraButton.state == .on, microphone: microphoneButton.state == .on, systemAudio: systemButton.state == .on, cursor: cursorButton.state == .on, clicks: clicksButton.state == .on, keys: keysButton.state == .on)
        optionsWindow?.orderOut(nil)
        optionsWindow?.close()
        optionsWindow = nil
        if regionButton.state == .on {
            isSelecting = true
            regionSelector.begin(on: screen) { [weak self] rect in
                guard let self else { return }
                self.isSelecting = false
                guard let rect else { return }
                self.sourceRegion = rect
                self.beginRecording(on: screen)
            }
        } else { sourceRegion = nil; beginRecording(on: screen) }
    }

    private func beginRecording(on screen: NSScreen) {
        let token = UUID()
        generation = token
        isStarting = true
        showControls(on: screen)
        Task {
            let recorder = ScreenRecorder()
            self.recorder = recorder
            do {
                if options.camera { try await authorize(.video, name: "caméra") }
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
                        guard let self, !self.isFinishing else { return }
                        self.finish(cancel: false)
                    }
                }
                try await recorder.start(displayID: id.uint32Value, sourceRect: rect, options: options)
                guard generation == token else {
                    _ = try? await recorder.finish(cancel: true)
                    isStarting = false
                    self.recorder = nil
                    return
                }
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
        finish(cancel: true)
    }
    @objc private func stopPressed() { stop() }
    @objc private func cancelPressed() { cancel() }

    private func finish(cancel: Bool) {
        guard !isFinishing else { return }
        generation = UUID()
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
        statusLabel.stringValue = cancel ? "Annulation…" : "Finalisation…"
        controlsWindow?.contentView?.subviews.compactMap { $0 as? NSStackView }.first?.views.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = false }
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

    private func showControls(on screen: NSScreen) {
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.maxY - 92, width: 320, height: 60), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ArtShot X · Enregistrement"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let stop = NSButton(title: "Arrêter", target: self, action: #selector(stopPressed))
        stop.bezelStyle = .rounded
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        statusLabel.stringValue = "Préparation…"
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let stack = NSStackView(views: [statusLabel, stop, cancel])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor), stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)])
        controlsWindow = panel
        panel.orderFrontRegardless()
    }

    private func closeControls() { elapsedTimer?.invalidate(); elapsedTimer = nil; controlsWindow?.close(); controlsWindow = nil }
    private func updateElapsed() {
        let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
        statusLabel.stringValue = String(format: "● %02d:%02d", seconds / 60, seconds % 60)
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
        if notification.object as? NSWindow === optionsWindow { optionsWindow = nil; onStateChanged?() }
    }
}
