import AppKit
import AVFoundation

@main
struct RecordingSmokeTest {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artshot-recording-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("capture.mov")
        let writer = try AVAssetWriter(outputURL: raw, fileType: .mov)
        func video(_ width: Int, _ height: Int) -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            return (input, AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]))
        }
        let (screenInput, screen) = video(320, 240)
        let (cameraInput, camera) = video(64, 48)
        let system = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        system.expectsMediaDataInRealTime = true
        mic.expectsMediaDataInRealTime = true
        writer.add(system)
        writer.add(mic)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        func frame(_ pool: CVPixelBufferPool, blue: Bool) -> CVPixelBuffer {
            var output: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
            let buffer = output!
            CVPixelBufferLockBaseAddress(buffer, [])
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<CVPixelBufferGetHeight(buffer) {
                for x in 0..<CVPixelBufferGetWidth(buffer) {
                    let p = y * stride + x * 4
                    pixels[p] = blue ? 240 : 15
                    pixels[p+1] = 15
                    pixels[p+2] = blue ? 15 : 240
                    pixels[p+3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
        let red = frame(screen.pixelBufferPool!, blue: false)
        let blue = frame(camera.pixelBufferPool!, blue: true)
        for index in 0..<60 {
            let deadline = Date().addingTimeInterval(5)
            while !screenInput.isReadyForMoreMediaData || !cameraInput.isReadyForMoreMediaData || !system.isReadyForMoreMediaData || !mic.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }
                if Date() > deadline { throw RecordingFailure.message("Synthetic writer stalled at frame \(index): \(screenInput.isReadyForMoreMediaData), \(cameraInput.isReadyForMoreMediaData), \(system.isReadyForMoreMediaData), \(mic.isReadyForMoreMediaData)") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let time = CMTime(value: Int64(index), timescale: 30)
            guard screen.append(red, withPresentationTime: time) else { throw writer.error! }
            if index >= 6 && index < 54 { guard camera.append(blue, withPresentationTime: time) else { throw writer.error! } }
            let audio = try audioBuffer(time: time)
            guard system.append(audio), mic.append(audio) else { throw writer.error! }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        for input in [screenInput, cameraInput, system, mic] { input.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        var options = RecordingOptions()
        options.camera = true; options.systemAudio = true; options.microphone = true; options.clicks = true; options.keys = true
        let metadata = RecordingMetadata(options: options, events: [RecordingEvent(time: 0.2, x: 0.5, y: 0.5), RecordingEvent(time: 0.3, label: "⌘C")], duration: 2, hasCamera: true, hasSystemAudio: true, hasMicrophone: true)
        try JSONEncoder().encode(metadata).write(to: RecordingMetadata.sidecar(for: raw))
        let source = AVURLAsset(url: raw)
        let sourceVideos = try await source.loadTracks(withMediaType: .video)
        let sourceAudios = try await source.loadTracks(withMediaType: .audio)
        precondition(sourceVideos.count == 2, "Camera must be a separate track")
        precondition(sourceAudios.count == 2, "Audio sources must be separate")
        var edit = RecordingEdit()
        edit.start = 0.1; edit.end = 1.1
        let (all, _) = try await RecordingComposition.make(url: raw, edit: edit)
        precondition(all.tracks(withMediaType: .audio).count == 2)
        let withCamera = folder.appendingPathComponent("camera.mp4")
        try await RecordingComposition.export(url: raw, edit: edit, to: withCamera)
        edit.camera = false; edit.systemAudio = false; edit.microphone = false; edit.clicks = false; edit.keys = false
        let (plain, _) = try await RecordingComposition.make(url: raw, edit: edit)
        precondition(plain.tracks(withMediaType: .audio).isEmpty)
        let withoutCamera = folder.appendingPathComponent("plain.mp4")
        try await RecordingComposition.export(url: raw, edit: edit, to: withoutCamera)
        for url in [withCamera, withoutCamera] {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            precondition(abs(duration - 1) < 0.06, "Trim should export one second")
            let videos = try await asset.loadTracks(withMediaType: .video)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            precondition(videos.count == 1)
            precondition((attributes[.size] as! NSNumber).intValue > 1000)
        }
        // Existing save targets must be replaced only after a complete export.
        try await RecordingComposition.export(url: raw, edit: edit, to: withoutCamera)
        let earlyCameraBlue = try await bluePixelCount(withCamera, at: 0.01)
        precondition(earlyCameraBlue < 100, "Late camera start must remain transparent")
        let cameraBlue = try await bluePixelCount(withCamera)
        let plainBlue = try await bluePixelCount(withoutCamera)
        precondition(cameraBlue > 500, "Export must contain the camera overlay")
        precondition(plainBlue < 100, "Camera toggle must remove camera pixels")
        let effectCounts = try await effectPixelCounts(withCamera)
        let plainCounts = try await effectPixelCounts(withoutCamera)
        precondition(effectCounts.yellow > 20 && plainCounts.yellow < 10, "Click ring must render only when enabled")
        precondition(effectCounts.white > 20 && plainCounts.white < 10, "Shortcut text must render only when enabled")
        let originalData = try Data(contentsOf: raw)
        let savedData = try Data(contentsOf: withoutCamera)
        var invalid = edit
        invalid.end = invalid.start
        do {
            try await RecordingComposition.export(url: raw, edit: invalid, to: withoutCamera)
            preconditionFailure("An invalid trim must fail")
        } catch { }
        let afterFailure = try Data(contentsOf: withoutCamera)
        precondition(afterFailure == savedData, "A failed export must preserve the existing destination")
        do {
            try await RecordingComposition.export(url: raw, edit: edit, to: raw)
            preconditionFailure("Export must never overwrite the original")
        } catch { }
        let afterOriginalAttempt = try Data(contentsOf: raw)
        precondition(originalData == afterOriginalAttempt, "The original must be preserved byte for byte")
        var tailEdit = edit
        tailEdit.camera = true
        tailEdit.start = 1.7
        tailEdit.end = 1.95
        let tail = folder.appendingPathComponent("camera-tail.mp4")
        try await RecordingComposition.export(url: raw, edit: tailEdit, to: tail)
        let tailBeginningBlue = try await bluePixelCount(tail, at: 0.01)
        let tailEndBlue = try await bluePixelCount(tail, at: 0.20)
        precondition(tailBeginningBlue > 500 && tailEndBlue < 100, "Early camera end must become transparent")
        let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "password", charactersIgnoringModifiers: "password", isARepeat: false, keyCode: 0)!
        precondition(RecordingShortcutLabel.make(typed) == nil, "Typed text must never be captured")
        let azerty = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 12)!
        precondition(RecordingShortcutLabel.make(azerty) == "⌘A", "Shortcut label must honor keyboard layout")
        for blockedSidecar in [false, true] {
            let interruptionFolder = folder.appendingPathComponent(blockedSidecar ? "blocked-sidecar" : "interrupted-stream")
            try FileManager.default.createDirectory(at: interruptionFolder, withIntermediateDirectories: true)
            let interruptedURL = interruptionFolder.appendingPathComponent("capture.mov")
            if blockedSidecar { try FileManager.default.createDirectory(at: RecordingMetadata.sidecar(for: interruptedURL), withIntermediateDirectories: true) }
            let (result, warning) = try await ScreenRecorder.testInterruptedFinalization(at: interruptedURL)
            precondition(result == interruptedURL && warning != nil, "An interrupted stream must return its preserved movie and a warning")
            let interruptedAsset = AVURLAsset(url: interruptedURL)
            let interruptedDuration = try await interruptedAsset.load(.duration).seconds
            precondition(interruptedDuration > 0.4, "Real finalization must preserve readable recorded frames")
            if blockedSidecar { precondition(warning!.contains(interruptedURL.path), "Failed sidecar warning must identify the preserved movie") }
            else { precondition(RecordingMetadata.read(interruptedURL)?.warning != nil, "Stream interruption must be saved as a warning") }
        }
        print("PASS: separate camera/audio tracks, camera timing, editable effects, atomic MP4 replacement, trim, AZERTY labels; interrupted-stream and failed-sidecar MOV preservation")
    }

    static func audioBuffer(time: CMTime) throws -> CMSampleBuffer {
        let count = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block)
        let bytes = [UInt8](repeating: 0, count: count * 2)
        bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count, presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer!
    }

    static func bluePixelCount(_ url: URL, at time: Double = 0.5) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.blueComponent > 0.6, color.redComponent < 0.3 { count += 1 }
            }
        }
        return count
    }
    static func effectPixelCounts(_ url: URL) async throws -> (yellow: Int, white: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var yellow = 0
        var white = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.6 && color.greenComponent > 0.5 && color.blueComponent < 0.4 { yellow += 1 }
                if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8 { white += 1 }
            }
        }
        return (yellow, white)
    }

}
