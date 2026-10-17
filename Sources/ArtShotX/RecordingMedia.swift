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
    var duration: Double? = nil
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
    var systemAudioVolume = 1.0
    var microphoneVolume = 1.0
    var cuts: [RecordingCut] = []
}

struct RecordingCut: Equatable {
    var start: Double
    var end: Double
}

struct RecordingTimelineSegment {
    let sourceStart: Double
    let sourceEnd: Double
    let outputStart: Double
    var duration: Double { sourceEnd - sourceStart }
    var sourceRange: CMTimeRange { CMTimeRange(start: CMTime(seconds: sourceStart, preferredTimescale: 60000), duration: CMTime(seconds: duration, preferredTimescale: 60000)) }
}

struct RecordingEditTimeline {
    let segments: [RecordingTimelineSegment]
    let duration: Double
    init(duration sourceDuration: Double, edit: RecordingEdit) throws {
        let start = min(sourceDuration, max(0, edit.start.isFinite ? edit.start : 0))
        let end = min(sourceDuration, edit.end.isFinite ? edit.end : sourceDuration)
        guard end > start else { throw RecordingFailure.message("La fin doit suivre le début de la sélection.") }
        let cuts = edit.cuts.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .map { RecordingCut(start: max(start, $0.start), end: min(end, $0.end)) }
            .filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var cursor = start
        var output = 0.0
        var kept: [RecordingTimelineSegment] = []
        for cut in cuts {
            if cut.start > cursor {
                kept.append(RecordingTimelineSegment(sourceStart: cursor, sourceEnd: cut.start, outputStart: output))
                output += cut.start - cursor
            }
            cursor = max(cursor, cut.end)
        }
        if cursor < end {
            kept.append(RecordingTimelineSegment(sourceStart: cursor, sourceEnd: end, outputStart: output))
            output += end - cursor
        }
        guard output > 0 else { throw RecordingFailure.message("Conservez au moins un passage de la vidéo.") }
        segments = kept
        duration = output
    }
    func sourceTime(forOutputTime time: Double) -> Double {
        let time = max(0, min(duration, time))
        for segment in segments where time < segment.outputStart + segment.duration {
            return segment.sourceStart + max(0, time - segment.outputStart)
        }
        return segments.last!.sourceEnd
    }
    func outputTime(forSourceTime time: Double) -> Double? {
        for segment in segments where time >= segment.sourceStart && time < segment.sourceEnd {
            return segment.outputStart + time - segment.sourceStart
        }
        if time == segments.last?.sourceEnd { return duration }
        return nil
    }
}

struct RecordingCompositionResult {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let timeline: RecordingEditTimeline
    let events: [RecordingEvent]
}

