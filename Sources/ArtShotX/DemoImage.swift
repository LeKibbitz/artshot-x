import AppKit

@MainActor
enum DemoImage {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 1000, height: 650))
        image.lockFocus()
        NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 650)).fill()
        NSColor(calibratedRed: 0.59, green: 0.94, blue: 0.76, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 520, width: 136, height: 36), xRadius: 18, yRadius: 18).fill()
        draw("IMAGE D’ESSAI", at: CGPoint(x: 81, y: 530), size: 12, color: .black, weight: .bold)
        draw("ArtShot X", at: CGPoint(x: 64, y: 414), size: 64, color: .white, weight: .bold)
        draw("Une image locale, prête à annoter.", at: CGPoint(x: 68, y: 364), size: 24, color: .lightGray)
        for (index, title) in ["01  Capturez", "02  Annotez", "03  Partagez"].enumerated() {
            let x = CGFloat(64 + index * 296)
            NSColor(calibratedRed: 0.14, green: 0.21, blue: 0.24, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 125, width: 280, height: 170), xRadius: 20, yRadius: 20).fill()
            draw(title, at: CGPoint(x: x + 22, y: 232), size: 22, color: .white, weight: .semibold)
            let lines = ["Un écran ou une zone.", "Une flèche, un rectangle.", "Copiez ou exportez en PNG."]
            draw(lines[index], at: CGPoint(x: x + 22, y: 174), size: 16, color: .lightGray)
        }
        draw("Choisissez Flèche ou Rectangle dans la barre d’outils, puis tracez sur l’image.", at: CGPoint(x: 64, y: 64), size: 17, color: .lightGray)
        image.unlockFocus()
        return image
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
}
