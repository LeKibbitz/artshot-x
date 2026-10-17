import AVFoundation

struct RecordingPauseChecks {
    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }

    static func run(in folder: URL) async throws {
        var timeline = RecordingTimeline()
        timeline.setPaused(true, at: time(98))
        timeline.setPaused(false, at: time(99))
        timeline.begin(at: time(100))
        timeline.setPaused(true, at: time(101.25))
        timeline.setPaused(true, at: time(101.5))
        timeline.setPaused(false, at: time(102.75))
        timeline.setPaused(false, at: time(102.9))
        timeline.setPaused(true, at: time(103.25))
        timeline.setPaused(false, at: time(103.75))
        precondition(timeline.presentationTime(for: time(101.5)) == nil)
        precondition(timeline.presentationTime(for: time(103.5)) == nil)
        precondition(abs(timeline.presentationTime(for: time(102.75))!.seconds - 101.25) < 0.000001)
        precondition(abs(timeline.elapsed(at: time(104)) - 2) < 0.000001)
        for planar in [false, true] {
            let source = try makePCM(start: time(101), count: 144000, channels: 2, planar: planar) { index, channel in Float(index + channel * 200000) }
            let clipped = try timeline.audioBuffers(from: source)
            precondition(clipped.count == 3, "Audio crossing both pause boundaries must be split")
            let ranges = [0..<12000, 84000..<108000, 132000..<144000]
            let timestamps = [101.0, 101.25, 101.75]
            for (index, buffer) in clipped.enumerated() {
                precondition(CMSampleBufferGetNumSamples(buffer) == ranges[index].count)
                precondition(abs(CMSampleBufferGetPresentationTimeStamp(buffer).seconds - timestamps[index]) < 0.000001)
                let channels = try pcmChannels(buffer)
                precondition(channels.count == 2)
                for channel in 0..<2 {
                    for (offset, value) in channels[channel].enumerated() {
                        precondition(value == Float(ranges[index].lowerBound + offset + channel * 200000), "PCM clipping must preserve channel contents and exclude every paused sample")
                    }
                }
            }
        }
        var continuous = RecordingTimeline()
        continuous.begin(at: time(100))
        for index in 0..<90 {
            let ranges = continuous.audioSampleRanges(start: time(100 + Double(index) / 30), count: 1600, sampleRate: 48000)
            precondition(ranges == [0..<1600], "Host-clock rounding must never lose one sample per audio block")
        }
        var fractional = RecordingTimeline()
        fractional.begin(at: .zero)
        fractional.setPaused(true, at: time(0.0255))
        fractional.setPaused(false, at: time(0.0505))
        precondition(fractional.audioSampleRanges(start: .zero, count: 100, sampleRate: 1000) == [0..<25, 51..<100], "Partial samples overlapping a pause boundary must be excluded")
        timeline.stop(at: time(104.5))
        precondition(abs(timeline.elapsed(at: time(200)) - 2.5) < 0.000001)
        precondition(timeline.presentationTime(for: time(105)) == nil)
        precondition(RecordingTimeline().elapsed(at: time(200)) == 0, "Each recorder must have a fresh timeline")
        try await ScreenRecorder.testPublicPauseAndCameraCache()
        let output = folder.appendingPathComponent("paused-real-writer", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = output.appendingPathComponent("capture.mov")
        let recorded = try await ScreenRecorder.testPausedMedia(at: url)
        precondition(recorded == url)
        let metadata = RecordingMetadata.read(url)!
        precondition(abs(metadata.duration - 2.5) < 0.04, "Stop during pause must finalize 2.5 active seconds, without paused gaps")
        precondition(metadata.events.count == 3, "Paused and delayed paused events must not be stored")
        for (event, expected) in zip(metadata.events, [0.2, 1.2, 2.3]) {
            precondition(abs(event.time - expected) < 0.000001, "Event timestamps must subtract all previous pauses")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        precondition(abs(duration - 2.5) < 0.06)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        precondition(videos.count == 2 && audios.count == 2)
        for (index, track) in videos.enumerated() {
            let reader = try AVAssetReader(asset: asset)
            let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(frames)
            guard reader.startReading() else { throw reader.error! }
            var count = 0
            var previous: Double?
            while let sample = frames.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if let previous { precondition(pts - previous < 0.04, "Paused time must not create gaps in either video track") }
                previous = pts
                let pixel = CMSampleBufferGetImageBuffer(sample)!
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                let offset = CVPixelBufferGetBytesPerRow(pixel) * (CVPixelBufferGetHeight(pixel) / 2) + (CVPixelBufferGetWidth(pixel) / 2) * 4
                precondition(bytes[offset + 1] < 80, "Green frames delivered during pause must never be encoded")
                precondition(index == 0 ? bytes[offset + 2] > 180 : bytes[offset] > 180, "Screen and camera frames must survive Resume")
                CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                count += 1
            }
            guard reader.status == .completed else { throw reader.error! }
            precondition(count == 75, "Only 75 active video/camera frames must be written")
        }
        for (index, wanted) in [440.0, 880.0].enumerated() {
            let amplitudes = try await audioAmplitudes(url, trackIndex: index, frequencies: [wanted, 2000])
            precondition(amplitudes[0] > 0.15 && amplitudes[1] < 0.01, "Active audio must survive, while paused 2000 Hz audio must be absent")
        }
        let mp4 = output.appendingPathComponent("paused.mp4")
        try await RecordingComposition.export(url: url, edit: RecordingEdit(), to: mp4)
        let mp4Asset = AVURLAsset(url: mp4)
        let mp4Audio = try await mp4Asset.loadTracks(withMediaType: .audio)
        let mp4Duration = try await mp4Asset.load(.duration).seconds
        precondition(mp4Audio.count == 1 && abs(mp4Duration - 2.5) < 0.06)
        let mixed = try await audioAmplitudes(mp4, trackIndex: 0, frequencies: [440, 880, 2000])
        precondition(mixed[0] > 0.06 && mixed[1] > 0.06 && mixed[2] < 0.01, "Portable MP4 must mix active audio without paused sound")
        print("PASS: real pause writer: 75 screen/camera frames, 2.5 active seconds, synchronized audio/events, no paused pixels/tone; planar PCM boundary clipping and delayed callbacks")
    }

    static func makePCM(start: CMTime, count: Int = 1600, channels: Int = 1, planar: Bool = false, value: (Int, Int) -> Float) throws -> CMSampleBuffer {
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0)
        let frameBytes = UInt32(MemoryLayout<Float>.size * (planar ? 1 : channels))
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else { throw RecordingFailure.message("Cannot create PCM fixture") }
        var samples = [Float](repeating: 0, count: count * channels)
        for channel in 0..<channels { for index in 0..<count { samples[planar ? channel * count + index : index * channels + channel] = value(index, channel) } }
        let length = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr else { throw RecordingFailure.message("Cannot create PCM data") }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count, presentationTimeStamp: start, packetDescriptions: nil, sampleBufferOut: &buffer) == noErr, let buffer else { throw RecordingFailure.message("Cannot create PCM buffer") }
        return buffer
    }

    static func pcmChannels(_ buffer: CMSampleBuffer) throws -> [[Float]] {
        let format = CMSampleBufferGetFormatDescription(buffer)!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let count = CMSampleBufferGetNumSamples(buffer)
        var listSize = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: nil)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retained)
        guard status == noErr else { throw RecordingFailure.message("Cannot inspect PCM fixture: \(status), channels \(channels), count \(count), planar \(planar)") }
        defer { withExtendedLifetime(retained) {} }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return (0..<channels).map { channel in
            let data = buffers[planar ? channel : 0].mData!.assumingMemoryBound(to: Float.self)
            return (0..<count).map { data[planar ? $0 : $0 * channels + channel] }
        }
    }

    static func audioAmplitudes(_ url: URL, trackIndex: Int, frequencies: [Double]) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[trackIndex], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() { samples.append(contentsOf: try pcmChannels(buffer)[0]) }
        guard reader.status == .completed else { throw reader.error! }
        return frequencies.map { frequency in
            var real = 0.0
            var imaginary = 0.0
            for (index, sample) in samples.enumerated() {
                let phase = 2 * Double.pi * frequency * Double(index) / 48000
                real += Double(sample) * cos(phase)
                imaginary += Double(sample) * sin(phase)
            }
            return 2 * hypot(real, imaginary) / Double(samples.count)
        }
    }
}
