import AppKit

// Standalone AppKit harness. Run scripts/test-preview.sh; no window is shown,
// capture permission is not requested, and the pasteboard is never accessed.
@main struct PreviewSmokeTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
        let cgImage = context.makeImage()!
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 100))
        let canvas = AnnotationCanvas(image: image)
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        let original = NSBitmapImageRep(data: try canvas.exportedPNG())!
        precondition(original.pixelsWide == 400 && original.pixelsHigh == 200, "Retina resolution lost")
        let source = NSBitmapImageRep(cgImage: cgImage)
        for y in [25, 175] {
            let a = original.colorAt(x: 40, y: y)!.usingColorSpace(.sRGB)!
            let b = source.colorAt(x: 40, y: y)!.usingColorSpace(.sRGB)!
            precondition(abs(a.redComponent - b.redComponent) < 0.01, "Source export flipped")
        }
        canvas.tool = .rectangle
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: 28 + x * 1.36, y: 64 + y * 1.36),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, 40, 20))
        canvas.mouseDragged(with: event(.leftMouseDragged, 120, 80))
        canvas.mouseUp(with: event(.leftMouseUp, 120, 80))
        precondition(canvas.annotationCount == 1 && canvas.canUndo, "Rectangle not committed")
        let annotated = NSBitmapImageRep(data: try canvas.exportedPNG())!
        precondition(annotated.pixelsWide == 400 && annotated.pixelsHigh == 200)
        let marked = annotated.colorAt(x: 40, y: 150)!.usingColorSpace(.sRGB)!
        let opposite = annotated.colorAt(x: 40, y: 50)!.usingColorSpace(.sRGB)!
        precondition(marked.redComponent > 0.9 && marked.greenComponent < 0.4, "Annotation coordinates incorrect")
        precondition(opposite.greenComponent > 0.7, "Annotation vertically flipped")
        canvas.undoLastAnnotation()
        precondition(!canvas.canUndo && canvas.annotationCount == 0)
        let restored = NSBitmapImageRep(data: try canvas.exportedPNG())!
        for y in [50, 150] {
            let a = restored.colorAt(x: 40, y: y)!.usingColorSpace(.sRGB)!
            let b = original.colorAt(x: 40, y: y)!.usingColorSpace(.sRGB)!
            precondition(abs(a.redComponent - b.redComponent) < 0.01 &&
                         abs(a.greenComponent - b.greenComponent) < 0.01,
                         "Undo failed to restore original pixels")
        }
        canvas.mouseDown(with: event(.leftMouseDown, 40, 20))
        canvas.mouseUp(with: event(.leftMouseUp, 40, 20))
        precondition(canvas.annotationCount == 0, "Zero-length drag created annotation")
        canvas.tool = .arrow
        canvas.mouseDown(with: event(.leftMouseDown, 180, 20))
        canvas.mouseDragged(with: event(.leftMouseDragged, 240, 80))
        canvas.mouseUp(with: event(.leftMouseUp, 240, 80))
        let arrow = NSBitmapImageRep(data: try canvas.exportedPNG())!
        let arrowShaft = arrow.colorAt(x: 200, y: 160)!.usingColorSpace(.sRGB)!
        precondition(arrowShaft.redComponent > 0.9 && arrowShaft.greenComponent < 0.4,
                     "Arrow was not burned into exported pixels")
        canvas.undoLastAnnotation()
        let preview = PreviewWindowController(image: image)
        precondition(preview.window?.title == "ArtShot X")
        let unavailable = AnnotationCanvas(image: NSImage(size: .zero))
        precondition(!unavailable.hasImage)
        do {
            _ = try unavailable.exportedPNG()
            preconditionFailure("Empty image unexpectedly exported")
        } catch AnnotationCanvas.ExportError.unavailableImage {
            // Expected recoverable failure, rather than a crash or bogus file.
        }
        print("PASS: Retina resolution; asymmetric orientation; rectangle and arrow export; undo restores pixels; zero-length drag; preview init; empty-image error")
    }
}
