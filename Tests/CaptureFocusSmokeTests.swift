// HARNESS: SelectionOverlay.swift
extension SelectionOverlayController {
    @MainActor func completeTestRegion() {
        let overlay = window!
        let view = overlay.contentView!
        for (type, point) in [(NSEvent.EventType.leftMouseDown, NSPoint(x: 20, y: 20)), (.leftMouseDragged, NSPoint(x: 180, y: 140)), (.leftMouseUp, NSPoint(x: 180, y: 140))] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: overlay.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        FocusProbe.key(36, to: overlay)
    }

    @MainActor static func checkFocus(on screen: NSScreen) {
        let controller = SelectionOverlayController()
        var callbacks = 0
        controller.begin(on: screen) { rect in
            callbacks += 1
            precondition(rect == nil && controller.window == nil, "Selection must close before cancellation callback")
        }
        let overlay = controller.window!
        FocusProbe.checkPanel(overlay, on: screen, key: true)
        FocusProbe.key(53, to: overlay)
        controller.cancel()
        precondition(callbacks == 1, "Selection cancellation completed twice")

        controller.begin(on: screen) { rect in
            callbacks += 1
            precondition(rect != nil && controller.window == nil, "Selection must close before capture callback")
        }
        let selected = controller.window!
        let view = selected.contentView!
        for (type, point) in [(NSEvent.EventType.leftMouseDown, NSPoint(x: 20, y: 20)), (.leftMouseDragged, NSPoint(x: 180, y: 140)), (.leftMouseUp, NSPoint(x: 180, y: 140))] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: selected.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        FocusProbe.key(36, to: selected)
        controller.cancel()
        precondition(callbacks == 2, "Selection Enter failed or completed twice")
    }
}
// HARNESS: ScrollingCaptureController.swift
extension ScrollingCaptureController {
    @MainActor static func checkFocus(on screen: NSScreen) {
        let controller = ScrollingCaptureController()
        // Only create the real HUD; never start screen capture or sampling.
        controller.showPanel(on: screen, avoiding: screen.frame.insetBy(dx: 200, dy: 200))
        FocusProbe.checkPanel(controller.panel!, on: screen, key: false)
        controller.cancel()
        precondition(controller.panel == nil)
    }
}
// HARNESS: RecordingController.swift
extension RecordingController {
    @MainActor func assertPreparedTestRegion(_ region: CGRect, on targetScreen: NSScreen) {
        precondition(sourceRegion == region && screen === targetScreen && regionButton.state == .on,
                     "Video options did not inherit the prepared capture area")
        precondition(cameraSource == nil, "Prepared video test must not open camera hardware")
    }

