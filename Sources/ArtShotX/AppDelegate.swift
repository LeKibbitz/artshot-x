import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum CaptureMode { case display, region, scroll }
    private let capture = CaptureService()
    private let selection = SelectionOverlayController()
    private let scrolling = ScrollingCaptureController()
    private let recording = RecordingController()
    private let library = CaptureLibrary()
    private var panel: CapturePanelController!
    private var quickAccess: QuickAccessController!
    private var previews: [UUID: PreviewWindowController] = [:]
    private var videoPreviews: [UUID: VideoPreviewWindowController] = [:]
    private var statusItem: NSStatusItem?
    private var shortcuts: GlobalShortcuts?
    private var hiddenWindows: [NSWindow] = []
    private weak var previousKeyWindow: NSWindow?
    private var previousExternalApp: NSRunningApplication?
    private var busy = false
    private var presentingOpenPanel = false
    private var quitAfterRecording = false
    private var exportingCapture = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = CapturePanelController()
        quickAccess = QuickAccessController()
        panel.onDisplay = { [weak self] in self?.beginCapture(.display) }
        panel.onRegion = { [weak self] in self?.beginCapture(.region) }
        panel.onScroll = { [weak self] in self?.beginCapture(.scroll) }
        panel.onRecord = { [weak self] in self?.beginRecording(nil) }
        panel.onStopRecording = { [weak self] in self?.recording.stop() }
        panel.onLastImage = { [weak self] in self?.openLastImage(nil) }
        panel.onLastVideo = { [weak self] in self?.openLastVideo(nil) }
        panel.onOpenImage = { [weak self] in self?.openImage(nil) }
        panel.onSample = { [weak self] in self?.showPreview(DemoImage.make()) }
        panel.onPermission = { [weak self] in self?.requestPermission(nil) }
        quickAccess.onEdit = { [weak self] in self?.editCapture($0) }
        quickAccess.onSave = { [weak self] in self?.saveCapture($0) }
        quickAccess.onCopy = { [weak self] in self?.copyCapture($0) }
        quickAccess.onDiscard = { [weak self] in self?.discardCapture($0) }
        recording.onCompleted = { [weak self] url in
            guard let self else { return }
            do {
                let item = try self.library.add(video: url)
                if self.quitAfterRecording { self.recordingFinishedBeforeQuit(); return }
                self.panel.window?.orderOut(nil)
                if let screen = self.currentScreen { self.quickAccess.present(item, on: screen) }
                self.refreshPanel()
            } catch { self.showError(error) }
        }
        recording.onError = { [weak self] error in
            self?.quitAfterRecording = false
            self?.refreshPanel()
            self?.showError(error)
        }
        recording.onStateChanged = { [weak self] in
            guard let self else { return }
            self.refreshPanel()
            self.statusItem?.button?.image = NSImage(systemSymbolName: self.recording.isRecording ? "record.circle.fill" : "camera.viewfinder", accessibilityDescription: "ArtShot X")
        }
        configureMenus()
        shortcuts = GlobalShortcuts { [weak self] id in
            switch id {
            case 1: self?.beginCapture(.display)
            case 2: self?.beginCapture(.region)
            default: self?.showPanel(nil)
            }
        }
        refreshPanel()
        // Normal launches remain silent. The explicit flag also supports local UI acceptance checks.
        if CommandLine.arguments.contains("--show-capture-panel") { showPanel(nil) }
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPanel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.unregister()
        selection.cancel()
        scrolling.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if exportingCapture || videoPreviews.values.contains(where: { $0.isExporting }) { return .terminateCancel }
        if recording.isFinalizing {
            quitAfterRecording = true
            return .terminateCancel
        }
        guard recording.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Un enregistrement est en cours."
        alert.informativeText = "Arrêtez-le pour conserver la vidéo avant de quitter."
        alert.addButton(withTitle: "Arrêter et quitter")
        alert.addButton(withTitle: "Continuer l’enregistrement")
        if alert.runModal() == .alertFirstButtonReturn {
            quitAfterRecording = true
            recording.stop()
        }
        return .terminateCancel
    }

    private func recordingFinishedBeforeQuit() {
        quitAfterRecording = false
        NSApp.terminate(nil)
    }

    private func configureMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("Menu de capture", action: #selector(showPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quitter ArtShot X", action: #selector(quit(_:)), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let file = NSMenuItem(title: "Fichier", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Fichier")
        fileMenu.addItem(item("Ouvrir une image…", action: #selector(openImage(_:)), key: "o"))
        fileMenu.addItem(item("Nouvel enregistrement…", action: #selector(beginRecording(_:))))
        fileMenu.addItem(NSMenuItem(title: "Enregistrer…", action: #selector(PreviewWindowController.saveDocument(_:)), keyEquivalent: "s"))
        fileMenu.addItem(NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        file.submenu = fileMenu
        main.addItem(file)
        let edit = NSMenuItem(title: "Édition", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(NSMenuItem(title: "Annuler l’annotation", action: #selector(PreviewWindowController.undo(_:)), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Copier", action: #selector(PreviewWindowController.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.submenu = editMenu
        main.addItem(edit)
        let view = NSMenuItem(title: "Présentation", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "Présentation")
        let fullscreen = NSMenuItem(title: "Plein écran", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullscreen)
        view.submenu = viewMenu
        main.addItem(view)
        NSApp.mainMenu = main

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ArtShot X")
        status.button?.toolTip = "ArtShot X · ⌘⌥⇧7"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Plein écran  ⌘⌥⇧5", action: #selector(captureDisplay(_:))))
        menu.addItem(item("Sélection de zone  ⌘⌥⇧6", action: #selector(captureRegion(_:))))
        menu.addItem(item("Menu de capture  ⌘⌥⇧7", action: #selector(showPanel(_:))))
        menu.addItem(item("Capture défilante…", action: #selector(captureScroll(_:))))
        let record = item("Enregistrer l’écran…", action: #selector(toggleRecording(_:)))
        record.tag = 10
        menu.addItem(record)
        menu.addItem(.separator())
        let image = item("Modifier la dernière capture", action: #selector(openLastImage(_:)))
        image.tag = 11
        menu.addItem(image)
        let video = item("Modifier la dernière vidéo", action: #selector(openLastVideo(_:)))
        video.tag = 12
        menu.addItem(video)
        let recent = NSMenuItem(title: "Captures récentes", action: nil, keyEquivalent: "")
        recent.tag = 13
        recent.submenu = NSMenu(title: "Captures récentes")
        menu.addItem(recent)
        menu.addItem(item("Afficher les captures dans le Finder", action: #selector(revealLibrary(_:))))
        menu.addItem(item("Ouvrir une image…", action: #selector(openImage(_:))))
        menu.addItem(item("Autorisation de capture…", action: #selector(requestPermission(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quitter ArtShot X", action: #selector(quit(_:))))
        menu.autoenablesItems = false
        status.menu = menu
        statusItem = status
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 10)?.title = recording.isRecording ? "Arrêter l’enregistrement" : "Enregistrer l’écran…"
        menu.item(withTag: 11)?.isEnabled = library.latestImage != nil && !busy
        menu.item(withTag: 12)?.isEnabled = library.latestVideo != nil && !busy
        if let recent = menu.item(withTag: 13)?.submenu {
            recent.removeAllItems()
            for capture in library.recentItems.prefix(20) {
                let date = capture.createdAt.formatted(date: .abbreviated, time: .shortened)
                let entry = item("\(capture.kind == .image ? "Image" : "Vidéo") · \(date)", action: #selector(openRecentCapture(_:)))
                entry.representedObject = capture.id.uuidString
                entry.isEnabled = !busy && !exportingCapture
                recent.addItem(entry)
            }
        }
        refreshPanel()
    }

    @objc private func openRecentCapture(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = library.recentItems.first(where: { $0.id.uuidString == id }) else { return }
        editCapture(item)
    }

    @objc private func revealLibrary(_ sender: Any?) {
        do {
            try FileManager.default.createDirectory(at: library.storageDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(library.storageDirectory)
        } catch { showError(error) }
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private var currentScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func rememberExternalApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousExternalApp = app
        }
    }

    private func returnToExternalApp() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousExternalApp?.activate(options: [])
        }
    }

    private func refreshPanel() {
        let failures = (shortcuts?.unavailable ?? []).map { GlobalShortcuts.labels[Int($0) - 1] }
        panel?.refresh(hasPermission: CaptureService.hasPermission, busy: busy || recording.isBusy || exportingCapture,
                       shortcutFailures: failures, hasImage: library.latestImage != nil,
                       hasVideo: library.latestVideo != nil, isRecording: recording.isRecording)
    }

    @objc private func showPanel(_ sender: Any?) {
        guard !busy else { return }
        rememberExternalApp()
        refreshPanel()
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func requestPermission(_ sender: Any?) {
        guard !busy else { return }
        if !CaptureService.hasPermission { CaptureService.requestPermission() }
        refreshPanel()
        if !CaptureService.hasPermission,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func captureDisplay(_ sender: Any?) { beginCapture(.display) }
    @objc private func captureRegion(_ sender: Any?) { beginCapture(.region) }
    @objc private func captureScroll(_ sender: Any?) { beginCapture(.scroll) }

    private func beginCapture(_ mode: CaptureMode) {
        guard !busy, !exportingCapture, !recording.isBusy, !presentingOpenPanel, NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { return }
        guard CaptureService.hasPermission else { showPanel(nil); requestPermission(nil); return }
        guard let screen = currentScreen else { return }
        rememberExternalApp()
        busy = true
        refreshPanel()
        previousKeyWindow = NSApp.keyWindow
        hiddenWindows = (previews.values.compactMap(\.window) + videoPreviews.values.compactMap(\.window)).filter(\.isVisible)
        hiddenWindows.forEach { $0.orderOut(nil) }
        panel.window?.orderOut(nil)
        quickAccess.dismiss()
        if mode == .display { performCapture(screen: screen, rect: nil); return }
        selection.begin(on: screen) { [weak self] rect in
            guard let self else { return }
            guard let rect else { self.finishCapture(restoreEditors: true); return }
            if mode == .scroll {
                self.returnToExternalApp()
                self.scrolling.begin(on: screen, region: rect) { [weak self] result in
                    guard let self else { return }
                    guard let result else { self.finishCapture(restoreEditors: true); return }
                    switch result {
                    case .success(let image): self.received(image, on: screen)
                    case .failure(let error): self.finishCapture(restoreEditors: true); self.showError(error)
                    }
                }
            } else { self.performCapture(screen: screen, rect: rect) }
        }
    }

    private func performCapture(screen: NSScreen, rect: CGRect?) {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let image: NSImage
                if let rect { image = try await capture.captureRegion(rect, on: screen) }
                else { image = try await capture.captureDisplay(screen) }
                received(image, on: screen)
            } catch { finishCapture(restoreEditors: true); showError(error) }
        }
    }

    private func received(_ image: NSImage, on screen: NSScreen) {
        do {
            let item = try library.add(image: image)
            finishCapture(restoreEditors: false)
            quickAccess.present(item, on: screen)
        } catch { finishCapture(restoreEditors: true); showError(error) }
    }

    private func finishCapture(restoreEditors: Bool) {
        if restoreEditors {
            hiddenWindows.forEach { $0.orderFront(nil) }
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        previousKeyWindow = nil
        hiddenWindows.removeAll()
        busy = false
        refreshPanel()
        returnToExternalApp()
    }

    @objc private func toggleRecording(_ sender: Any?) {
        if recording.isRecording { recording.stop() } else { beginRecording(sender) }
    }

    @objc private func beginRecording(_ sender: Any?) {
        guard !busy, !exportingCapture, !recording.isBusy, !presentingOpenPanel, NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.attachedSheet != nil }), let screen = currentScreen else { return }
        rememberExternalApp()
        panel.window?.orderOut(nil)
        quickAccess.dismiss()
        recording.present(on: screen)
    }

    @objc private func openLastImage(_ sender: Any?) { if let item = library.latestImage { editCapture(item) } }
    @objc private func openLastVideo(_ sender: Any?) { if let item = library.latestVideo { editCapture(item) } }

    private func editCapture(_ item: CaptureItem) {
        guard !busy else { return }
        quickAccess.dismiss()
        panel.window?.orderOut(nil)
        if item.kind == .image {
            if let preview = previews[item.id] {
                preview.showWindow(nil)
                preview.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if let image = NSImage(contentsOf: item.url) { showPreview(image, identifier: item.id) }
        } else {
            let preview = videoPreviews[item.id] ?? VideoPreviewWindowController(url: item.url)
            videoPreviews[item.id] = preview
            preview.onClose = { [weak self] in
                self?.videoPreviews.removeValue(forKey: item.id)
            }
            preview.showWindow(nil)
            preview.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showPreview(_ image: NSImage, identifier: UUID = UUID()) {
        let preview = PreviewWindowController(image: image)
        preview.onClose = { [weak self] in
            if self?.library.latestImage?.id != identifier { self?.previews.removeValue(forKey: identifier) }
        }
        previews[identifier] = preview
        preview.showWindow(nil)
        preview.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func copyCapture(_ item: CaptureItem) {
        guard item.kind == .image else { return }
        do {
            let data = try Data(contentsOf: item.url)
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(data, forType: .png)
            if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation { pasteboardItem.setData(tiff, forType: .tiff) }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([pasteboardItem]) else { throw CocoaError(.fileWriteUnknown) }
            quickAccess.showCopied()
        } catch { showError(error) }
    }

    private func saveCapture(_ item: CaptureItem) {
        guard !presentingOpenPanel, !exportingCapture else { return }
        let dialog = NSSavePanel()
        dialog.allowedContentTypes = item.kind == .image ? [.png] : [.mpeg4Movie]
        dialog.nameFieldStringValue = item.kind == .image ? "ArtShot X.png" : "ArtShot X.mp4"
        dialog.canCreateDirectories = true
        presentingOpenPanel = true
        NSApp.activate(ignoringOtherApps: true)
        dialog.begin { [weak self] result in
            guard let self else { return }
            self.presentingOpenPanel = false
            guard result == .OK, let destination = dialog.url else { return }
            self.exportingCapture = true
            self.refreshPanel()
            self.quickAccess.showSaving()
            Task { @MainActor in
                defer {
                    self.exportingCapture = false
                    self.refreshPanel()
                }
                do {
                    if item.kind == .image { try Data(contentsOf: item.url).write(to: destination, options: .atomic) }
                    else { try await RecordingComposition.export(url: item.url, edit: RecordingEdit(), to: destination) }
                    self.quickAccess.showSaved()
                } catch { self.quickAccess.showSaveFailed(); self.showError(error) }
            }
        }
    }

    private func discardCapture(_ item: CaptureItem) {
        guard !exportingCapture, !presentingOpenPanel else { return }
        do {
            try library.discard(item)
            quickAccess.dismiss()
            previews[item.id]?.close()
            previews.removeValue(forKey: item.id)
            videoPreviews[item.id]?.close()
            videoPreviews.removeValue(forKey: item.id)
            refreshPanel()
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    @objc private func openImage(_ sender: Any?) {
        guard !busy, !presentingOpenPanel else { return }
        let dialog = NSOpenPanel()
        dialog.title = "Ouvrir une image"
        dialog.allowedContentTypes = [.image]
        dialog.allowsMultipleSelection = false
        dialog.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        presentingOpenPanel = true
        dialog.begin { [weak self] response in
            guard let self else { return }
            self.presentingOpenPanel = false
            guard response == .OK, let url = dialog.url else { return }
            guard let image = NSImage(contentsOf: url), image.isValid else {
                self.showError(CocoaError(.fileReadCorruptFile)); return
            }
            self.showPreview(image)
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
