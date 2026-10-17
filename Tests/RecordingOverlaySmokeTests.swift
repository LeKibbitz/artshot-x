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
        func saveSnapshot(_ bitmap: NSBitmapImageRep, name: String) {
            guard let path = ProcessInfo.processInfo.environment["ARTSHOT_OVERLAY_SNAPSHOT_DIR"] else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
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
            if shape == .verticalOval {
                precondition(abs(expected.width / expected.height - 0.75) < 0.001,
                             "Vertical camera oval lost its portrait 3:4 proportions")
            }
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

        // The portrait fixture matches the oval's aspect ratio. Zooming into its green
        // center must remove both side bands without resizing or moving the window.
        let zoomContext = CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index, color) in [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                               CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                               CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            zoomContext.setFillColor(color)
            zoomContext.fill(CGRect(x: index * 100, y: 0, width: 100, height: 400))
        }
        let zoomImage = zoomContext.makeImage()!
        let oval = CameraLayout(shape: .verticalOval, widthFraction: 0.23, centerX: 0.5, centerY: 0.5)
        camera.show(in: capture, layout: oval, editable: true)
        camera.update(image: zoomImage)
        let unzoomedFrame = camera.window.frame
        let unzoomed = snapshot(camera.window.contentView!)
        saveSnapshot(unzoomed, name: "camera-vertical-oval-zoom-1.png")
        var zoomedOval = oval
        zoomedOval.zoom = 2
        camera.show(in: capture, layout: zoomedOval, editable: true)
        let zoomed = snapshot(camera.window.contentView!)
        saveSnapshot(zoomed, name: "camera-vertical-oval-zoom-2.png")
        precondition(camera.window.frame == unzoomedFrame && zoomed.pixelsWide == unzoomed.pixelsWide &&
                     zoomed.pixelsHigh == unzoomed.pixelsHigh,
                     "Camera zoom changed the bubble size or placement")
        for fraction in [0.2, 0.8] {
            let x = Int(Double(zoomed.pixelsWide) * fraction)
            let y = zoomed.pixelsHigh / 2
            let before = unzoomed.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let after = zoomed.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            precondition((fraction < 0.5 ? before.redComponent : before.blueComponent) > 0.9 &&
                         after.greenComponent > 0.9 && after.redComponent < 0.05 && after.blueComponent < 0.05,
                         "Camera zoom failed to crop symmetrically into the center of the source")
        }
        for bitmap in [unzoomed, zoomed] {
            let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
            for point in [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)] {
                precondition(bitmap.colorAt(x: point.0, y: point.1)!.alphaComponent < 0.05,
                             "Vertical oval zoom left opaque corners")
            }
            precondition(bitmap.colorAt(x: w / 2, y: h / 20)!.alphaComponent > 0.9 &&
                         bitmap.colorAt(x: w / 20, y: h / 2)!.alphaComponent > 0.9,
                         "Vertical oval mask cut its vertical or horizontal axis")
        }
        camera.close()

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

        var stopped = 0, cancelled = 0, paused = 0, restarted = 0
        bar.onStop = { stopped += 1 }
        bar.onCancel = { cancelled += 1 }
        bar.onPauseResume = { paused += 1 }
        bar.onRestart = { restarted += 1 }
        bar.show(on: screen)
        bar.window.contentView!.layoutSubtreeIfNeeded()
        precondition(NSApp.keyWindow === previousKey && NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp,
                     "Showing recording controls stole keyboard focus or activated the app")
        precondition(bar.window.styleMask.contains(.nonactivatingPanel) && bar.window.sharingType == .none
                     && bar.window.frame.width > bar.window.frame.height * 4,
                     "Recording bar is not compact, nonactivating or excluded from capture")
        precondition(bar.window.title == "ArtShot X · Télécommande", "Recording remote has no accessibility window title")
        let userPosition = CGPoint(x: bar.window.frame.minX + 23, y: bar.window.frame.minY - 17)
        bar.window.setFrameOrigin(userPosition)
        bar.show(on: screen)
        precondition(bar.window.frame.origin == userPosition, "Revealing the recording bar reset its dragged position")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let buttons = descendants(bar.window.contentView!).compactMap { $0 as? NSButton }
        precondition(buttons.count == 4, "Recording remote lost Stop, Pause, Restart or Delete")
        func button(_ label: String) -> NSButton { buttons.first { $0.toolTip == label }! }
        for status in ["Préparation…", "0:05", "12:34", "1:02:03", "Finalisation de l’enregistrement…"] {
            bar.update(status: status, canStop: false, canCancel: true, canRestart: false, canPause: false, isPaused: false)
            bar.window.contentView!.layoutSubtreeIfNeeded()
            for control in descendants(bar.window.contentView!).filter({ $0 is NSButton || $0 is NSTextField }) {
                let frame = control.convert(control.bounds, to: bar.window.contentView)
                precondition(!control.hasAmbiguousLayout && frame.width > 0 && frame.height > 0
                             && bar.window.contentView!.bounds.contains(frame), "Recording bar clips or ambiguously lays out a control")
            }
            let label = descendants(bar.window.contentView!).compactMap { $0 as? NSTextField }.first!
            precondition(label.stringValue == status && label.textColor!.redComponent > label.textColor!.greenComponent,
                         "Recording timer lost its status or red styling")
            if status == "1:02:03" {
                let textWidth = status.size(withAttributes: [.font: label.font!]).width
                precondition(textWidth <= label.bounds.width, "Hour-long recording timer is truncated")
            }
        }
        button("Arrêter l’enregistrement").performClick(nil)
        button("Pause").performClick(nil)
        button("Recommencer l’enregistrement").performClick(nil)
        button("Supprimer l’enregistrement").performClick(nil)
        precondition(stopped == 0 && paused == 0 && restarted == 0 && cancelled == 1, "Disabled recording actions still dispatch")
        bar.update(status: "0:05", canStop: true, canCancel: true, canRestart: true, canPause: true, isPaused: false)
        precondition(buttons.allSatisfy(\.acceptsFirstResponder), "Recording buttons are not keyboard focusable")
        let stop = button("Arrêter l’enregistrement")
        precondition(bar.window.makeFirstResponder(stop), "Recording Stop cannot receive keyboard focus")
        bar.window.selectNextKeyView(stop)
        precondition(bar.window.firstResponder === button("Pause"), "Recording remote keyboard navigation is broken")
        buttons.forEach { $0.performClick(nil) }
        precondition(stopped == 1 && paused == 1 && restarted == 1 && cancelled == 2, "Recording buttons failed to dispatch callbacks")
        let pauseImage = button("Pause").image
        bar.update(status: "0:05", canStop: true, canCancel: true, canRestart: true, canPause: true, isPaused: true)
        let resume = button("Reprendre")
        precondition(resume.accessibilityLabel() == "Reprendre" && resume.image !== pauseImage,
                     "Paused remote did not switch to Reprendre and its play icon")
        resume.performClick(nil)
        precondition(paused == 2, "Resume did not use the Pause/Resume callback")
        bar.update(status: "Finalisation…", canStop: false, canCancel: false, canRestart: false, canPause: false, isPaused: false)
        buttons.forEach { $0.performClick(nil) }
        precondition(stopped == 1 && paused == 2 && restarted == 1 && cancelled == 2,
                     "Finalization left destructive recording actions enabled")
        bar.update(status: "0:05", canStop: true, canCancel: true, canRestart: true, canPause: false, isPaused: false)
        _ = bar.window.makeFirstResponder(stop)
        bar.window.selectNextKeyView(stop)
        precondition(bar.window.firstResponder === button("Recommencer l’enregistrement"),
                     "Keyboard navigation failed to skip disabled Pause")
        bar.update(status: "0:05", canStop: true, canCancel: true, canRestart: true, canPause: true, isPaused: false)
        let ordered = buttons.map { $0.convert($0.bounds, to: bar.window.contentView).midX }
        precondition(zip(ordered, ordered.dropFirst()).allSatisfy { $0 < $1 }, "Remote actions are not ordered Stop, Pause, Restart, Delete")
        let handle = descendants(bar.window.contentView!).compactMap { $0 as? NSImageView }.first { $0.toolTip == "Déplacer la télécommande" }!
        precondition(handle.image != nil, "Remote drag handle has no visible symbol")
        precondition(handle.convert(handle.bounds, to: bar.window.contentView).midX > ordered.last!, "Remote drag handle is not at the right end")
        if let path = ProcessInfo.processInfo.environment["ARTSHOT_OVERLAY_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let content = bar.window.contentView!
            content.layoutSubtreeIfNeeded()
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("recording-control-bar.png"))
        }
        bar.close()
        camera.close()
        precondition(!bar.window.isVisible && !camera.window.isVisible, "Recording overlays remain visible after close")
        print("PASS: camera shapes/clipping; portrait oval; centered digital zoom with fixed frame; aspect-fill without mirror; placeholder; top-left placement; drag/clamping/locked layout; nonactivation; segmented remote layout; hour timer; Pause/Resume/Restart/Delete/Stop callbacks; keyboard navigation; disabled finalization; close")
    }
}
