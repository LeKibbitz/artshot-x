import AppKit
import ArtShotCore

/// Captures settled frames while the user scrolls the selected document by hand.
@MainActor
final class ScrollingCaptureController {
    private enum Style {
        static let panelSize = CGSize(width: 280, height: 410)
        static let previewHeight: CGFloat = 220
        static let inset: CGFloat = 16
        static let gap: CGFloat = 10
        static let screenMargin: CGFloat = 12
    }

    private enum ScrollError: LocalizedError {
        case invalidImage
        case changedSize
        case cannotAlign
        case stillMoving
        case limitReached

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Impossible de préparer l’image de la capture défilante."
            case .changedSize: return "La taille de la zone a changé. Relancez la capture défilante."
            case .cannotAlign:
                return "Impossible d’assembler cette position sans perdre du contenu. Défilez par petits pas vers le bas. Sélectionnez le contenu sans pied fixe ni animation."
            case .stillMoving: return "Le contenu bouge encore. Arrêtez le défilement avant de terminer."
            case .limitReached: return "La capture défilante a atteint sa limite : 20 000 px de haut, 32 millions de pixels ou 200 étapes. Terminez une capture plus courte."
            }
        }
    }

    private struct Sample {
        let image: CGImage
        let logicalSize: CGSize
        let frame: ScrollFrame
    }

    private let captureService = CaptureService()
    private var panel: ScrollCapturePanel?
    private let previewView = ScrollingPreviewView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Préparation…")
    private let finishButton = NSButton(title: "Terminer", target: nil, action: nil)
    private var completion: ((Result<NSImage, Error>?) -> Void)?
    private var task: Task<Void, Never>?
    private var sessionID: UUID?
    private var screenObserver: NSObjectProtocol?
    private var accepted: Sample?
    private var lastSeen: Sample?
    private var strips: [CGImage] = []
    private var totalHeight = 0
    private var hasUnmatchedPosition = false
    private var finishing = false
    private var selectedScreen: NSScreen?
    private var selectedRegion = CGRect.zero

    /// `region` uses global AppKit points and a bottom-left origin.
    func begin(on screen: NSScreen, region: CGRect,
               completion: @escaping (Result<NSImage, Error>?) -> Void) {
        cancel()
        let id = UUID()
        sessionID = id
        self.completion = completion
        selectedScreen = screen
        selectedRegion = region
        showPanel(on: screen, avoiding: region)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let initial = try await self.captureSample(on: screen, region: region)
                guard self.sessionID == id else { return }
                self.accepted = initial
                self.lastSeen = initial
                self.strips = [initial.image]
                self.totalHeight = initial.image.height
                self.updatePreview()
                self.finishButton.isEnabled = true
                self.updateStatus()
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(400))
                    let sample = try await self.captureSample(on: screen, region: region)
                    guard self.sessionID == id, !self.finishing else { return }
                    if let last = self.lastSeen, ScrollStitcher.isStable(last.frame, sample.frame) {
                        try await self.record(sample, session: id)
                    }
                    self.lastSeen = sample
                }
            } catch is CancellationError {
                // Cancellation closes the session through cancel() or finish().
            } catch {
                if self.sessionID == id { self.complete(.failure(error)) }
            }
        }
    }

    func cancel() { complete(nil) }

    @objc private func cancelFromPanel() { cancel() }

    @objc private func finish() {
        guard !finishing, accepted != nil, let screen = selectedScreen, let id = sessionID else { return }
        finishing = true
        finishButton.isEnabled = false
        statusLabel.stringValue = "Vérification de la dernière position…"
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Always verify the current viewport: clicking Finish immediately
                // after scrolling must not silently omit the last movement.
                var preceding = try await self.captureSample(on: screen, region: self.selectedRegion)
                var stable: Sample?
                for _ in 0..<5 {
                    try await Task.sleep(for: .milliseconds(350))
                    let current = try await self.captureSample(on: screen, region: self.selectedRegion)
                    if ScrollStitcher.isStable(preceding.frame, current.frame) {
                        stable = current
                        break
                    }
                    preceding = current
                }
                guard self.sessionID == id else { return }
                guard let stable else { throw ScrollError.stillMoving }
                try await self.record(stable, session: id)
                guard self.sessionID == id else { return }
                guard !self.hasUnmatchedPosition else { throw ScrollError.cannotAlign }
                self.complete(.success(try self.render()))
            } catch is CancellationError {
            } catch {
                if self.sessionID == id { self.complete(.failure(error)) }
            }
        }
    }

    private func captureSample(on screen: NSScreen, region: CGRect) async throws -> Sample {
        let image = try await captureService.captureRegion(region, on: screen)
        try Task.checkCancellation()
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              cgImage.width >= 8, cgImage.height >= 48 else { throw ScrollError.invalidImage }
        guard cgImage.height <= 20_000, cgImage.width <= 32_000_000 / cgImage.height else {
            throw ScrollError.limitReached
        }
        let width = min(160, cgImage.width)
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ScrollError.invalidImage }
        return Sample(image: cgImage, logicalSize: image.size,
                      frame: ScrollFrame(width: width, height: height, pixels: pixels))
    }

    private func record(_ sample: Sample, session id: UUID) async throws {
        guard let previous = accepted else { return }
        guard previous.image.width == sample.image.width, previous.image.height == sample.image.height else {
            throw ScrollError.changedSize
        }
        let previousFrame = previous.frame
        let nextFrame = sample.frame
        let alignment = await Task.detached(priority: .userInitiated) {
            ScrollStitcher.align(previous: previousFrame, next: nextFrame)
        }.value
        try Task.checkCancellation()
        guard sessionID == id else { return }
        switch alignment {
        case .duplicate:
            hasUnmatchedPosition = false
            if !finishing { updateStatus() }
        case .unalignable:
            hasUnmatchedPosition = true
            if !finishing {
                statusLabel.stringValue = "Position non alignée. Revenez un peu en haut, puis défilez moins. Évitez les pieds fixes."
            }
        case .shifted(let pixels):
            let newHeight = totalHeight + pixels
            guard newHeight <= 20_000, sample.image.width <= 32_000_000 / newHeight,
                  strips.count < 200 else { throw ScrollError.limitReached }
            guard let cropped = sample.image.cropping(to: CGRect(x: 0, y: sample.image.height - pixels,
                                                                 width: sample.image.width, height: pixels)),
                  let stripContext = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                               bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ScrollError.invalidImage
            }
            // CGImage.cropping can retain the entire source bitmap. Copy each
            // strip so memory grows with output height, rather than frame count.
            stripContext.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
            guard let strip = stripContext.makeImage() else { throw ScrollError.invalidImage }
            strips.append(strip)
            totalHeight = newHeight
            accepted = sample
            hasUnmatchedPosition = false
            updatePreview()
            if !finishing { updateStatus() }
        }
    }

    private func render() throws -> NSImage {
        guard let sample = accepted,
              let context = CGContext(data: nil, width: sample.image.width, height: totalHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScrollError.invalidImage
        }
        var top = totalHeight
        context.interpolationQuality = .none
        for strip in strips {
            top -= strip.height
            context.draw(strip, in: CGRect(x: 0, y: top, width: strip.width, height: strip.height))
        }
        guard let output = context.makeImage() else { throw ScrollError.invalidImage }
        let scale = CGFloat(sample.image.width) / sample.logicalSize.width
        return NSImage(cgImage: output, size: CGSize(width: sample.logicalSize.width,
                                                    height: CGFloat(totalHeight) / scale))
    }

    private func updateStatus() {
        statusLabel.stringValue = "\(strips.count) position\(strips.count > 1 ? "s" : "") · \(totalHeight) px de haut. Pause après chaque petit défilement."
    }

    private func updatePreview() {
        guard let accepted else { previewView.reset(); return }
        previewView.update(strips: strips, sourceWidth: accepted.image.width, totalHeight: totalHeight)
    }

    private func complete(_ result: Result<NSImage, Error>?) {
        let callback = completion
        completion = nil
        sessionID = nil
        task?.cancel()
        task = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        previewView.reset()
        accepted = nil
        lastSeen = nil
        strips = []
        totalHeight = 0
        hasUnmatchedPosition = false
        finishing = false
        selectedScreen = nil
        callback?(result)
    }

    private func showPanel(on screen: NSScreen, avoiding region: CGRect) {
        let size = Style.panelSize
        let margin = Style.screenMargin
        let visible = screen.visibleFrame.insetBy(dx: margin, dy: margin)
        let candidates = [
            CGRect(x: region.minX - size.width - margin, y: region.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: region.maxX + margin, y: region.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: region.minX, y: region.minY - size.height - margin, width: size.width, height: size.height),
            CGRect(x: region.minX, y: region.maxY + margin, width: size.width, height: size.height)
        ]
        let fallback = CGRect(x: visible.minX, y: visible.minY,
                              width: size.width, height: size.height)
        let frame = candidates.first(where: { visible.contains($0) && !$0.intersects(region) }) ?? fallback
        let panel = ScrollCapturePanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        // Include the native title bar when keeping the floating preview on screen.
        panel.setFrameOrigin(CGPoint(x: max(visible.minX, min(visible.maxX - panel.frame.width, panel.frame.minX)),
                                     y: max(visible.minY, min(visible.maxY - panel.frame.height, panel.frame.minY))))
        panel.title = "Capture défilante"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        previewView.reset()
        let instruction = NSTextField(wrappingLabelWithString: "Dans l’app à capturer, défilez lentement vers le bas.")
        instruction.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Préparation de la première image…"
        finishButton.target = self
        finishButton.action = #selector(finish)
        finishButton.bezelStyle = .rounded
        finishButton.isEnabled = false
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelFromPanel))
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, finishButton])
        buttons.spacing = Style.gap
        let stack = NSStackView(views: [previewView, instruction, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Style.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = panel.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Style.inset),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Style.inset),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
                previewView.widthAnchor.constraint(equalTo: stack.widthAnchor),
                previewView.heightAnchor.constraint(equalToConstant: Style.previewHeight),
                instruction.widthAnchor.constraint(equalTo: stack.widthAnchor),
                statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }
}

@MainActor
private final class ScrollCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