    @MainActor static func checkFocus(on screen: NSScreen) {
        let controller = RecordingController()
        controller.present(on: screen)
        let options = controller.optionsWindow!
        FocusProbe.checkPanel(options, on: screen, key: true)
        precondition(controller.revealActiveControls())
        FocusProbe.checkPanel(options, on: screen, key: true)
        precondition(controller.cameraSource == nil, "Focus test must never start camera hardware")
        controller.regionButton.state = .on
        controller.regionToggled()
        precondition(controller.isSelecting && !options.isVisible)
        controller.regionSelector.cancel()
        precondition(!controller.isSelecting && options.isVisible && controller.sourceRegion == nil)
        FocusProbe.checkPanel(options, on: screen, key: true)
        controller.cancel()
    }
}
// HARNESS: AppDelegate.swift
extension AppDelegate {
    @MainActor static func checkFocus() {
        let delegate = AppDelegate()
        delegate.panel = CapturePanelController()
        delegate.quickAccess = QuickAccessController()
        let editor = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        editor.orderBack(nil)
        defer { editor.close(); delegate.panel.window?.orderOut(nil) }
        let frame = editor.frame
        delegate.showPanel(nil)
        precondition(editor.isVisible && editor.frame == frame, "Opening capture controls hid or moved an editor")
        precondition(!editor.isKeyWindow && !editor.isMainWindow, "Opening capture controls promoted an editor")
        let targetScreen = delegate.preparedScreen!
        delegate.selectTargetRegion()
        precondition(delegate.busy && !delegate.panel.window!.isVisible)
        delegate.selection.completeTestRegion()
        let region = delegate.preparedRegion!
        precondition(region.size == CGSize(width: 160, height: 120))
        precondition(!delegate.busy && delegate.panel.window!.isVisible && !delegate.recording.isBusy,
                     "Preparing a region must return to the action bar without starting capture")
        precondition(delegate.preparedScreen === targetScreen, "Selection changed the target display")
        delegate.recordPreparedTarget()
        delegate.recording.assertPreparedTestRegion(region, on: targetScreen)
        precondition(delegate.preparedScreen == nil && !delegate.panel.window!.isVisible)
        delegate.recording.cancel()
        delegate.preparedScreen = targetScreen
        delegate.preparedRegion = region
        delegate.selectTargetDisplay()
        precondition(delegate.preparedRegion == nil && delegate.preparedScreen === targetScreen && delegate.panel.window!.isVisible,
                     "Display selection did not clear the prepared region")
        delegate.clearPreparedTarget()
    }
}
// HARNESS: CaptureTargetOutline.swift
extension CaptureTargetOutline {
    @MainActor static func checkFocus(on screen: NSScreen) {
        let outline = CaptureTargetOutline()
        let region = screen.frame.insetBy(dx: 100, dy: 100)
        outline.show(region: region)
        let window = outline.panel!
        FocusProbe.checkPanel(window, on: screen, key: false)
        precondition(window.ignoresMouseEvents && window.frame == region && window.sharingType == .none,
                     "Prepared area outline must preserve scrolling input and stay outside captures")
        outline.hide()
        precondition(outline.panel == nil)
    }
}
// HARNESS: Main.swift
import AppKit

@MainActor enum FocusProbe {
    static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.08)) }
    static func checkPanel(_ window: NSWindow, on screen: NSScreen, key: Bool) {
        settle()
        precondition(window is NSPanel && window.styleMask.contains(.nonactivatingPanel))
        precondition(window.collectionBehavior.contains(.canJoinAllSpaces) && window.collectionBehavior.contains(.fullScreenAuxiliary))
        precondition(window.canBecomeKey == key && !window.canBecomeMain, "Unexpected key/main eligibility for \(type(of: window))")
        precondition(window.isVisible && window.isOnActiveSpace, "Capture UI was not shown on the active Space")
        precondition(screen.frame.intersects(window.frame), "Capture UI missed its requested display")
    }
    static func key(_ code: UInt16, to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : "\r", charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r", isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
}

@main struct CaptureFocusSmokeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("A macOS login session is required") }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        precondition(frontPID != ProcessInfo.processInfo.processIdentifier && !NSApp.isActive, "Run focus smoke test from another foreground app")
        var activations = 0
        var spaceChanges = 0
        let activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { _ in activations += 1 }
        let space = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in spaceChanges += 1 }
        defer { NotificationCenter.default.removeObserver(activation); NSWorkspace.shared.notificationCenter.removeObserver(space) }
        func unchanged() {
            FocusProbe.settle()
            precondition(!NSApp.isActive && activations == 0, "Capture controls activated the application")
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID, "Capture controls changed the foreground application")
            precondition(spaceChanges == 0, "Capture controls changed the active Space")
        }
        AppDelegate.checkFocus(); unchanged()
        SelectionOverlayController.checkFocus(on: screen); unchanged()
        ScrollingCaptureController.checkFocus(on: screen); unchanged()
        CaptureTargetOutline.checkFocus(on: screen); unchanged()
        RecordingController.checkFocus(on: screen); unchanged()
        print("PASS: capture menu/editor isolation and prepared region/display/video routing; input-transparent target outline; selection Enter/Escape and exactly-once completion; scroll HUD; recording options/reveal/region cancellation; foreground app and Space preserved without global input or capture hardware")
    }
}
