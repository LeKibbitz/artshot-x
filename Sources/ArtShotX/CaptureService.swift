import AppKit
import ArtShotCore
import ScreenCaptureKit

@MainActor
final class CaptureService {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case displayUnavailable
        case invalidRegion
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Autorisez ArtShot X dans Réglages Système → Confidentialité et sécurité → Enregistrement de l’écran, puis relancez l’app si macOS le demande."
            case .displayUnavailable:
                return "Cet écran n’est plus disponible. Relancez la capture sur un écran connecté."
            case .invalidRegion:
                return "La zone doit contenir au moins un pixel sur l’écran sélectionné."
            case .failed(let detail):
                return "La capture a échoué : \(detail)"
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Only call from an explicit user action. macOS owns the permission prompt.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func captureDisplay(_ screen: NSScreen) async throws -> NSImage {
        try await captureRegion(screen.frame, on: screen)
    }

    /// `rect` is in AppKit global points (bottom-left), clipped to `screen`.
    /// The returned image keeps logical size in points and native Retina pixels.
    func captureRegion(_ rect: CGRect, on screen: NSScreen) async throws -> NSImage {
        guard Self.hasPermission else { throw CaptureError.permissionDenied }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayUnavailable
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard NSScreen.screens.contains(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw CaptureError.displayUnavailable }
        try Task.checkCancellation()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayUnavailable
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownApplications = content.applications.filter { $0.processID == ownPID }
            let filter: SCContentFilter
            if ownApplications.isEmpty {
                // The process may not yet appear in the application list during startup.
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            } else {
                filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            }
            let scale = CGFloat(filter.pointPixelScale)
            guard let source = CaptureGeometry.pixelAlignedSourceRect(for: rect, screenFrame: screen.frame, scale: scale),
                  let pixels = CaptureGeometry.pixelSize(for: source.size, scale: scale),
                  pixels.width < CGFloat(Int.max), pixels.height < CGFloat(Int.max) else {
                throw CaptureError.invalidRegion
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = source
            configuration.width = Int(pixels.width)
            configuration.height = Int(pixels.height)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            try Task.checkCancellation()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            return NSImage(cgImage: image, size: source.size)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaptureError {
            throw error
        } catch {
            if !Self.hasPermission { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error.localizedDescription)
        }
    }
}
