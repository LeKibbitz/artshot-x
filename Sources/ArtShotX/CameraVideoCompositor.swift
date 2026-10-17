import AVFoundation
import CoreImage

final class CameraCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let screenTimeRanges: [CMTimeRange]
    let cameraTrackID: CMPersistentTrackID?
    let cameraTimeRange: CMTimeRange?
    let cameraFrame: CGRect
    let renderSize: CGSize
    let mask: CIImage?

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, cameraTimeRange: CMTimeRange?, screenTimeRanges: [CMTimeRange], renderSize: CGSize, layout: CameraLayout?) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.screenTimeRanges = screenTimeRanges
        self.cameraTrackID = cameraTrackID
        self.cameraTimeRange = cameraTimeRange
        self.renderSize = renderSize
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
        let frame: CGRect
        if let layout {
            let topLeft = layout.frame(in: renderSize)
            frame = CGRect(x: topLeft.minX, y: renderSize.height - topLeft.maxY, width: topLeft.width, height: topLeft.height)
        } else {
            // Preserve the legacy rectangular bottom-right overlay and its 400 px cap.
            let width = min(renderSize.width * 0.23, 400)
            frame = CGRect(x: renderSize.width - width - 28, y: 28, width: width, height: width * 0.75)
        }
        cameraFrame = frame
        mask = Self.makeMask(shape: layout?.shape, frame: frame, renderSize: renderSize)
        super.init()
    }

    private static func makeMask(shape: CameraShape?, frame: CGRect, renderSize: CGSize) -> CIImage? {
        guard let shape, shape != .square else { return nil }
        let width = max(1, Int(ceil(frame.width)))
        let height = max(1, Int(ceil(frame.height)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / frame.width, y: CGFloat(height) / frame.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let local = CGRect(origin: .zero, size: frame.size)
        if shape == .circle { context.fillEllipse(in: local) }
        else {
            let radius = min(frame.width, frame.height) * 0.16
            context.addPath(CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        let mask = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: frame.width / CGFloat(width), y: frame.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
        return mask.composited(over: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: renderSize)))
    }
}

/// One renderer is used for AVPlayer playback and exported frames, including transparent corners.
final class CameraVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    private let queue = DispatchQueue(label: "ArtShotX.camera-compositor", qos: .userInitiated)
    private let context = CIContext()
    private let lock = NSLock()
    private var generation = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let token = generation
        lock.unlock()
        queue.async {
            self.lock.lock()
            let cancelled = token != self.generation
            self.lock.unlock()
            guard !cancelled else { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? CameraCompositionInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: RecordingFailure.message("Impossible de composer l’image vidéo.")); return
            }
            let bounds = CGRect(origin: .zero, size: instruction.renderSize)
            var image: CIImage
            if !instruction.screenTimeRanges.contains(where: { CMTimeRangeContainsTime($0, time: request.compositionTime) }) {
                // Capture devices can start late or audio can outlast the screen track.
                // Deterministic padding preserves audio, trim and event timestamps.
                image = CIImage(color: .black).cropped(to: bounds)
            } else if let screen = request.sourceFrame(byTrackID: instruction.screenTrackID) {
                image = CIImage(cvPixelBuffer: screen)
                image = image.transformed(by: CGAffineTransform(scaleX: bounds.width / image.extent.width, y: bounds.height / image.extent.height)).cropped(to: bounds)
            } else {
                request.finish(with: RecordingFailure.message("Une image écran attendue est indisponible.")); return
            }
            if let id = instruction.cameraTrackID, let range = instruction.cameraTimeRange,
               CMTimeRangeContainsTime(range, time: request.compositionTime), let camera = request.sourceFrame(byTrackID: id) {
                var overlay = CIImage(cvPixelBuffer: camera)
                let frame = instruction.cameraFrame
                let scale = max(frame.width / overlay.extent.width, frame.height / overlay.extent.height)
                overlay = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                overlay = overlay.transformed(by: CGAffineTransform(translationX: frame.midX - overlay.extent.midX, y: frame.midY - overlay.extent.midY)).cropped(to: frame)
                if let mask = instruction.mask {
                    image = overlay.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]).cropped(to: bounds)
                } else { image = overlay.composited(over: image).cropped(to: bounds) }
            }
            self.context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }
}