enum RecordingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum RecordingComposition {
    /// All captured inputs stay independent until an MP4 is exported.
    static func make(url: URL, edit: RecordingEdit) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let result = try await prepare(url: url, edit: edit)
        return (result.composition, result.videoComposition)
    }

    static func prepare(url: URL, edit: RecordingEdit) async throws -> RecordingCompositionResult {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audioSources = try await asset.loadTracks(withMediaType: .audio)
        var audios: [AVAssetTrack] = []
        for audio in audioSources where try await audio.load(.timeRange).duration > .zero { audios.append(audio) }
        guard let screen = videos.first else { throw RecordingFailure.message("Cette vidéo ne contient aucune image.") }
        let duration = try await asset.load(.duration).seconds
        let timeline = try RecordingEditTimeline(duration: duration, edit: edit)
        let composition = AVMutableComposition()
        let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        for segment in timeline.segments { try screenTrack.insertTimeRange(segment.sourceRange, of: screen, at: CMTime(seconds: segment.outputStart, preferredTimescale: 60000)) }
        let size = try await screen.load(.naturalSize)
        let metadata = RecordingMetadata.read(url)
        var cameraTrackID: CMPersistentTrackID?
        var cameraRanges: [CMTimeRange] = []
        if edit.camera, metadata?.hasCamera == true, videos.count > 1 {
            let camera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            cameraRanges = try await insertSegments(videos[1], into: camera, timeline: timeline)
            if !cameraRanges.isEmpty { cameraTrackID = camera.trackID }
        }
        let screenRanges = try await mappedRanges(screen, timeline: timeline)
        let instruction = CameraCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: timeline.duration, preferredTimescale: 60000)), screenTrackID: screenTrack.trackID, cameraTrackID: cameraTrackID, cameraTimeRange: nil, screenTimeRanges: screenRanges, renderSize: size, layout: metadata?.options.cameraLayout, cameraTimeRanges: cameraRanges)
        let audioMix = AVMutableAudioMix()
        var parameters: [AVAudioMixInputParameters] = []
        var index = 0
        if metadata?.hasSystemAudio == true {
            if edit.systemAudio, index < audios.count { parameters += try await insertAudio(audios[index], into: composition, timeline: timeline, volume: edit.systemAudioVolume) }
            index += 1
        }
        if metadata?.hasMicrophone == true {
            if edit.microphone, index < audios.count { parameters += try await insertAudio(audios[index], into: composition, timeline: timeline, volume: edit.microphoneVolume) }
        } else if metadata == nil {
            for audio in audios where edit.systemAudio { parameters += try await insertAudio(audio, into: composition, timeline: timeline, volume: edit.systemAudioVolume) }
        }
        audioMix.inputParameters = parameters
        let events = (metadata?.events ?? []).compactMap { event -> RecordingEvent? in
            let lifetime = event.duration ?? (event.label == nil ? 0.6 : 1.25)
            guard let segment = timeline.segments.first(where: {
                (event.time >= $0.sourceStart && event.time < $0.sourceEnd) ||
                ($0.outputStart == 0 && event.time < $0.sourceStart && event.time + lifetime > $0.sourceStart && event.time >= 0 && !edit.cuts.contains(where: { event.time >= $0.start && event.time < $0.end }))
            }) else { return nil }
            var mapped = event
            mapped.time = segment.outputStart + max(0, event.time - segment.sourceStart)
            mapped.duration = min(event.time + lifetime, segment.sourceEnd) - max(event.time, segment.sourceStart)
            return mapped
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.customVideoCompositorClass = CameraVideoCompositor.self
        videoComposition.instructions = [instruction]
        if (edit.clicks || edit.keys), !events.isEmpty {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: size)
            let video = CALayer()
            video.frame = parent.bounds
            parent.addSublayer(video)
            for event in events {
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
                animation.beginTime = AVCoreAnimationBeginTimeAtZero + event.time
                animation.duration = event.duration ?? (event.label == nil ? 0.6 : 1.25)
                animation.isRemovedOnCompletion = false
                animation.fillMode = .both
                layer.add(animation, forKey: "visibility")
                parent.addSublayer(layer)
            }
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        }
        return RecordingCompositionResult(composition: composition, videoComposition: videoComposition, audioMix: audioMix, timeline: timeline, events: events)
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

    private static func mappedRanges(_ source: AVAssetTrack, timeline: RecordingEditTimeline) async throws -> [CMTimeRange] {
        let segments = try await source.load(.segments)
        let ranges = segments.isEmpty ? [try await source.load(.timeRange)] : segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
        return timeline.segments.flatMap { kept in ranges.compactMap { range in
            let overlap = CMTimeRangeGetIntersection(kept.sourceRange, otherRange: range)
            guard overlap.duration > .zero else { return nil }
            return CMTimeRange(start: CMTime(seconds: kept.outputStart, preferredTimescale: 60000) + overlap.start - kept.sourceRange.start, duration: overlap.duration)
        } }
    }

    private static func insertSegments(_ source: AVAssetTrack, into target: AVMutableCompositionTrack, timeline: RecordingEditTimeline) async throws -> [CMTimeRange] {
        let sourceRange = try await source.load(.timeRange)
        for kept in timeline.segments {
            let overlap = CMTimeRangeGetIntersection(kept.sourceRange, otherRange: sourceRange)
            if overlap.duration > .zero { try target.insertTimeRange(overlap, of: source, at: CMTime(seconds: kept.outputStart, preferredTimescale: 60000) + overlap.start - kept.sourceRange.start) }
        }
        return try await mappedRanges(source, timeline: timeline)
    }

    private static func insertAudio(_ source: AVAssetTrack, into composition: AVMutableComposition, timeline: RecordingEditTimeline, volume: Double) async throws -> [AVAudioMixInputParameters] {
        let gain = volume.isFinite ? min(2, max(0, volume)) : 1
        // AVAudioMix accepts only 0...1 per track. Identical synchronized tracks
        // sum linearly, providing genuine amplification through 200%.
        var remaining = gain
        var parameters: [AVAudioMixInputParameters] = []
        while remaining > 0 {
            let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            _ = try await insertSegments(source, into: target, timeline: timeline)
            let input = AVMutableAudioMixInputParameters(track: target)
            input.setVolume(Float(min(1, remaining)), at: .zero)
            parameters.append(input)
            remaining -= min(1, remaining)
        }
        return parameters
    }

    static func export(url: URL, edit: RecordingEdit, to destination: URL) async throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw RecordingFailure.message("Choisissez un autre fichier pour conserver l’original.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".artshot-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let prepared = try await prepare(url: url, edit: edit)
        let composition = prepared.composition
        let videoComposition = prepared.videoComposition
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingFailure.message("Impossible de préparer l’export vidéo.")
        }
        exporter.videoComposition = videoComposition
        exporter.audioMix = prepared.audioMix
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
