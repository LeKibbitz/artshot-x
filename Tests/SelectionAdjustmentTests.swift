
@main
struct SelectionAdjustmentTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let view = SelectionView(frame: frame, screenFrame: frame, scale: 2)
        let original = CGRect(x: 100, y: 100, width: 200, height: 160)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func drag(_ start: CGPoint, _ end: CGPoint) {
            view.mouseDown(with: event(.leftMouseDown, start))
            view.mouseDragged(with: event(.leftMouseDragged, end))
            view.mouseUp(with: event(.leftMouseUp, end))
        }
        let handles = [CGPoint(x:100,y:100), CGPoint(x:200,y:100), CGPoint(x:300,y:100), CGPoint(x:300,y:180),
                       CGPoint(x:300,y:260), CGPoint(x:200,y:260), CGPoint(x:100,y:260), CGPoint(x:100,y:180)]
        let expectedHandles = [CGRect(x:120,y:120,width:180,height:140), CGRect(x:100,y:120,width:200,height:140),
                               CGRect(x:100,y:120,width:220,height:140), CGRect(x:100,y:100,width:220,height:160),
                               CGRect(x:100,y:100,width:220,height:180), CGRect(x:100,y:100,width:200,height:180),
                               CGRect(x:120,y:100,width:180,height:180), CGRect(x:120,y:100,width:180,height:160)]
        for (index, handle) in handles.enumerated() {
            view.setGlobalSelection(original)
            drag(handle, CGPoint(x: handle.x + 20, y: handle.y + 20))
            precondition(view.globalSelection == expectedHandles[index], "Wrong rectangle for handle \(index)")
            precondition(frame.contains(view.globalSelection!), "Handle escaped display")
        }
        view.setGlobalSelection(original)
        drag(CGPoint(x: 150,y: 150), CGPoint(x: 1000,y: 1000))
        precondition(view.globalSelection == CGRect(x:600,y:440,width:200,height:160))
        view.setGlobalSelection(original)
        drag(CGPoint(x:100,y:100), CGPoint(x:400,y:400))
        precondition(view.globalSelection?.size == CGSize(width:2,height:2))
        drag(CGPoint(x:10,y:10), CGPoint(x:60,y:70))
        precondition(view.globalSelection == CGRect(x:10,y:10,width:50,height:60))
        let edgeCases: [(CGPoint, CGPoint, CGRect)] = [
            (CGPoint(x:100,y:180), CGPoint(x:-50,y:180), CGRect(x:0,y:100,width:300,height:160)),
            (CGPoint(x:300,y:180), CGPoint(x:900,y:180), CGRect(x:100,y:100,width:700,height:160)),
            (CGPoint(x:200,y:100), CGPoint(x:200,y:-50), CGRect(x:100,y:0,width:200,height:260)),
            (CGPoint(x:200,y:260), CGPoint(x:200,y:700), CGRect(x:100,y:100,width:200,height:500)),
            (CGPoint(x:300,y:180), CGPoint(x:50,y:180), CGRect(x:100,y:100,width:2,height:160)),
            (CGPoint(x:200,y:260), CGPoint(x:200,y:50), CGRect(x:100,y:100,width:200,height:2))
        ]
        for (start, end, expected) in edgeCases {
            view.setGlobalSelection(original)
            drag(start, end)
            precondition(view.globalSelection == expected, "Edge resize did not clamp correctly")
        }
        let negativeScreen = CGRect(x:-1200,y:-300,width:800,height:600)
        let negativeView = SelectionView(frame: frame, screenFrame: negativeScreen, scale: 1)
        negativeView.setGlobalSelection(CGRect(x:-1100,y:-200,width:200,height:160))
        precondition(negativeView.globalSelection == CGRect(x:-1100,y:-200,width:200,height:160))
        negativeView.setGlobalSelection(CGRect(x:-1250,y:-350,width:200,height:200))
        precondition(negativeView.globalSelection == CGRect(x:-1200,y:-300,width:150,height:150))
        negativeView.setGlobalSelection(CGRect(x:-500,y:200,width:200,height:200))
        precondition(negativeView.globalSelection == CGRect(x:-500,y:200,width:100,height:100))
        // CoreGraphics' sentinel has finite extreme coordinates and clips to the display.
        negativeView.setGlobalSelection(.infinite)
        precondition(negativeView.globalSelection == negativeScreen)
        let invalidRects: [CGRect?] = [nil, .null, .zero,
            CGRect(x:0,y:0,width:20,height:20), // Entirely outside this negative-origin screen.
            CGRect(x:-1100,y:-200,width:1,height:20),
            CGRect(x:CGFloat.nan,y:-200,width:20,height:20),
            CGRect(x:-1100,y:-200,width:CGFloat.infinity,height:20)]
        for (index, rect) in invalidRects.enumerated() {
            negativeView.setGlobalSelection(rect)
            precondition(negativeView.globalSelection == nil, "Invalid selection \(index) was accepted: \(String(describing: negativeView.globalSelection))")
        }
        view.setGlobalSelection(original)
        var finishes = 0, changes = 0
        view.didFinish = { _ in finishes += 1 }
        view.didChange = { _ in changes += 1 }
        view.isPreparing = true
        drag(CGPoint(x:400,y:400), CGPoint(x:500,y:500))
        precondition(finishes == 0 && changes == 1)
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        view.keyDown(with: key(36))
        precondition(finishes == 0 && changes == 2)
        view.isPreparing = false
        view.keyDown(with: key(36))
        precondition(finishes == 1)
        view.keyDown(with: key(53))
        precondition(finishes == 2)
        // Render only owned AppKit views over a synthetic background, never the desktop.
        let snapshotSize = CGSize(width: 1000, height: 720)
        let preview = SelectionView(frame: CGRect(origin: .zero, size: snapshotSize),
                                    screenFrame: CGRect(origin: .zero, size: snapshotSize), scale: 1)
        preview.isPreparing = true
        preview.setGlobalSelection(CGRect(x: 230, y: 230, width: 540, height: 330))
        let toolbar = CapturePanelController()
        toolbar.setSelectionReady(true)
        toolbar.setSelection(isRegion: true, pixelSize: CGSize(width: 1080, height: 660))
        let image = NSImage(size: snapshotSize)
        image.lockFocus()
        NSColor(calibratedRed: 0.18, green: 0.23, blue: 0.30, alpha: 1).setFill()
        CGRect(origin: .zero, size: snapshotSize).fill()
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 145, y: 170, width: 710, height: 450), xRadius: 16, yRadius: 16).fill()
        ("Synthetic workspace" as NSString).draw(at: CGPoint(x: 185, y: 572),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.darkGray])
        for index in 0..<5 {
            NSColor(calibratedWhite: 0.65 + CGFloat(index) * 0.035, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 185, y: 250 + index * 54, width: 410 + index * 24, height: 24), xRadius: 6, yRadius: 6).fill()
        }
        preview.draw(preview.bounds)
        if let content = toolbar.window?.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let toolbarImage = NSImage(size: content.bounds.size)
            toolbarImage.addRepresentation(bitmap)
            toolbarImage.draw(in: CGRect(x: 178, y: 100, width: 644, height: 94))
        }
        image.unlockFocus()
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("replica/clone-screens/selection-adjustment-synthetic.png")
        try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
        print("Synthetic snapshot: \(output.path)")
        print("Selection adjustment tests passed")
    }
}
