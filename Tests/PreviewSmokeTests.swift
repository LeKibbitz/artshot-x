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
            let scale = min((canvas.bounds.width - 56) / 400, (canvas.bounds.height - 56) / 200)
            let origin = CGPoint(x: canvas.bounds.midX - 200 * scale, y: canvas.bounds.midY - 100 * scale)
            return NSEvent.mouseEvent(with: type, location: CGPoint(x: origin.x + x * scale, y: origin.y + y * scale),
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

        func click(_ x: CGFloat, _ y: CGFloat) {
            canvas.mouseDown(with: event(.leftMouseDown, x, y))
            canvas.mouseUp(with: event(.leftMouseUp, x, y))
        }
        func markerPixels(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [Int] {
            // Compare native pixels inside the circle, including its white number.
            var result: [Int] = []
            for dy in -10...10 {
                for dx in -10...10 {
                    let color = bitmap.colorAt(x: x + dx, y: 200 - y + dy)!.usingColorSpace(.sRGB)!
                    result.append(Int((color.redComponent * 255).rounded()))
                    result.append(Int((color.greenComponent * 255).rounded()))
                    result.append(Int((color.blueComponent * 255).rounded()))
                }
            }
            return result
        }
        canvas.tool = .step
        click(-10, 40)
        precondition(canvas.annotationCount == 0, "Click outside image placed a step")
        canvas.mouseDown(with: event(.leftMouseDown, 80, 40))
        canvas.mouseDragged(with: event(.leftMouseDragged, 95, 50))
        canvas.mouseUp(with: event(.leftMouseUp, 95, 50))
        precondition(canvas.stepCount == 1 && canvas.annotationCount == 1, "Step requires a drag or commits twice")
        let firstStep = NSBitmapImageRep(data: try canvas.exportedPNG())!
        let circle = firstStep.colorAt(x: 68, y: 160)!.usingColorSpace(.sRGB)!
        precondition(circle.redComponent > 0.9 && circle.greenComponent < 0.4,
                     "Step circle not anchored at mouse-down in native coordinates")
        let firstGlyph = markerPixels(firstStep, x: 80, y: 40)
        precondition(stride(from: 0, to: firstGlyph.count, by: 3).filter {
            firstGlyph[$0] > 230 && firstGlyph[$0 + 1] > 230 && firstGlyph[$0 + 2] > 230
        }.count > 10, "Step number is missing or illegible")

        canvas.tool = .rectangle
        canvas.mouseDown(with: event(.leftMouseDown, 280, 20))
        canvas.mouseUp(with: event(.leftMouseUp, 330, 70))
        canvas.tool = .step
        click(220, 40)
        precondition(canvas.stepCount == 2 && canvas.annotationCount == 3, "Other annotation changed step numbering")
        let numberedPNG = try canvas.exportedPNG()
        let numbered = NSBitmapImageRep(data: numberedPNG)!
        let secondGlyph = markerPixels(numbered, x: 220, y: 40)
        precondition(firstGlyph != secondGlyph, "Steps 1 and 2 rendered the same number")
        canvas.undoLastAnnotation()
        precondition(canvas.stepCount == 1 && canvas.annotationCount == 2, "Undo failed to remove last step")
        canvas.frame.size = NSSize(width: 856, height: 456)
        click(220, 40)
        let replacedPNG = try canvas.exportedPNG()
        precondition(replacedPNG == numberedPNG,
                     "Undo did not reuse number 2, or resize changed native export coordinates")
        canvas.undoLastAnnotation()
        canvas.undoLastAnnotation()
        precondition(canvas.stepCount == 1 && canvas.annotationCount == 1, "Undoing rectangle changed step count")
        click(220, 40)
        let afterMixedUndo = NSBitmapImageRep(data: try canvas.exportedPNG())!
        precondition(markerPixels(afterMixedUndo, x: 220, y: 40) == secondGlyph,
                     "Step numbering skipped a number after undoing another tool")
        for number in 3...10 { click(CGFloat(35 + (number - 3) * 45), 130) }
        precondition(canvas.stepCount == 10, "Step numbering did not reach double digits")
        let doubleDigit = NSBitmapImageRep(data: try canvas.exportedPNG())!
        precondition(doubleDigit.pixelsWide == 400 && doubleDigit.pixelsHigh == 200,
                     "Numbered export lost source resolution")
        let tenthGlyph = markerPixels(doubleDigit, x: 350, y: 130)
        precondition(stride(from: 0, to: tenthGlyph.count, by: 3).filter {
            tenthGlyph[$0] > 230 && tenthGlyph[$0 + 1] > 230 && tenthGlyph[$0 + 2] > 230
        }.count > 10, "Double-digit step text is missing")
        // Render the actual preview at a 2× fit and compare interior colors with PNG.
        let previewBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 856, pixelsHigh: 456,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .retagging(with: .sRGB)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: previewBitmap)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let previewCircle = previewBitmap.colorAt(x: 28 + 68 * 2, y: 456 - (28 + 40 * 2))!.usingColorSpace(.sRGB)!
        precondition(abs(previewCircle.redComponent - circle.redComponent) < 0.03 &&
                     abs(previewCircle.greenComponent - circle.greenComponent) < 0.03,
                     "Preview and exported step render differ")
        while canvas.canUndo { canvas.undoLastAnnotation() }
        precondition(canvas.stepCount == 0 && canvas.annotationCount == 0, "Undo did not clear steps")
        click(80, 40)
        let restarted = NSBitmapImageRep(data: try canvas.exportedPNG())!
        precondition(markerPixels(restarted, x: 80, y: 40) == firstGlyph, "Numbering did not restart at 1")
        let preview = PreviewWindowController(image: image)
        precondition(preview.window?.title == "ArtShot X")
        precondition(preview.window?.collectionBehavior.contains(.fullScreenPrimary) == true,
                     "Preview lost native fullscreen support")
        let toolItem = preview.window!.toolbar!.items.first { $0.itemIdentifier.rawValue == "ArtShotX.preview.tools" }
        let toolControl = toolItem?.view as? NSSegmentedControl
        precondition(toolControl?.segmentCount == 4 && toolControl?.label(forSegment: 3) == "Étapes",
                     "Numbered steps tool is missing from toolbar")
        let unavailable = AnnotationCanvas(image: NSImage(size: .zero))
        precondition(!unavailable.hasImage)
        do {
            _ = try unavailable.exportedPNG()
            preconditionFailure("Empty image unexpectedly exported")
        } catch AnnotationCanvas.ExportError.unavailableImage {
            // Expected recoverable failure, rather than a crash or bogus file.
        }
        print("PASS: Retina resolution; orientation; rectangle/arrow export; numbered clicks; mixed-tool undo and numbering reuse; double digits; resize/export parity; preview rendering; fullscreen; toolbar; empty-image error")
    }
}
