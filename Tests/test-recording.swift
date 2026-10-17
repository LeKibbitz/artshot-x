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
            let systemTone = try audioBuffer(time: time, frequency: 440)
            let microphoneTone = try audioBuffer(time: time, frequency: 880)
            guard system.append(systemTone), mic.append(microphoneTone) else { throw writer.error! }
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
        let mixedTracks = try await AVURLAsset(url: withCamera).loadTracks(withMediaType: .audio)
        let silentTracks = try await AVURLAsset(url: withoutCamera).loadTracks(withMediaType: .audio)
        precondition(mixedTracks.count == 1, "Two enabled sources must export as one portable AAC track")
        let mixedFormats = try await mixedTracks[0].load(.formatDescriptions)
        precondition(mixedFormats.allSatisfy { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }, "The portable mixed audio track must be AAC")
        precondition(silentTracks.isEmpty, "Disabling both sources must remove audio")
        let mixedTones = try await toneAmplitudes(withCamera)
        precondition(mixedTones.system > 0.06 && mixedTones.microphone > 0.06, "The exported AAC track must contain both source tones")
        for enableSystem in [true, false] {
            var single = edit
            single.systemAudio = enableSystem
            single.microphone = !enableSystem
            let target = folder.appendingPathComponent(enableSystem ? "system-only.mp4" : "mic-only.mp4")
            try await RecordingComposition.export(url: raw, edit: single, to: target)
            let tracks = try await AVURLAsset(url: target).loadTracks(withMediaType: .audio)
            precondition(tracks.count == 1, "A single enabled source must export one AAC track")
            let tones = try await toneAmplitudes(target)
            let enabled = enableSystem ? tones.system : tones.microphone
            let disabled = enableSystem ? tones.microphone : tones.system
            precondition(enabled > 0.15 && disabled < 0.015, "Source toggles must retain only the selected tone")
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
        print("PASS: separate original tracks; one AAC track with both tones (440 Hz: \(String(format: "%.3f", mixedTones.system)), 880 Hz: \(String(format: "%.3f", mixedTones.microphone))); source toggles; camera timing; effects; atomic MP4; trim; AZERTY; interrupted-stream/sidecar preservation")
    }

    static func audioBuffer(time: CMTime, frequency: Double) throws -> CMSampleBuffer {
        let count = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block)
        let samples: [Int16] = (0..<count).map { index in
            Int16(sin(2 * Double.pi * frequency * (time.seconds + Double(index) / 48000)) * 8192)
        }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count, presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer!
    }

    static func toneAmplitudes(_ url: URL) async throws -> (system: Double, microphone: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw RecordingFailure.message("Test export has no audio") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var samples: [Float] = []
        var rate = 48000.0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer), let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { continue }
            rate = description.pointee.mSampleRate
            let channels = Int(description.pointee.mChannelsPerFrame)
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw RecordingFailure.message("Cannot decode test audio") }
            for index in stride(from: 0, to: values.count, by: channels) { samples.append(values[index]) }
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingFailure.message("Audio test decoding failed") }
        func amplitude(_ frequency: Double) -> Double {
            var real = 0.0
            var imaginary = 0.0
            for (index, sample) in samples.enumerated() {
                let phase = 2 * Double.pi * frequency * Double(index) / rate
                real += Double(sample) * cos(phase)
                imaginary += Double(sample) * sin(phase)
            }
            return 2 * hypot(real, imaginary) / Double(samples.count)
        }
        return (amplitude(440), amplitude(880))
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
