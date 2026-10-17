import AppKit
import AVFoundation
@main struct RecordingEditChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artshot-edit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("capture.mov")
        let writer = try AVAssetWriter(outputURL: raw, fileType: .mov)
        func video(_ width: Int, _ height: Int) -> (AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAllowFrameReorderingKey: false]])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            return (input, AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]))
        }
        let system = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        system.expectsMediaDataInRealTime = true
        mic.expectsMediaDataInRealTime = true
        // Put audio first so the movie duration can exceed both video tracks.
        writer.add(system)
        let (screenInput, screen) = video(320, 240)
        let (cameraInput, camera) = video(64, 48)
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
                    if blue && (x < 6 || x >= CVPixelBufferGetWidth(buffer) - 6) {
                        pixels[p] = 15
                        pixels[p+1] = 240
                        pixels[p+2] = x < 6 ? 15 : 240
                    } else if blue && (6..<12).contains(y) {
                        // A horizontal cyan stripe is visible at 1× and cropped out at 2×.
                        pixels[p+1] = 240
                    }
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
            if index >= 3 && index < 57 { guard screen.append(red, withPresentationTime: time) else { throw writer.error! } }
            if index >= 6 && index < 54 { guard camera.append(blue, withPresentationTime: time) else { throw writer.error! } }
            let systemTone = try audioBuffer(time: time, frequency: index >= 18 && index < 42 ? 2200 : 440)
            let microphoneTone = try audioBuffer(time: time, frequency: index >= 18 && index < 42 ? 2600 : 880)
            guard system.append(systemTone), mic.append(microphoneTone) else { throw writer.error! }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        for input in [screenInput, cameraInput, system, mic] { input.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        var options = RecordingOptions()
        options.camera = true; options.systemAudio = true; options.microphone = true; options.clicks = true; options.keys = true
        let metadata = RecordingMetadata(options: options, events: [RecordingEvent(time: 0.2, x: 0.5, y: 0.5), RecordingEvent(time: 0.8, label: "REMOVED"), RecordingEvent(time: 1.5, label: "⌘C")], duration: 2, hasCamera: true, hasSystemAudio: true, hasMicrophone: true)
        try JSONEncoder().encode(metadata).write(to: RecordingMetadata.sidecar(for: raw))

        var separate = RecordingEdit()
        separate.start = 0.1; separate.end = 1.9
        separate.cuts = [RecordingCut(start: 1.2, end: 1.4), RecordingCut(start: -2, end: 0.2), RecordingCut(start: 0.6, end: 0.8), RecordingCut(start: 0.9, end: 0.85)]
        let separateTimeline = try RecordingEditTimeline(duration: 2, edit: separate)
        precondition(separateTimeline.segments.count == 3 && abs(separateTimeline.duration - 1.3) < 0.00001)
        precondition(abs(separateTimeline.sourceTime(forOutputTime: 0.4) - 0.8) < 0.00001)
        precondition(abs(separateTimeline.outputTime(forSourceTime: 1.5)! - 0.9) < 0.00001)
        separate.cuts = [RecordingCut(start: 0, end: 2)]
        do {
            _ = try RecordingEditTimeline(duration: 2, edit: separate)
            preconditionFailure("Removing the entire source must fail")
        } catch RecordingFailure.message { }
        let original = try Data(contentsOf: raw)
        var edit = RecordingEdit()
        edit.clicks = false; edit.keys = false
        edit.cuts = [RecordingCut(start: 0.6, end: 1.0), RecordingCut(start: 0.9, end: 1.4)]
        let prepared = try await RecordingComposition.prepare(url: raw, edit: edit)
        precondition(abs(prepared.timeline.duration - 1.2) < 0.00001)
        precondition(prepared.timeline.segments.count == 2)
        precondition(prepared.timeline.outputTime(forSourceTime: 0.8) == nil)
        precondition(abs(prepared.timeline.sourceTime(forOutputTime: 0.6) - 1.4) < 0.00001)
        precondition(prepared.events.count == 2 && abs(prepared.events[1].time - 0.7) < 0.00001)
        precondition(abs(prepared.events[0].duration! - 0.4) < 0.00001)
        let instruction = prepared.videoComposition.instructions[0] as! CameraCompositionInstruction
        precondition(instruction.cameraTimeRanges.count == 2)
        precondition(abs(instruction.cameraTimeRanges[0].start.seconds - 0.2) < 0.04)
        precondition(abs(CMTimeRangeGetEnd(instruction.cameraTimeRanges[1]).seconds - 1.0) < 0.04)
        var results: [(Double, Double)] = []
        for (name, systemGain, microphoneGain) in [("one", 1.0, 0.0), ("two", 2.0, 0.0), ("mic", 0.0, 1.0), ("both", 0.5, 2.0), ("mute", 0.0, 0.0)] {
            edit.systemAudioVolume = systemGain; edit.microphoneVolume = microphoneGain
            let destination = folder.appendingPathComponent(name + ".mp4")
            try await RecordingComposition.export(url: raw, edit: edit, to: destination)
            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            precondition(abs(duration - 1.2) < 0.05, "\(name) duration \(duration)")
            if name == "mute" {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                precondition(tracks.isEmpty)
            } else {
                let values = try await toneAmplitudes(destination)
                results.append((values.system, values.microphone))
                precondition(values.removed < max(values.system, values.microphone) * 0.03, "Cut-only tones must disappear")
            }
            if name == "one" {
                let before = try await bluePixelCount(destination, at: 0.05)
                let during = try await bluePixelCount(destination, at: 0.4)
                let after = try await bluePixelCount(destination, at: 1.1)
                precondition(before < 100 && during > 500 && after < 100)
            }
        }
        print("Decoded amplitudes (system, microphone): \(results)")
        precondition(results[0].0 > 0.01 && results[0].1 < results[0].0 * 0.04)
        precondition(abs(results[1].0 / results[0].0 - 2) < 0.12, "200% must decode at twice the amplitude")
        precondition(results[2].0 < results[2].1 * 0.04 && results[2].1 > 0.01)
        precondition(abs(results[3].0 / results[0].0 - 0.5) < 0.08)
        precondition(abs(results[3].1 / results[2].1 - 2) < 0.12)
        let preserved = try Data(contentsOf: raw)
        precondition(preserved == original)
        print("Recording edit tests passed: real 2× AAC gain, independent mute/mix, overlapping cuts, camera gaps and event mapping")
    }
    static func audioBuffer(time: CMTime, frequency: Double) throws -> CMSampleBuffer {
        let count = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block)
        let samples: [Int16] = (0..<count).map { index in
            Int16(sin(2 * Double.pi * frequency * (time.seconds + Double(index) / 48000)) * 1638)
        }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count, presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer!
    }

    static func toneAmplitudes(_ url: URL) async throws -> (system: Double, microphone: Double, removed: Double) {
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
        return (amplitude(440), amplitude(880), max(amplitude(2200), amplitude(2600)))
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
}
