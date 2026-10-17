import AppKit

/// Marks the prepared area without intercepting input or becoming part of the capture.
@MainActor
final class CaptureTargetOutline {
    private var panel: NSPanel?

    func show(region: CGRect) {
        hide()
        let panel = CaptureOutlinePanel(contentRect: region, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.sharingType = .none
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: region.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        panel.contentView = view
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

@MainActor
private final class CaptureOutlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
