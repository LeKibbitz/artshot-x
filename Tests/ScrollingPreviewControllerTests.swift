// HARNESS: ScrollingPreviewView.swift
extension ScrollingPreviewView {
    var testDimensions: (Int, Int, Int) { (strips.count, sourceWidth, totalHeight) }
    func checkMatches(_ expected: [CGImage], width: Int, height: Int) {
        precondition(strips.count == expected.count && sourceWidth == width && totalHeight == height,
                     "Preview dimensions diverged from accepted capture")
        for (actual, wanted) in zip(strips, expected) {
            precondition(actual === wanted, "Preview copied or substituted accepted image strips")
        }
    }
}

// HARNESS: ScrollingCaptureController.swift
extension ScrollingCaptureController {
    private static func testSample(offset: Int) -> Sample {
        let width = 48, height = 180
        let pixels: [UInt8] = (0..<height).flatMap { y in
            (0..<width).map { x in
                let row = y + offset
                let hash = (row &* 1_664_525 &+ x &* 1_013_904_223) ^ (row &* x &* 7_919)
                return UInt8(truncatingIfNeeded: hash >> 7)
            }
        }
        let data = Data(pixels.flatMap { [$0, $0, $0, UInt8(255)] })
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        return Sample(image: image, logicalSize: CGSize(width: width / 2, height: height / 2),
                      frame: ScrollFrame(width: width, height: height, pixels: pixels))
    }

    static func checkPreviewLifecycle(on screen: NSScreen) async throws {
        let controller = ScrollingCaptureController()
        let id = UUID()
        controller.sessionID = id
        let initial = testSample(offset: 0)
        controller.accepted = initial
        controller.lastSeen = initial
        controller.strips = [initial.image]
        controller.totalHeight = initial.image.height
        controller.updatePreview()
        controller.previewView.checkMatches(controller.strips, width: 48, height: 180)

        try await controller.record(testSample(offset: 0), session: id)
        precondition(controller.strips.count == 1 && !controller.hasUnmatchedPosition)
        controller.previewView.checkMatches(controller.strips, width: 48, height: 180)
        try await controller.record(testSample(offset: 500), session: id)
        precondition(controller.hasUnmatchedPosition && controller.totalHeight == 180)
        controller.previewView.checkMatches(controller.strips, width: 48, height: 180)
        try await controller.record(testSample(offset: 37), session: id)
        precondition(!controller.hasUnmatchedPosition && controller.totalHeight == 217 && controller.strips.count == 2)
        controller.previewView.checkMatches(controller.strips, width: 48, height: 217)
        let result = try controller.render()
        var rect = CGRect(origin: .zero, size: result.size)
        let output = result.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        precondition(output.width == 48 && output.height == 217 && result.size == CGSize(width: 24, height: 108.5),
                     "Preview lifecycle changed export or Retina dimensions")

        var callbacks = 0
        controller.completion = { result in
            callbacks += 1
            precondition(result == nil && controller.panel == nil && controller.strips.isEmpty)
            let state = controller.previewView.testDimensions
            precondition(state.0 == 0 && state.1 == 0 && state.2 == 0,
                         "Cancellation callback retained preview pixels")
        }
        controller.cancel()
        controller.cancel()
        precondition(callbacks == 1 && controller.accepted == nil && controller.lastSeen == nil)

        let keyWindow = NSApp.keyWindow
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let region = CGRect(x: screen.visibleFrame.midX - 50, y: screen.visibleFrame.midY - 50, width: 100, height: 100)
        controller.showPanel(on: screen, avoiding: region)
        let panel = controller.panel!
        defer { controller.cancel() }
        precondition(panel.isVisible && panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeKey && !panel.canBecomeMain)
        precondition(NSApp.keyWindow === keyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                     "Scrolling HUD stole keyboard focus")
        precondition(panel.sharingType == .none && screen.visibleFrame.contains(panel.frame))
        let content = panel.contentView!
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(content).filter { $0 is NSTextField || $0 is NSButton || $0 is ScrollingPreviewView }
        for control in controls {
            let frame = control.convert(control.bounds, to: content)
            precondition(!control.hasAmbiguousLayout && frame.width > 0 && frame.height > 0 && content.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                         "Scrolling HUD has clipped or ambiguous control: \(control)")
        }
        let previewFrame = controller.previewView.convert(controller.previewView.bounds, to: content)
        for control in controls where control !== controller.previewView {
            precondition(!previewFrame.intersects(control.convert(control.bounds, to: content)), "Preview overlaps HUD controls")
        }
        precondition(controller.previewView.testDimensions.0 == 0, "Reopened HUD retained previous capture")
        precondition(!controller.finishButton.isEnabled, "Finish enabled before initial capture")
        controller.accepted = initial
        controller.strips = [initial.image]
        controller.totalHeight = 180
        controller.updatePreview()
        controller.updateStatus()
        controller.finishButton.isEnabled = true
        content.layoutSubtreeIfNeeded()
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("artshot-scrolling-preview-hud.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: snapshotURL)
        print("Synthetic HUD snapshot: \(snapshotURL.path)")
    }
}

// HARNESS: Main.swift
import AppKit
@main struct ScrollingPreviewControllerTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("A macOS login session is required") }
        try await ScrollingCaptureController.checkPreviewLifecycle(on: screen)
        print("PASS: initial/shifted preview; duplicate/rejected preservation; Retina export; cancel cleanup; HUD focus/layout/reset")
    }
}
