
// Appended to the real controller source by the harness for private lifecycle inspection.
extension RecordingController {
    @MainActor static func checkControls() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("macOS login session required") }
        let savedLayout = UserDefaults.standard.object(forKey: "recording.cameraLayout")
        defer {
            if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: "recording.cameraLayout") }
            else { UserDefaults.standard.removeObject(forKey: "recording.cameraLayout") }
        }
        let controller = RecordingController()
        controller.present(on: screen)
        guard let window = controller.optionsWindow, let content = window.contentView else { fatalError("Options window missing") }
        defer { controller.cancel() }
        content.layoutSubtreeIfNeeded()
        precondition(content.bounds.size == CGSize(width: 470, height: 640), "Options must use the expanded camera controls layout")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for control in descendants(content).filter({ $0 is NSControl && !$0.isHiddenOrHasHiddenAncestor }) {
            let frame = control.convert(control.bounds, to: content)
            precondition(!control.hasAmbiguousLayout && frame.width > 0 && frame.height > 0 && content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Clipped or ambiguous option: \(control)")
        }
        precondition(controller.startButton.isEnabled && !controller.shapeControl.isEnabled && !controller.sizeControl.isEnabled && !controller.zoomControl.isEnabled)
        precondition(controller.shapeControl.segmentCount == 4 && controller.shapeControl.label(forSegment: 3) == "Ovale vertical")
        precondition(controller.zoomControl.minValue == 1 && controller.zoomControl.maxValue == 3 && controller.zoomControl.isContinuous)
        precondition(controller.cameraSource == nil, "Control checks must not open camera hardware")
        // Exercise the action directly while the camera is off, including persisted preferences.
        controller.shapeControl.selectedSegment = 3
        controller.sizeControl.doubleValue = 0.3
        for zoom in [1.0, 2.5, 3.0] {
            controller.zoomControl.doubleValue = zoom
            controller.layoutChanged()
            precondition(controller.cameraLayout.shape == .verticalOval && controller.cameraLayout.widthFraction == 0.3 && controller.cameraLayout.zoom == zoom)
            precondition(controller.zoomLabel.stringValue == String(format: "%.1f×", locale: Locale(identifier: "fr_FR"), zoom))
            let data = UserDefaults.standard.data(forKey: "recording.cameraLayout")!
            let persisted = try! JSONDecoder().decode(CameraLayout.self, from: data)
            precondition(persisted == controller.cameraLayout, "Shape and zoom must survive preference serialization")
            let frame = persisted.frame(in: CGSize(width: 1920, height: 1080))
            precondition(abs(frame.width / frame.height - 0.75) < 0.000001, "Vertical oval must retain portrait proportions")
            precondition(controller.cameraSource == nil && !controller.zoomControl.isEnabled)
        }
        precondition(controller.revealActiveControls() && controller.optionsWindow === window)
        controller.cancel()
        precondition(!controller.isBusy && !controller.revealActiveControls())
        for (seconds, label) in [(0.0, "0:00"), (5, "0:05"), (65, "1:05"), (3723, "1:02:03"), (-5, "0:00"), (Double.nan, "0:00")] {
            precondition(RecordingController.elapsedLabel(seconds) == label, "Incorrect elapsed time label")
        }
        // Simulate an established recording: shortcut 7 must reveal the bar without an options panel.
        controller.isRecording = true
        controller.status = "0:09"
        precondition(controller.revealActiveControls())
        precondition(controller.controls.window.isVisible && controller.optionsWindow == nil)
        precondition(controller.controls.window.styleMask.contains(.borderless))
        let buttons = descendants(controller.controls.window.contentView!).compactMap { $0 as? NSButton }
        precondition(buttons.count == 4 && buttons.allSatisfy(\.isEnabled))
        controller.isPaused = true
        controller.refreshControls()
        precondition(buttons.contains { $0.accessibilityLabel() == "Reprendre" }, "Pause must offer Resume")
        controller.isChangingPause = true
        controller.refreshControls()
        precondition(buttons.allSatisfy { !$0.isEnabled }, "Pause transition must prevent competing actions")
        controller.isChangingPause = false
        controller.isPaused = false
        controller.isRecording = false
        controller.isFinishing = true
        controller.status = "Finalisation…"
        precondition(controller.revealActiveControls())
        precondition(!buttons.isEmpty && buttons.allSatisfy { !$0.isEnabled }, "Finalization must disable recording actions")
        controller.restartAfterFinish = true
        controller.stop()
        precondition(!controller.restartAfterFinish, "Quitting during finalization must cancel automatic restart")
        controller.isFinishing = false
        controller.closeControls()
        precondition(!controller.controls.window.isVisible)
        print("PASS: unclipped 470×640 options, vertical oval, zoom range/action/preferences without hardware, shortcut routing, elapsed labels, pause controls, restart cancellation and cleanup")
    }
}

@main struct RecordingControlsSmokeTests {
    @MainActor static func main() { RecordingController.checkControls() }
}
