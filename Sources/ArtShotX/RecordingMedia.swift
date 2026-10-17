import AppKit
import AVFoundation
import QuartzCore
import CoreText

struct RecordingOptions: Codable {
    var camera = false
    var microphone = false
    var systemAudio = false
    var cursor = true
    var clicks = false
    var keys = false
    var cameraLayout: CameraLayout? = nil
}

struct RecordingEvent: Codable {
    var time: Double
    var x: Double?
    var y: Double?
    var label: String?
}

struct RecordingMetadata: Codable {
    var options: RecordingOptions
    var events: [RecordingEvent]
    var duration: Double
    var hasCamera: Bool
    var hasSystemAudio: Bool
    var hasMicrophone: Bool
    var warning: String? = nil

    static func sidecar(for url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent("metadata.json") }
    static func read(_ url: URL) -> RecordingMetadata? {
        guard let data = try? Data(contentsOf: sidecar(for: url)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct RecordingEdit {
    var camera = true
    var systemAudio = true
    var microphone = true
    var clicks = true
    var keys = true
    var start = 0.0
    var end = Double.greatestFiniteMagnitude
}

enum RecordingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum RecordingComposition {
    /// All captured inputs stay independent until an MP4 is exported.
    static func make(url: URL, edit: RecordingEdit) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audioSources = try await asset.loadTracks(withMediaType: .audio)
        var audios: [AVAssetTrack] = []
        for audio in audioSources where try await audio.load(.timeRange).duration > .zero { audios.append(audio) }
        guard let screen = videos.first else { throw RecordingFailure.message("Cette vidéo ne contient aucune image.") }
        let duration = try await asset.load(.duration).seconds
        let start = max(0, min(edit.start, duration))
        let end = min(duration, edit.end)
        guard end > start else { throw RecordingFailure.message("La fin doit suivre le début de la sélection.") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: end - start, preferredTimescale: 600))
        let composition = AVMutableComposition()
        let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try screenTrack.insertTimeRange(range, of: screen, at: .zero)
        let size = try await screen.load(.naturalSize)
        let metadata = RecordingMetadata.read(url)
        var cameraTrackID: CMPersistentTrackID?
        var cameraRange: CMTimeRange?
        if edit.camera, metadata?.hasCamera == true, videos.count > 1 {
            let source = videos[1]
            let sourceRange = try await source.load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(range, otherRange: sourceRange)
            if overlap.duration > .zero {
                let cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                let offset = overlap.start - range.start
                try cameraTrack.insertTimeRange(overlap, of: source, at: offset)
                cameraTrackID = cameraTrack.trackID
                cameraRange = CMTimeRange(start: offset, duration: overlap.duration)
            }
        }
        let instruction = CameraCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: range.duration), screenTrackID: screenTrack.trackID, cameraTrackID: cameraTrackID, cameraTimeRange: cameraRange, renderSize: size, layout: metadata?.options.cameraLayout)
        var index = 0
        if metadata?.hasSystemAudio == true {
            if edit.systemAudio, index < audios.count {
                try await insertAudio(audios[index], into: composition, range: range)
            }
            index += 1
        }
        if metadata?.hasMicrophone == true {
            if edit.microphone, index < audios.count { try await insertAudio(audios[index], into: composition, range: range) }
        } else if metadata == nil {
            for audio in audios { try await insertAudio(audio, into: composition, range: range) }
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.customVideoCompositorClass = CameraVideoCompositor.self
        videoComposition.instructions = [instruction]
        if let metadata, (edit.clicks || edit.keys), !metadata.events.isEmpty {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: size)
            let video = CALayer()
            video.frame = parent.bounds
            parent.addSublayer(video)
            for event in metadata.events where event.time + (event.label == nil ? 0.6 : 1.25) > start && event.time <= end {
                let layer: CALayer
                if let x = event.x, let y = event.y, edit.clicks {
                    let ring = CAShapeLayer()
                    ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 48, height: 48), transform: nil)
                    ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
                    ring.strokeColor = NSColor.systemYellow.cgColor
                    ring.lineWidth = 4
                    ring.frame = CGRect(x: x * size.width - 24, y: (1 - y) * size.height - 24, width: 48, height: 48)
                    layer = ring
                } else if let label = event.label, edit.keys {
                    let text = CALayer()
                    // CATextLayer may omit glyphs in AVFoundation's offline renderer.
                    // CoreText rasterization preserves the shortcut in the exported frames.
                    text.contents = shortcutImage(label)
                    text.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
                    text.cornerRadius = 12
                    text.frame = CGRect(x: (size.width - 260) / 2, y: 40, width: 260, height: 48)
                    text.contentsScale = 2
                    layer = text
                } else { continue }
                layer.opacity = 0
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.values = [0, 1, 1, 0]
                animation.keyTimes = [0, 0.08, 0.75, 1]
                animation.beginTime = AVCoreAnimationBeginTimeAtZero + event.time - start
                animation.duration = event.label == nil ? 0.6 : 1.25
                animation.isRemovedOnCompletion = false
                animation.fillMode = .both
                layer.add(animation, forKey: "visibility")
                parent.addSublayer(layer)
            }
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        }
        return (composition, videoComposition)
    }

    private static func shortcutImage(_ label: String) -> CGImage? {
        guard let context = CGContext(data: nil, width: 520, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 27, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textPosition = CGPoint(x: (260 - width) / 2, y: (48 - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private static func insertAudio(_ source: AVAssetTrack, into composition: AVMutableComposition, range: CMTimeRange) async throws {
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        // The audio device may have started after the first screen frame.
        let sourceRange = try await source.load(.timeRange)
        let overlap = CMTimeRangeGetIntersection(range, otherRange: sourceRange)
        if overlap.duration > .zero { try target.insertTimeRange(overlap, of: source, at: overlap.start - range.start) }
    }

    static func export(url: URL, edit: RecordingEdit, to destination: URL) async throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw RecordingFailure.message("Choisissez un autre fichier pour conserver l’original.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".artshot-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (composition, videoComposition) = try await make(url: url, edit: edit)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingFailure.message("Impossible de préparer l’export vidéo.")
        }
        exporter.videoComposition = videoComposition
        let audioTracks = composition.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            // Explicit mixing renders enabled sources into one portable AAC track.
            // Reserve headroom when the microphone and system audio overlap.
            let mix = AVMutableAudioMix()
            let gain: Float = audioTracks.count > 1 ? 0.5 : 1
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(gain, at: .zero)
                return parameters
            }
            exporter.audioMix = mix
        }
        exporter.outputFileType = .mp4
        exporter.outputURL = temporary
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? RecordingFailure.message("L’export vidéo a échoué.") }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }
}


enum RecordingShortcutLabel {
    /// Ordinary typed characters are never inspected; a command shortcut can use its layout-aware key label.
    static func make(_ event: NSEvent) -> String? {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let flags = event.modifierFlags
        var key = special[event.keyCode]
        if key == nil, flags.contains(.command), let character = event.charactersIgnoringModifiers,
           character.count == 1, character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0) }) {
            key = character.uppercased()
        }
        guard let key else { return nil }
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        return prefix + key
    }

}
