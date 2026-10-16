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
        verifyLayout(panel.window!, label: "Capture menu")
        panel.refresh(hasPermission: false, busy: false, shortcutFailures: ["⌘⌥⇧5", "⌘⌥⇧6", "⌘⌥⇧7"],
                      hasImage: false, hasVideo: false, isRecording: false)
        verifyLayout(panel.window!, label: "Permission and shortcut errors")
        panel.refresh(hasPermission: true, busy: true, shortcutFailures: [], hasImage: true, hasVideo: true, isRecording: true)
        verifyLayout(panel.window!, label: "Recording menu")
        var stopped = false
        panel.onStopRecording = { stopped = true }
        button("Arrêter l’enregistrement", in: panel.window!.contentView!).performClick(nil)
        precondition(stopped, "Recording menu has no working Stop action")
        print("PASS: thumbnail layout; nonactivation; bottom-left placement; image/video actions and copy state; save feedback layout; capture menu permission/errors/recording layout; Stop navigation")
    }
}
