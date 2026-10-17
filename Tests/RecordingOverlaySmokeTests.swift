import AppKit

@main struct RecordingOverlaySmokeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("A macOS login session is required") }
        let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previousKey = NSApp.keyWindow
        let capture = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        let camera = CameraOverlayController()
        let bar = RecordingControlBar()
        defer { camera.close(); bar.close() }

        func snapshot(_ view: NSView, into existing: NSBitmapImageRep? = nil) -> NSBitmapImageRep {
            let bitmap = existing ?? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
                                          pixelsHigh: Int(view.bounds.height), bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                .retagging(with: .sRGB)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap
        }
        func event(_ type: NSEvent.EventType, screenPoint: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: camera.window.convertPoint(fromScreen: screenPoint),
                               modifierFlags: [], timestamp: 0, windowNumber: camera.window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ delta: CGSize) {
            let point = CGPoint(x: camera.window.frame.midX, y: camera.window.frame.midY)
            let end = CGPoint(x: point.x + delta.width, y: point.y + delta.height)
            camera.window.contentView!.mouseDown(with: event(.leftMouseDown, screenPoint: point))
            camera.window.contentView!.mouseDragged(with: event(.leftMouseDragged, screenPoint: end))
            camera.window.contentView!.mouseUp(with: event(.leftMouseUp, screenPoint: end))
        }

        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let image = context.makeImage()!
        for shape in CameraShape.allCases {
            let layout = CameraLayout(shape: shape, widthFraction: 0.23, centerX: 0.5, centerY: 0.5)
            camera.show(in: capture, layout: layout, editable: true)
            let expected = layout.frame(in: capture.size)
            precondition(abs(camera.window.frame.minX - capture.minX - expected.minX) < 1 &&
                         abs(camera.window.frame.minY - capture.maxY + expected.maxY) < 1,
                         "Camera top-left layout was not converted to AppKit screen coordinates")
            let placeholder = snapshot(camera.window.contentView!)
            precondition(placeholder.colorAt(x: placeholder.pixelsWide / 2, y: placeholder.pixelsHigh / 2)!.alphaComponent > 0.9,
                         "Camera has no placeholder before the first frame")
            camera.update(image: image)
            let rendered = snapshot(camera.window.contentView!)
            let y = rendered.pixelsHigh / 2
            let left = rendered.colorAt(x: rendered.pixelsWide / 4, y: y)!.usingColorSpace(.sRGB)!
            let right = rendered.colorAt(x: rendered.pixelsWide * 3 / 4, y: y)!.usingColorSpace(.sRGB)!
            precondition(left.redComponent > 0.9 && right.blueComponent > 0.9,
                         "Live camera was mirrored, letterboxed or did not render the input frame")
            let top = rendered.colorAt(x: rendered.pixelsWide * 2 / 5, y: rendered.pixelsHigh / 8)!.usingColorSpace(.sRGB)!
            precondition(top.redComponent > 0.9, "Camera fits the image with letterboxing instead of filling the bubble")
            let corner = rendered.colorAt(x: 1, y: 1)!.alphaComponent
            precondition(shape == .square ? corner > 0.9 : corner < 0.05,
                         "Camera shape clipping is missing or cuts the square")
            camera.close()
        }
        let square = CameraLayout(shape: .square, widthFraction: 0.23, centerX: 0.5, centerY: 0.5)
        camera.show(in: capture, layout: square, editable: true)
        camera.update(image: image)
        let reused = snapshot(camera.window.contentView!)
        camera.show(in: capture, layout: CameraLayout(shape: .circle, widthFraction: 0.23, centerX: 0.5, centerY: 0.5), editable: true)
        _ = snapshot(camera.window.contentView!, into: reused)
        precondition(reused.colorAt(x: 1, y: 1)!.alphaComponent < 0.05,
                     "Switching square to circle left opaque pixels from the previous shape")
        var changes = 0
        camera.onLayoutChanged = { _ in changes += 1 }
        let centered = CameraLayout(shape: .roundedRectangle, widthFraction: 0.23, centerX: 0.5, centerY: 0.5)
        camera.show(in: capture, layout: centered, editable: true)
        drag(CGSize(width: 20, height: 15))
        precondition(abs(camera.currentLayout.centerX - (0.5 + 20 / capture.width)) < 0.001 &&
                     abs(camera.currentLayout.centerY - (0.5 - 15 / capture.height)) < 0.001 && changes == 1,
                     "Camera drag changed the wrong normalized coordinate or missed its callback")
        drag(CGSize(width: capture.width * 3, height: capture.height * 3))
        precondition(capture.insetBy(dx: -1, dy: -1).contains(camera.window.frame), "Camera drag escaped capture bounds")
        let edgeCenter = camera.currentLayout.centerX
        drag(CGSize(width: -10, height: 0))
        precondition(camera.currentLayout.centerX < edgeCenter, "Clamped camera drag retained invisible overshoot")
        let locked = camera.currentLayout
        camera.show(in: capture, layout: locked, editable: false)
        let lockedFrame = camera.window.frame
        let lockedChanges = changes
        drag(CGSize(width: -100, height: -100))
        precondition(camera.currentLayout == locked && camera.window.frame == lockedFrame && changes == lockedChanges,
                     "Camera moved during the locked recording layout")
        precondition(!camera.window.canBecomeKey && camera.window.sharingType == .none && camera.window.ignoresMouseEvents,
                     "Camera can take keyboard focus or appear in the captured screen")

        var stopped = 0, cancelled = 0, revealed = 0
        bar.onStop = { stopped += 1 }
        bar.onCancel = { cancelled += 1 }
        bar.onShowCamera = { revealed += 1 }
        bar.show(on: screen)
        bar.window.contentView!.layoutSubtreeIfNeeded()
        precondition(NSApp.keyWindow === previousKey && NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp,
                     "Showing recording controls stole keyboard focus or activated the app")
        precondition(bar.window.styleMask.contains(.nonactivatingPanel) && bar.window.sharingType == .none
                     && bar.window.frame.width > bar.window.frame.height * 4,
                     "Recording bar is not compact, nonactivating or excluded from capture")
        let userPosition = CGPoint(x: bar.window.frame.minX + 23, y: bar.window.frame.minY - 17)
        bar.window.setFrameOrigin(userPosition)
        bar.show(on: screen)
        precondition(bar.window.frame.origin == userPosition, "Revealing the recording bar reset its dragged position")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let buttons = descendants(bar.window.contentView!).compactMap { $0 as? NSButton }
        precondition(buttons.count == 3, "Recording bar lost actions or added unsupported controls")
        func button(_ label: String) -> NSButton { buttons.first { $0.toolTip == label }! }
        for status in ["Préparation…", "● 12:34", "Finalisation de l’enregistrement…"] {
            bar.update(status: status, canStop: false, canCancel: true, cameraEnabled: false)
            bar.window.contentView!.layoutSubtreeIfNeeded()
            for control in descendants(bar.window.contentView!).filter({ $0 is NSButton || $0 is NSTextField }) {
                let frame = control.convert(control.bounds, to: bar.window.contentView)
                precondition(!control.hasAmbiguousLayout && frame.width > 0 && frame.height > 0
                             && bar.window.contentView!.bounds.contains(frame), "Recording bar clips or ambiguously lays out a control")
            }
        }
        button("Arrêter l’enregistrement").performClick(nil)
        button("Afficher la caméra").performClick(nil)
        button("Annuler l’enregistrement").performClick(nil)
        precondition(stopped == 0 && revealed == 0 && cancelled == 1, "Disabled recording actions still dispatch")
        bar.update(status: "● 00:01", canStop: true, canCancel: true, cameraEnabled: true)
        precondition(buttons.allSatisfy(\.acceptsFirstResponder), "Recording buttons are not keyboard focusable")
        let stop = button("Arrêter l’enregistrement")
        precondition(bar.window.makeFirstResponder(stop), "Recording Stop cannot receive keyboard focus")
        bar.window.selectNextKeyView(stop)
        precondition(bar.window.firstResponder === button("Afficher la caméra"), "Recording bar keyboard navigation is broken")
        buttons.forEach { $0.performClick(nil) }
        precondition(stopped == 1 && revealed == 1 && cancelled == 2, "Recording buttons failed to dispatch callbacks")
        bar.close()
        camera.close()
        precondition(!bar.window.isVisible && !camera.window.isVisible, "Recording overlays remain visible after close")
        print("PASS: camera shapes/clipping; aspect-fill without mirror; placeholder; top-left placement; drag/clamping/locked layout; nonactivation; compact recording bar layout/states/callbacks; close")
    }
}
