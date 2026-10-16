import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let capture = CaptureService()
    private let selection = SelectionOverlayController()
    private var panel: CapturePanelController!
    private var previews: [UUID: PreviewWindowController] = [:]
    private var statusItem: NSStatusItem?
    private var shortcuts: GlobalShortcuts?
    private var hiddenWindows: [NSWindow] = []
    private weak var previousKeyWindow: NSWindow?
    private var busy = false
    private var presentingOpenPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = CapturePanelController()
        panel.onDisplay = { [weak self] in self?.beginCapture(region: false) }
        panel.onRegion = { [weak self] in self?.beginCapture(region: true) }
        panel.onOpenImage = { [weak self] in self?.openImage(nil) }
        panel.onSample = { [weak self] in self?.showPreview(DemoImage.make()) }
        panel.onPermission = { [weak self] in self?.requestPermission(nil) }
        configureMenus()
        shortcuts = GlobalShortcuts { [weak self] id in
            switch id {
            case 1: self?.beginCapture(region: false)
            case 2: self?.beginCapture(region: true)
            default: self?.showPanel(nil)
            }
        }
        showPanel(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPanel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(nil)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { shortcuts?.unregister() }

    private func configureMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("ArtShot X", action: #selector(showPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quitter ArtShot X", action: #selector(quit(_:)), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let file = NSMenuItem(title: "Fichier", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Fichier")
        fileMenu.addItem(item("Ouvrir une image…", action: #selector(openImage(_:)), key: "o"))
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
        status.button?.toolTip = "ArtShot X"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Plein écran  ⌃⌥⌘5", action: #selector(captureDisplay(_:))))
        menu.addItem(item("Sélection de zone  ⌃⌥⌘6", action: #selector(captureRegion(_:))))
        menu.addItem(item("Ouvrir ArtShot X  ⌃⌥⌘7", action: #selector(showPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Ouvrir une image…", action: #selector(openImage(_:))))
        menu.addItem(item("Autorisation de capture…", action: #selector(requestPermission(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quitter ArtShot X", action: #selector(quit(_:))))
        status.menu = menu
        statusItem = status
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func refreshPanel() {
        panel?.refresh(hasPermission: CaptureService.hasPermission, busy: busy,
                       shortcutsAvailable: shortcuts?.unavailable.isEmpty ?? false)
    }

    @objc private func showPanel(_ sender: Any?) {
        guard !busy else { return }
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

    @objc private func captureDisplay(_ sender: Any?) { beginCapture(region: false) }
    @objc private func captureRegion(_ sender: Any?) { beginCapture(region: true) }

    private func beginCapture(region: Bool) {
        guard !busy, !presentingOpenPanel, NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { return }
        guard CaptureService.hasPermission else {
            showPanel(nil)
            requestPermission(nil)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        busy = true
        refreshPanel()
        previousKeyWindow = NSApp.keyWindow
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0 != statusItem?.button?.window }
        hiddenWindows.forEach { $0.orderOut(nil) }
        if region {
            selection.begin(on: screen) { [weak self] rect in
                guard let self else { return }
                guard let rect else { self.finishCapture(); return }
                self.performCapture(screen: screen, rect: rect)
            }
        } else {
            performCapture(screen: screen, rect: nil)
        }
    }

    private func performCapture(screen: NSScreen, rect: CGRect?) {
        Task { @MainActor in
            do {
                // Let the closed menu/overlay leave the compositor before sampling.
                try await Task.sleep(nanoseconds: 180_000_000)
                let image: NSImage
                if let rect { image = try await capture.captureRegion(rect, on: screen) }
                else { image = try await capture.captureDisplay(screen) }
                finishCapture()
                showPreview(image)
            } catch {
                finishCapture()
                showPanel(nil)
                if let window = panel.window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }

    private func finishCapture() {
        hiddenWindows.forEach { $0.orderFront(nil) }
        previousKeyWindow?.makeKeyAndOrderFront(nil)
        previousKeyWindow = nil
        hiddenWindows.removeAll()
        busy = false
        refreshPanel()
    }

    private func showPreview(_ image: NSImage) {
        let identifier = UUID()
        let preview = PreviewWindowController(image: image)
        preview.onClose = { [weak self] in self?.previews.removeValue(forKey: identifier) }
        previews[identifier] = preview
        preview.showWindow(nil)
        preview.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            self?.presentingOpenPanel = false
            guard response == .OK, let url = dialog.url else { return }
            guard let image = NSImage(contentsOf: url), image.isValid else {
                let alert = NSAlert()
                alert.messageText = "Cette image ne peut pas être ouverte."
                alert.informativeText = "Choisissez un fichier PNG, JPEG ou un autre format d’image pris en charge par macOS."
                alert.runModal()
                return
            }
            self?.showPreview(image)
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
