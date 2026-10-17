
// Appended to the real controller source by the harness for private lifecycle inspection.
extension RecordingController {
    @MainActor static func checkControls() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("macOS login session required") }
        let controller = RecordingController()
        controller.present(on: screen)
        guard let window = controller.optionsWindow, let content = window.contentView else { fatalError("Options window missing") }
        defer { controller.cancel() }
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for control in descendants(content).filter({ $0 is NSControl && !$0.isHiddenOrHasHiddenAncestor }) {
            let frame = control.convert(control.bounds, to: content)
            precondition(!control.hasAmbiguousLayout && frame.width > 0 && frame.height > 0 && content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Clipped or ambiguous option: \(control)")
        }
        precondition(controller.startButton.isEnabled && !controller.shapeControl.isEnabled && !controller.sizeControl.isEnabled)
        precondition(controller.revealActiveControls() && controller.optionsWindow === window)
        controller.cancel()
        precondition(!controller.isBusy && !controller.revealActiveControls())
        // Simulate an established recording: shortcut 7 must reveal the bar without an options panel.
        controller.isRecording = true
        controller.status = "00:09"
        precondition(controller.revealActiveControls())
        precondition(controller.controls.window.isVisible && controller.optionsWindow == nil)
        precondition(controller.controls.window.styleMask.contains(.borderless))
        controller.isRecording = false
        controller.isFinishing = true
        controller.status = "Finalisation…"
        precondition(controller.revealActiveControls())
        let buttons = descendants(controller.controls.window.contentView!).compactMap { $0 as? NSButton }
        precondition(!buttons.isEmpty && buttons.allSatisfy { !$0.isEnabled }, "Finalization must disable recording actions")
        controller.isFinishing = false
        controller.closeControls()
        precondition(!controller.controls.window.isVisible)
        print("PASS: recording options layout, idle/recording shortcut routing, finalization controls and cleanup")
    }
}

@main struct RecordingControlsSmokeTests {
    @MainActor static func main() { RecordingController.checkControls() }
}
