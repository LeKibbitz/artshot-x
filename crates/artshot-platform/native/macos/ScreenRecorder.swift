import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Capture callbacks and the writer are serialized on one queue. UI never touches writer state.
final class ScreenRecorder: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    var recordingDirectory: URL?
    var onCameraImage: ((CGImage) -> Void)?
    var excludedProcessID: Int32?
    var onFailure: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "ArtShotX.recording", qos: .userInitiated)
    private let context = CIContext()
    private var stream: SCStream?
    private var devices: AVCaptureSession?
    private var timer: DispatchSourceTimer?
    private var writer: AVAssetWriter?
    private var screenInput: AVAssetWriterInput?
    private var cameraInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var screenAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var screenImage: CVPixelBuffer?
    private var cameraImage: CVPixelBuffer?
    private var startTime: CMTime?
    private var lastTime: CMTime?
    private var timeline = RecordingTimeline()
    private var size = CGSize.zero
    private var events: [RecordingEvent] = []
    private var active = false
    private var failure: Error?
    private var cameraFrames = 0
    private var systemSamples = 0
    private var microphoneSamples = 0
    private var options = RecordingOptions()
    private(set) var url: URL?
    private(set) var completionWarning: String?

    @MainActor
    func start(displayID: CGDirectDisplayID, sourceRect: CGRect?, options: RecordingOptions, externalCamera: Bool = false) async throws {
        self.options = options
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingFailure.message("L’écran sélectionné n’est plus disponible.")
        }
        let applications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier || $0.processID == self.excludedProcessID }
        let filter = SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let logicalSize = sourceRect?.size ?? CGSize(width: display.width, height: display.height)
        let pixelScale = CGFloat(filter.pointPixelScale)
        let scale = min(pixelScale, 1920 / logicalSize.width)
        let width = max(2, Int(logicalSize.width * scale) / 2 * 2)
        let height = max(2, Int(logicalSize.height * scale) / 2 * 2)
        size = CGSize(width: width, height: height)
        configuration.width = width
        configuration.height = height
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = options.cursor
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        try prepareWriter(options: options)
        var deviceOptions = options
        if externalCamera { deviceOptions.camera = false }
        if deviceOptions.camera || deviceOptions.microphone { try prepareDevices(options: deviceOptions) }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        // Starting camera/audio hardware may block; keep it off the main thread.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.devices?.startRunning()
                if let devices = self.devices, !devices.isRunning {
                    continuation.resume(throwing: RecordingFailure.message("Impossible de démarrer la caméra ou le microphone."))
                } else { self.active = true; continuation.resume() }
            }
        }
        try await stream.startCapture()
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { [weak self] in self?.writeFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    private func prepareWriter(options: RecordingOptions) throws {
        let folder = (recordingDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArtShot X/Recordings", isDirectory: true)).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("capture.mov")
        self.url = url
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.writer = writer
        let (input, adaptor) = makeVideoInput(width: Int(size.width), height: Int(size.height))
        guard writer.canAdd(input) else { throw RecordingFailure.message("Le codec vidéo est indisponible.") }
        writer.add(input)
        screenInput = input
        screenAdaptor = adaptor
        if options.camera {
            let (input, adaptor) = makeVideoInput(width: 640, height: 480)
            guard writer.canAdd(input) else { throw RecordingFailure.message("Impossible d’ajouter la caméra.") }
            writer.add(input)
            cameraInput = input
            cameraAdaptor = adaptor
        }
        if options.systemAudio { systemInput = try makeAudioInput(writer: writer, channels: 2) }
        if options.microphone { micInput = try makeAudioInput(writer: writer, channels: 1) }
    }

    private func makeVideoInput(width: Int, height: Int) -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 5, AVVideoExpectedSourceFrameRateKey: 30]])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        return (input, adaptor)
    }

    private func makeAudioInput(writer: AVAssetWriter, channels: Int) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels * 96000])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingFailure.message("Impossible d’ajouter la piste audio.") }
        writer.add(input)
        return input
    }

    private func prepareDevices(options: RecordingOptions) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .medium
        if options.camera {
            guard let device = AVCaptureDevice.default(for: .video) else { throw RecordingFailure.message("Aucune caméra disponible.") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecordingFailure.message("La caméra est occupée.") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RecordingFailure.message("La sortie caméra est indisponible.") }
            session.addOutput(output)
        }
        if options.microphone {
            guard let device = AVCaptureDevice.default(for: .audio) else { throw RecordingFailure.message("Aucun microphone disponible.") }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecordingFailure.message("Le microphone est occupé.") }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RecordingFailure.message("La sortie microphone est indisponible.") }
            session.addOutput(output)
        }
        session.commitConfiguration()
        devices = session
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard active, sampleBuffer.isValid else { return }
        if type == .screen {
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
            screenImage = image
        } else if type == .audio { appendAudio(sampleBuffer, input: systemInput, system: true) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active else { return }
        if output is AVCaptureVideoDataOutput {
            cameraImage = CMSampleBufferGetImageBuffer(sampleBuffer)
            if let buffer = cameraImage, let handler = onCameraImage {
                let image = CIImage(cvPixelBuffer: buffer)
                if let cg = context.createCGImage(image, from: image.extent) { handler(cg) }
            }
        }
        else { appendAudio(sampleBuffer, input: micInput, system: false) }
    }

    func receiveCameraFrame(_ frame: CVPixelBuffer) {
        queue.async { self.cameraImage = frame }
    }

    func cameraFailed(_ error: Error) {
        queue.async { self.fail(error) }
    }

    @MainActor
    func setPaused(_ paused: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.timeline.setPaused(paused, at: CMClockGetTime(CMClockGetHostTimeClock()))
                continuation.resume()
            }
        }
    }

    @MainActor
    func elapsedDuration() async -> Double {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock()))) }
        }
    }

    private func appendAudio(_ buffer: CMSampleBuffer, input: AVAssetWriterInput?, system: Bool) {
        guard active, let writer, writer.status == .writing, startTime != nil, let input else { return }
        do {
            for part in try timeline.audioBuffers(from: buffer) {
                guard input.isReadyForMoreMediaData else { continue }
                if input.append(part) { if system { systemSamples += 1 } else { microphoneSamples += 1 } }
                else { fail(writer.error ?? RecordingFailure.message("Échec de l’écriture audio.")); return }
            }
        } catch { fail(error) }
    }

    private func writeFrame(at hostTime: CMTime? = nil) {
        guard active, !timeline.isPaused, let writer, let screenImage else { return }
        let hostTime = hostTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        if startTime == nil {
            guard writer.startWriting() else { fail(writer.error ?? RecordingFailure.message("Impossible de créer la vidéo.")); return }
            timeline.begin(at: hostTime)
            startTime = hostTime
            writer.startSession(atSourceTime: hostTime)
        }
        guard let now = timeline.presentationTime(for: hostTime) else { return }
        guard writer.status == .writing, let input = screenInput, input.isReadyForMoreMediaData, let adaptor = screenAdaptor else { return }
        guard let frame = rendered(screenImage, adaptor: adaptor, size: size), adaptor.append(frame, withPresentationTime: now) else {
            fail(writer.error ?? RecordingFailure.message("Échec de l’écriture vidéo.")); return
        }
        lastTime = now
        if let cameraInput, cameraInput.isReadyForMoreMediaData, let cameraAdaptor {
            // Black frames preserve the camera track's complete time range during device warmup.
            let image = cameraImage.map { CIImage(cvPixelBuffer: $0) } ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
            if let frame = rendered(image, adaptor: cameraAdaptor, size: CGSize(width: 640, height: 480)), cameraAdaptor.append(frame, withPresentationTime: now), cameraImage != nil { cameraFrames += 1 }
        }
    }

    private func rendered(_ pixel: CVPixelBuffer, adaptor: AVAssetWriterInputPixelBufferAdaptor, size: CGSize) -> CVPixelBuffer? {
        rendered(CIImage(cvPixelBuffer: pixel), adaptor: adaptor, size: size)
    }

    private func rendered(_ image: CIImage, adaptor: AVAssetWriterInputPixelBufferAdaptor, size: CGSize) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        let transformed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = transformed.transformed(by: CGAffineTransform(translationX: (size.width - transformed.extent.width) / 2, y: (size.height - transformed.extent.height) / 2))
        context.render(centered, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    func currentStatus() async -> (Bool, Double, String?) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning:(self.timeline.isPaused,self.timeline.elapsed(at:CMClockGetTime(CMClockGetHostTimeClock())),self.failure?.localizedDescription)) }
        }
    }

    func addEvent(x: Double? = nil, y: Double? = nil, label: String? = nil) {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { self.recordEvent(at: time, x: x, y: y, label: label) }
    }

    private func recordEvent(at time: CMTime, x: Double?, y: Double?, label: String?) {
        guard active, let start = startTime, let pts = timeline.presentationTime(for: time) else { return }
        events.append(RecordingEvent(time: (pts - start).seconds, x: x, y: y, label: label))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.fail(error) } }
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure?(error)
    }

    @MainActor
    func finish(cancel: Bool) async throws -> URL? {
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        stream = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.active = false
                self.timeline.stop(at: CMClockGetTime(CMClockGetHostTimeClock()))
                self.timer?.cancel()
                self.timer = nil
                self.devices?.stopRunning()
                self.devices = nil
                guard let writer = self.writer, let url = self.url else { continuation.resume(returning: nil); return }
                if cancel || self.startTime == nil || writer.status != .writing {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    if !cancel { continuation.resume(throwing: self.failure ?? stopError ?? RecordingFailure.message("Aucune image n’a été enregistrée.")) }
                    else { continuation.resume(returning: nil) }
                    return
                }
                let end = (self.lastTime ?? self.startTime!) + CMTime(value: 1, timescale: 30)
                writer.endSession(atSourceTime: end)
                for input in [self.screenInput, self.cameraInput, self.systemInput, self.micInput] { input?.markAsFinished() }
                var missing: [String] = []
                if self.options.camera && self.cameraFrames == 0 { missing.append("caméra") }
                if self.options.systemAudio && self.systemSamples == 0 { missing.append("son système") }
                if self.options.microphone && self.microphoneSamples == 0 { missing.append("microphone") }
                var warnings: [String] = []
                if !missing.isEmpty { warnings.append("Sources sans données : \(missing.joined(separator: ", ")). Vérifiez les périphériques et les autorisations macOS.") }
                if let interrupted = self.failure ?? stopError { warnings.append("Capture interrompue : \(interrupted.localizedDescription)") }
                let warning = warnings.isEmpty ? nil : "La vidéo de l’écran est conservée. " + warnings.joined(separator: " ")
                let metadata = RecordingMetadata(options: self.options, events: self.events, duration: (end - self.startTime!).seconds, hasCamera: self.cameraFrames > 0, hasSystemAudio: self.systemSamples > 0, hasMicrophone: self.microphoneSamples > 0, warning: warning)
                writer.finishWriting {
                    guard writer.status == .completed else {
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                        continuation.resume(throwing: writer.error ?? RecordingFailure.message("La finalisation vidéo a échoué.")); return
                    }
                    do {
                        try JSONEncoder().encode(metadata).write(to: RecordingMetadata.sidecar(for: url), options: .atomic)
                        self.completionWarning = warning
                    } catch {
                        // A finished MOV is valuable even when its optional project sidecar fails.
                        self.completionWarning = "La vidéo est conservée : \(url.path). Les options de montage n’ont pas pu être enregistrées : \(error.localizedDescription)"
                    }
                    continuation.resume(returning: url)
                }
            }
        }
    }
}
