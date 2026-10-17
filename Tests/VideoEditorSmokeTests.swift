
// Appended to the real controller to exercise its private editor actions without capture hardware.
extension VideoPreviewWindowController {
    @MainActor static func checkEditor(folder: URL, snapshot: URL) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let raw = folder.appendingPathComponent("audio/capture.mov")
        var options = RecordingOptions()
        options.systemAudio = true; options.microphone = true; options.clicks = true; options.keys = true
        let metadata = RecordingMetadata(options: options, events: [], duration: 4, hasCamera: false, hasSystemAudio: true, hasMicrophone: true)
        try JSONEncoder().encode(metadata).write(to: RecordingMetadata.sidecar(for: raw))
        let original = try Data(contentsOf: raw)
        let controller = VideoPreviewWindowController(url: raw)
        controller.showWindow(nil)
        defer { controller.close() }
        func ready(_ editor: VideoPreviewWindowController) async throws {
            for _ in 0..<1000 {
                if editor.saveButton.isEnabled { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            fatalError("Editor preparation timed out: \(editor.status.stringValue)")
        }
        try await ready(controller)
        precondition(controller.systemVolume.minValue == 0 && controller.systemVolume.maxValue == 200)
        precondition(controller.micVolume.minValue == 0 && controller.micVolume.maxValue == 200)
        precondition(controller.systemVolume.doubleValue == 100 && controller.micVolume.doubleValue == 100)
        precondition(controller.systemVolume.isEnabled && controller.micVolume.isEnabled)
        controller.systemVolume.doubleValue = 50
        controller.micVolume.doubleValue = 175
        controller.volumeChanged()
        try await ready(controller)
        precondition(controller.currentEdit.systemAudioVolume == 0.5 && controller.currentEdit.microphoneVolume == 1.75)
        precondition(controller.systemVolumeLabel.stringValue == "50 %" && controller.micVolumeLabel.stringValue == "175 %")
        let parameters = controller.player.currentItem!.audioMix!.inputParameters
        precondition(parameters.count == 3, "Gain above unity uses parallel tracks")
        let gains = parameters.map { parameter -> Float in
            var from: Float = -1; var to: Float = -1; var range = CMTimeRange.zero
            precondition(parameter.getVolumeRamp(for: .zero, startVolume: &from, endVolume: &to, timeRange: &range))
            return from
        }
        precondition(gains.sorted() == [0.5, 0.75, 1.0], "Player audio mix must apply both gains")
        controller.cutStart.stringValue = "1,00"; controller.cutEnd.stringValue = "2,00"
        controller.removePassage()
        try await ready(controller)
        precondition(controller.cuts.count == 1 && controller.undoButton.isEnabled)
        precondition(abs(controller.timeline!.duration - 3) < 0.03)
        await controller.player.seek(to: CMTime(seconds: 1.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        precondition(abs(controller.sourcePosition - 2.5) < 0.04)
        controller.markCutStart(); controller.markCutEnd()
        precondition(controller.cutStart.stringValue == "2,50" && controller.cutEnd.stringValue == "2,50")
        controller.undo(nil)
        try await ready(controller)
        precondition(controller.cuts.isEmpty && !controller.undoButton.isEnabled)
        precondition(abs(controller.timeline!.duration - 4) < 0.03)
        let unchanged = try Data(contentsOf: raw)
        precondition(unchanged == original, "Edits must preserve original movie")
        controller.player.play()
        controller.reload()
        precondition(controller.isPreparing && !controller.start.isEnabled && !controller.system.isEnabled && !controller.systemVolume.isEnabled)
        controller.reload()
        precondition(controller.resumeAfterReload, "Rapid reload must preserve playback intent")
        try await ready(controller)
        precondition(!controller.isPreparing && !controller.resumeAfterReload && controller.player.rate > 0)
        controller.player.pause()
        let window = controller.window!
        precondition(window.collectionBehavior.contains(.fullScreenPrimary), "Native fullscreen must be available")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for size in [window.frame.size, window.minSize] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            let content = window.contentView!
            content.layoutSubtreeIfNeeded()
            // AVKit owns its playback chrome; inspect every editor-owned footer control.
            for control in descendants(content).filter({ $0 is NSControl && !$0.isHiddenOrHasHiddenAncestor && !$0.isDescendant(of: controller.playerView) }) {
                let frame = control.convert(control.bounds, to: content)
                precondition(frame.width > 0 && frame.height > 0 && content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Clipped editor control: \(control), \(frame)")
            }
        }
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), snapshot.path]
        try capture.run()
        capture.waitUntilExit()
        precondition(capture.terminationStatus == 0, "Window snapshot failed")
        let silent = VideoPreviewWindowController(url: folder.appendingPathComponent("silent/capture.mov"))
        defer { silent.close() }
        try await ready(silent)
        precondition(silent.systemVolume.isHiddenOrHasHiddenAncestor && silent.micVolume.isHiddenOrHasHiddenAncestor)
        print("PASS: actual editor, both gains 0–200%, audio mix, internal removal/undo, original preservation, original playhead mapping, initial/minimum layout, fullscreen capability and silent controls")
    }
}
@main struct VideoEditorSmokeTests {
    @MainActor static func main() async throws {
        try await VideoPreviewWindowController.checkEditor(folder: URL(fileURLWithPath: CommandLine.arguments[1]), snapshot: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
