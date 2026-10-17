import AppKit

@main struct ScrollingPreviewSmokeTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func strip(_ width: Int, _ height: Int, _ color: CGColor) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let red = strip(100, 100, NSColor.red.cgColor)
        let blue = strip(100, 100, NSColor.blue.cgColor)
        let view = ScrollingPreviewView()
        func render() -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
                                      pixelsHigh: Int(view.bounds.height), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func isRed(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return color.redComponent > 0.8 && color.blueComponent < 0.2
        }
        func isBlue(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return color.blueComponent > 0.8 && color.redComponent < 0.2
        }
        view.update(strips: [red, blue], sourceWidth: 100, totalHeight: 200)
        let rep = render()
        precondition(isRed(rep, 110, 60) && isBlue(rep, 110, 200), "First strip must be at the top")
        precondition(!isRed(rep, 40, 60), "Aspect-fit must preserve horizontal margins")
        precondition(view.accessibilityLabel()!.contains("100 × 200"))
        let patternedContext = CGContext(data: nil, width: 100, height: 200, bitsPerComponent: 8,
                                         bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        patternedContext.setFillColor(NSColor.blue.cgColor)
        patternedContext.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        patternedContext.setFillColor(NSColor.red.cgColor)
        patternedContext.fill(CGRect(x: 0, y: 100, width: 100, height: 100))
        view.update(strips: [patternedContext.makeImage()!], sourceWidth: 100, totalHeight: 200)
        let patterned = render()
        precondition(isRed(patterned, 110, 60) && isBlue(patterned, 110, 200), "Pixels within each strip must remain upright")
        view.update(strips: [red, blue], sourceWidth: 100, totalHeight: 200)
        view.frame.size = CGSize(width: 120, height: 120)
        let resized = render()
        precondition(isRed(resized, 60, 30) && isBlue(resized, 60, 90))
        // One-pixel accepted strips must retain their relative height.
        view.update(strips: [strip(100, 1, NSColor.red.cgColor), strip(100, 99, NSColor.blue.cgColor)],
                    sourceWidth: 100, totalHeight: 100)
        let tiny = render()
        precondition(isBlue(tiny, 60, 60))
        view.update(strips: [strip(500, 10000, NSColor.red.cgColor)], sourceWidth: 500, totalHeight: 10000)
        let long = render()
        precondition(isRed(long, 60, 60) && !isRed(long, 55, 60), "Long content must fit entirely")
        view.reset()
        precondition(!isRed(render(), 60, 30))
        precondition(view.accessibilityLabel()!.contains("en attente"))
        view.update(strips: [red], sourceWidth: 0, totalHeight: 100)
        precondition(view.accessibilityLabel()!.contains("en attente"))
        print("PASS: preview order, aspect-fit, resize, tiny strips, long content, reset, accessibility")
    }
}
