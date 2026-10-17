import AppKit

// Exercises real AppKit layout and target/action wiring without capture permissions or pasteboard writes.
@main struct CaptureUISmokeTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("A macOS login session is required") }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("artshot-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let context = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let imageURL = root.appendingPathComponent("image.png")
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: imageURL)
        let image = CaptureItem(id: UUID(), kind: .image, url: imageURL, createdAt: Date())
        let video = CaptureItem(id: UUID(), kind: .video, url: root.appendingPathComponent("video.mov"), createdAt: Date())

        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func button(_ title: String, in content: NSView) -> NSButton {
            guard let result = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                fatalError("Missing navigation button: \(title)")
            }
            return result
        }
        func verifyLayout(_ window: NSWindow, label: String) {
            let content = window.contentView!
            content.layoutSubtreeIfNeeded()
            let controls = descendants(content).filter { $0 is NSButton || $0 is NSImageView || $0 is NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
            for control in controls {
                let rect = control.convert(control.bounds, to: content)
                precondition(!control.hasAmbiguousLayout, "\(label): ambiguous \(control)")
                precondition(rect.width > 0 && rect.height > 0 && content.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                             "\(label): clipped or empty control \(control), frame \(rect), content \(content.bounds)")
            }
            let buttons = controls.compactMap { $0 as? NSButton }
            for (index, first) in buttons.enumerated() {
                for second in buttons.dropFirst(index + 1) {
                    let a = first.convert(first.bounds.insetBy(dx: 1, dy: 1), to: content)
                    let b = second.convert(second.bounds.insetBy(dx: 1, dy: 1), to: content)
                    precondition(!a.intersects(b), "\(label): navigation buttons overlap")
                }
            }
        }

        let quick = QuickAccessController()
        defer { quick.dismiss() }
        let window = quick.window!
        let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previousKeyWindow = NSApp.keyWindow
        var actions: [(String, UUID)] = []
        quick.onEdit = { actions.append(("edit", $0.id)) }
        quick.onSave = { actions.append(("save", $0.id)) }
        quick.onCopy = { actions.append(("copy", $0.id)) }
        quick.onDiscard = { actions.append(("discard", $0.id)) }
        quick.present(image, on: screen)
        verifyLayout(window, label: "Image thumbnail")
        precondition(window.styleMask.contains(.nonactivatingPanel) && !window.canBecomeKey && !window.canBecomeMain)
        precondition(NSApp.keyWindow === previousKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp,
                     "Thumbnail stole keyboard focus or activated ArtShot X")
        precondition(abs(window.frame.minX - screen.visibleFrame.minX - 18) < 1 &&
                     abs(window.frame.minY - screen.visibleFrame.minY - 18) < 1,
                     "Thumbnail was not positioned at the screen's visible bottom-left")
        let content = window.contentView!
        let copy = button("Copier", in: content)
        precondition(copy.isEnabled && descendants(content).compactMap({ $0 as? NSImageView }).first?.image != nil)
        for title in ["Modifier", "Enregistrer", "Copier", "Supprimer"] { button(title, in: content).performClick(nil) }
        precondition(actions.map { $0.0 } == ["edit", "save", "copy", "discard"] && actions.allSatisfy { $0.1 == image.id },
                     "Image actions failed to reach callbacks with the current capture")
        quick.showCopied()
        precondition(copy.title == "Copié")
        quick.present(video, on: screen)
        verifyLayout(window, label: "Video thumbnail")
        precondition(copy.title == "Copier" && !copy.isEnabled, "Video enabled image-only copying")
        let actionCount = actions.count
        copy.performClick(nil)
        precondition(actions.count == actionCount, "Disabled video Copy still dispatched")
        for title in ["Modifier", "Enregistrer", "Supprimer"] { button(title, in: content).performClick(nil) }
        precondition(actions.suffix(3).allSatisfy { $0.1 == video.id }, "Video actions retained the previous image")
        quick.showSaving()
        verifyLayout(window, label: "Saving thumbnail")
        quick.showSaved()
        verifyLayout(window, label: "Saved thumbnail")
        quick.showSaveFailed()
        verifyLayout(window, label: "Failed-save thumbnail")
        quick.dismiss()
        precondition(!window.isVisible, "Dismiss left thumbnail onscreen")

        let panel = CapturePanelController()
        panel.refresh(hasPermission: true, busy: false, shortcutFailures: [], hasImage: true, hasVideo: true, isRecording: false)
        let panelWindow = panel.window!
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let normal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        panel.present(on: screen)
        precondition(panelWindow.isVisible && !normal.isVisible)
        precondition(panelWindow.styleMask.contains(.nonactivatingPanel) && panelWindow.styleMask.contains(.borderless))
        precondition(panelWindow is NSPanel && panelWindow.canBecomeKey && !panelWindow.canBecomeMain)
        precondition(panelWindow.sharingType == .none && !panelWindow.hidesOnDeactivate)
        precondition(panelWindow.collectionBehavior.contains(.canJoinAllSpaces) && panelWindow.collectionBehavior.contains(.fullScreenAuxiliary))
        precondition(panelWindow.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID)
        precondition(screen.visibleFrame.contains(panelWindow.frame))
        verifyLayout(panelWindow, label: "Capture menu")
        var captureActions: [String] = []
        panel.onSnapshot = { captureActions.append("snapshot") }
        panel.onRegion = { captureActions.append("region") }
        panel.onDisplay = { captureActions.append("display") }
        panel.onScroll = { captureActions.append("scroll") }
        panel.onRecord = { captureActions.append("record") }
        for title in ["Zone", "Écran", "Photo", "Défilement", "Vidéo"] { button(title, in: panelWindow.contentView!).performClick(nil) }
        precondition(captureActions == ["region", "display", "snapshot", "scroll", "record"])
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID && !normal.isVisible)
        panel.setSelection(isRegion: true, pixelSize: CGSize(width: 640, height: 480))
        precondition(button("Zone", in: panelWindow.contentView!).state == .on && button("Écran", in: panelWindow.contentView!).state == .off)
        precondition(descendants(panelWindow.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Zone · 640 × 480 px" })
        panel.setSelection(isRegion: false, pixelSize: CGSize(width: 3024, height: 1964))
        precondition(button("Écran", in: panelWindow.contentView!).state == .on && button("Zone", in: panelWindow.contentView!).state == .off)
        let snapshot = panelWindow.contentView!
        snapshot.displayIfNeeded()
        let bitmap = snapshot.bitmapImageRepForCachingDisplay(in: snapshot.bounds)!
        snapshot.cacheDisplay(in: snapshot.bounds, to: bitmap)
        let screenshotURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("replica/clone-screens/capture-bar.png")
        try files.createDirectory(at: screenshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: screenshotURL)
        panel.refresh(hasPermission: false, busy: false, shortcutFailures: ["⌘⌥⇧5", "⌘⌥⇧6", "⌘⌥⇧7"],
                      hasImage: false, hasVideo: false, isRecording: false)
        verifyLayout(panel.window!, label: "Permission and shortcut errors")
        panel.refresh(hasPermission: true, busy: true, shortcutFailures: [], hasImage: true, hasVideo: true, isRecording: true)
        verifyLayout(panel.window!, label: "Recording menu")
        var stopped = false
        panel.onStopRecording = { stopped = true }
        button("Arrêter", in: panel.window!.contentView!).performClick(nil)
        precondition(stopped, "Recording menu has no working Stop action")
        var dismissCount = 0
        panel.onDismiss = { dismissCount += 1 }
        panel.hide()
        precondition(dismissCount == 0 && !panelWindow.isVisible, "Temporary hide dispatched dismissal")
        panel.present(on: screen)
        panelWindow.cancelOperation(nil)
        precondition(dismissCount == 1, "Escape did not dispatch dismissal")
        precondition(!panelWindow.isVisible, "Escape did not dismiss capture toolbar")
        print("PASS: thumbnail layout; nonactivation; bottom-left placement; image/video actions and copy state; save feedback layout; capture menu permission/errors/recording layout; Stop navigation")
    }
}
