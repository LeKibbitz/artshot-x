import AVFoundation
import CoreImage

/// One camera session supplies both the visible preview and the original camera track.
/// Hardware work and frame delivery are serialized; preview updates are coalesced.
final class LiveCameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let hardwareQueue = DispatchQueue(label: "ArtShotX.liveCamera", qos: .userInitiated)
    private let context = CIContext()
    private let onImage: @MainActor (CGImage) -> Void
    private let onFailure: @MainActor (Error) -> Void
    private var session: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []
    private var latestFrame: CVPixelBuffer?
    private var bufferHandler: ((CVPixelBuffer) -> Void)?
    private var previewPending = false
    private var lastPreviewTime = -Double.infinity
    private var running = false

    init(onImage: @escaping @MainActor (CGImage) -> Void, onFailure: @escaping @MainActor (Error) -> Void) {
        self.onImage = onImage
        self.onFailure = onFailure
        super.init()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.hardwareQueue.async {
                do {
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    session.sessionPreset = .vga640x480
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        throw RecordingFailure.message("Aucune caméra disponible.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw RecordingFailure.message("La caméra est occupée.") }
                    session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: Self.hardwareQueue)
                    guard session.canAddOutput(output) else { throw RecordingFailure.message("La sortie caméra est indisponible.") }
                    session.addOutput(output)
                    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                    session.commitConfiguration()
                    self.session = session
                    self.observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                        guard let self else { return }
                        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error ?? RecordingFailure.message("La caméra a été interrompue.")
                        Self.hardwareQueue.async { self.report(error) }
                    })
                    self.observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
                        guard let self else { return }
                        Self.hardwareQueue.async { self.report(RecordingFailure.message("La caméra a été interrompue. Relancez-la avant le prochain enregistrement.")) }
                    })
                    session.startRunning()
                    guard session.isRunning else { throw RecordingFailure.message("Impossible de démarrer la caméra.") }
                    self.running = true
                    Self.hardwareQueue.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard let self, self.running, self.latestFrame == nil else { return }
                        self.report(RecordingFailure.message("La caméra ne fournit aucune image. Vérifiez son autorisation dans Réglages Système."))
                    }
                    continuation.resume()
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setBufferHandler(_ handler: ((CVPixelBuffer) -> Void)?) async {
        await withCheckedContinuation { continuation in
            Self.hardwareQueue.async {
                self.bufferHandler = handler
                if let frame = self.latestFrame { handler?(frame) }
                continuation.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            Self.hardwareQueue.async {
                self.stopOnQueue()
                continuation.resume()
            }
        }
    }

    private func stopOnQueue() {
        running = false
        bufferHandler = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        session?.stopRunning()
        session = nil
        latestFrame = nil
    }

    private func report(_ error: Error) {
        guard running else { return }
        DispatchQueue.main.async { self.onFailure(error) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestFrame = frame
        bufferHandler?(frame)
        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard !previewPending, now - lastPreviewTime >= 1.0 / 15 else { return }
        let image = CIImage(cvPixelBuffer: frame)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        lastPreviewTime = now
        previewPending = true
        DispatchQueue.main.async {
            self.onImage(cgImage)
            Self.hardwareQueue.async { self.previewPending = false }
        }
    }
}
