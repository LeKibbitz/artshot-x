import AppKit

/// Draws accepted capture strips directly, keeping allocation bounded by the view size.
@MainActor
final class ScrollingPreviewView: NSView {
    private enum Style {
        static let size = CGSize(width: 220, height: 260)
        static let inset: CGFloat = 10
        static let radius: CGFloat = 8
        static let background = NSColor(white: 0.08, alpha: 1)
        static let border = NSColor(white: 1, alpha: 0.14)
        static let placeholder = NSColor(white: 0.65, alpha: 1)
    }

    private var strips: [CGImage] = []
    private var sourceWidth = 0
    private var totalHeight = 0

    override var intrinsicContentSize: NSSize { Style.size }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        reset()
    }

    convenience init() {
        self.init(frame: NSRect(origin: .zero, size: Style.size))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        reset()
    }

    func update(strips: [CGImage], sourceWidth: Int, totalHeight: Int) {
        guard !strips.isEmpty, sourceWidth > 0, totalHeight > 0 else {
            reset()
            return
        }
        self.strips = strips
        self.sourceWidth = sourceWidth
        self.totalHeight = totalHeight
        setAccessibilityLabel("Aperçu de la capture défilante, \(sourceWidth) × \(totalHeight) pixels")
        needsDisplay = true
    }

    func reset() {
        strips.removeAll()
        sourceWidth = 0
        totalHeight = 0
        setAccessibilityLabel("Aperçu de la capture défilante, en attente")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let outline = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                             cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil)
        context.addPath(outline)
        context.setFillColor(Style.background.cgColor)
        context.fillPath()
        context.addPath(outline)
        context.clip()

        let available = bounds.insetBy(dx: Style.inset, dy: Style.inset)
        if sourceWidth > 0, totalHeight > 0, available.width > 0, available.height > 0 {
            let scale = min(available.width / CGFloat(sourceWidth), available.height / CGFloat(totalHeight))
            let width = CGFloat(sourceWidth) * scale
            let height = CGFloat(totalHeight) * scale
            let left = available.midX - width / 2
            var top = available.midY + height / 2
            context.interpolationQuality = .high
            // AppKit's default coordinate system has its origin at the bottom left.
            // Each original image is drawn upright, starting with the first strip at the top.
            for strip in strips {
                let stripHeight = CGFloat(strip.height) * scale
                context.draw(strip, in: CGRect(x: left, y: top - stripHeight, width: width, height: stripHeight))
                top -= stripHeight
            }
        } else {
            let text = "Aperçu de la capture" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Style.placeholder
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
        }
        context.addPath(outline)
        context.setStrokeColor(Style.border.cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }
}
