import AppKit

/// Image and annotations share bottom-left-origin, native-pixel coordinates.
@MainActor
final class AnnotationCanvas: NSView {
    enum Tool: Int { case preview, arrow, rectangle }

    private struct Annotation {
        let tool: Tool
        let start: CGPoint
        let end: CGPoint
    }

    enum ExportError: LocalizedError {
        case unavailableImage, cannotRender, cannotEncode
        var errorDescription: String? {
            switch self {
            case .unavailableImage: return "Cette image ne peut pas être lue."
            case .cannotRender: return "Impossible de préparer l’image pour l’export."
            case .cannotEncode: return "Impossible d’encoder l’image au format PNG."
            }
        }
    }

    var tool: Tool = .preview {
        didSet {
            cancelDraft()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onChange: (() -> Void)?
    private let source: CGImage?
    private var annotations: [Annotation] = []
    private var draft: Annotation?
    private var dragStart: CGPoint?

    var pixelSize: CGSize {
        guard let source else { return .zero }
        return CGSize(width: source.width, height: source.height)
    }
    var hasImage: Bool { source != nil }
    var canUndo: Bool { !annotations.isEmpty }
    var annotationCount: Int { annotations.count }
    var fitPercentage: Int {
        guard pixelSize.width > 0 else { return 0 }
        return Int((imageRect.width / pixelSize.width * 100).rounded())
    }

    init(image: NSImage) {
        source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: .zero)
        setAccessibilityLabel("Aperçu de la capture")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    private var imageRect: CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let available = bounds.insetBy(dx: 28, dy: 28)
        guard available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / pixelSize.width, available.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        onChange?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if tool != .preview, source != nil { addCursorRect(imageRect, cursor: .crosshair) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let source, let context = NSGraphicsContext.current?.cgContext else {
            let text = "Aucun aperçu disponible"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
            return
        }
        let rect = imageRect
        guard rect.width > 0 else { return }

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 16,
                          color: NSColor.black.withAlphaComponent(0.16).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.restoreGState()

        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / pixelSize.width, y: rect.height / pixelSize.height)
        renderAnnotations(in: context, includeDraft: true)
        context.restoreGState()
    }

    private func nativePoint(_ location: CGPoint, clamp: Bool) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(location) else { return nil }
        return CGPoint(x: max(0, min(pixelSize.width, (location.x - rect.minX) * pixelSize.width / rect.width)),
                       y: max(0, min(pixelSize.height, (location.y - rect.minY) * pixelSize.height / rect.height)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard tool != .preview,
              let start = nativePoint(convert(event.locationInWindow, from: nil), clamp: false) else { return }
        dragStart = start
        draft = Annotation(tool: tool, start: start, end: start)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart,
              let end = nativePoint(convert(event.locationInWindow, from: nil), clamp: true) else { return }
        draft = Annotation(tool: tool, start: start, end: end)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart,
              let end = nativePoint(convert(event.locationInWindow, from: nil), clamp: true) else {
            cancelDraft()
            return
        }
        let distance = hypot(end.x - start.x, end.y - start.y)
        let minimumDistance = 3 * pixelSize.width / max(imageRect.width, 1)
        if distance >= minimumDistance {
            annotations.append(Annotation(tool: tool, start: start, end: end))
        }
        cancelDraft()
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDraft() } else { super.keyDown(with: event) }
    }

    func undoLastAnnotation() {
        cancelDraft()
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
        onChange?()
    }

    private func cancelDraft() {
        dragStart = nil
        draft = nil
        needsDisplay = true
    }

    // A fixed pixel-space style keeps the annotation identical at every view size and in exports.
    private var strokeWidth: CGFloat { max(3, min(pixelSize.width, pixelSize.height) / 260) }

    private func renderAnnotations(in context: CGContext, includeDraft: Bool) {
        let objects = annotations + (includeDraft ? draft.map { [$0] } ?? [] : [])
        context.setStrokeColor(CGColor(srgbRed: 0.98, green: 0.22, blue: 0.25, alpha: 1))
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.22, blue: 0.25, alpha: 1))
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in objects {
            switch annotation.tool {
            case .preview: break
            case .rectangle:
                let rectangle = CGRect(x: min(annotation.start.x, annotation.end.x),
                                       y: min(annotation.start.y, annotation.end.y),
                                       width: abs(annotation.end.x - annotation.start.x),
                                       height: abs(annotation.end.y - annotation.start.y))
                context.stroke(rectangle)
            case .arrow:
                let dx = annotation.end.x - annotation.start.x
                let dy = annotation.end.y - annotation.start.y
                let length = hypot(dx, dy)
                guard length > 0 else { continue }
                let head = min(strokeWidth * 5, length * 0.45)
                let ux = dx / length, uy = dy / length
                let base = CGPoint(x: annotation.end.x - ux * head, y: annotation.end.y - uy * head)
                context.beginPath()
                context.move(to: annotation.start)
                context.addLine(to: base)
                context.strokePath()
                context.beginPath()
                context.move(to: annotation.end)
                context.addLine(to: CGPoint(x: base.x - uy * head * 0.45, y: base.y + ux * head * 0.45))
                context.addLine(to: CGPoint(x: base.x + uy * head * 0.45, y: base.y - ux * head * 0.45))
                context.closePath()
                context.fillPath()
            }
        }
    }

    func exportedPNG() throws -> Data {
        guard let source else { throw ExportError.unavailableImage }
        let result: CGImage
        if annotations.isEmpty {
            result = source
        } else {
            let space = (source.colorSpace?.model == .rgb ? source.colorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: source.width, height: source.height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ExportError.cannotRender
            }
            context.draw(source, in: CGRect(origin: .zero, size: pixelSize))
            renderAnnotations(in: context, includeDraft: false)
            guard let rendered = context.makeImage() else { throw ExportError.cannotRender }
            result = rendered
        }
        guard let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
            throw ExportError.cannotEncode
        }
        return data
    }
}
