import AVFoundation

/// Host-clock intervals are retained so callbacks delivered after Resume can still
/// identify, trim and discard samples captured during any earlier pause.
struct RecordingTimeline {
    private struct Pause {
        let start: CMTime
        var end: CMTime?
    }
    private var pauses: [Pause] = []
    private(set) var origin: CMTime?
    private var stoppedAt: CMTime?
    var isPaused: Bool { pauses.last?.end == nil && !pauses.isEmpty }

    mutating func begin(at time: CMTime) {
        if origin == nil { origin = time }
    }

    mutating func setPaused(_ paused: Bool, at time: CMTime) {
        guard paused != isPaused, stoppedAt == nil else { return }
        if paused { pauses.append(Pause(start: time, end: nil)) }
        else { pauses[pauses.count - 1].end = max(time, pauses.last!.start) }
    }

    mutating func stop(at time: CMTime) { stoppedAt = time }

    func isPaused(at time: CMTime) -> Bool {
        pauses.contains { time >= $0.start && ($0.end == nil || time < $0.end!) }
    }

    private func excludedDuration(until time: CMTime) -> CMTime {
        guard let origin else { return .zero }
        return pauses.reduce(.zero) { total, pause in
            let start = max(origin, pause.start)
            let end = min(time, pause.end ?? time)
            return end > start ? total + end - start : total
        }
    }

    /// Presentation timestamps remain in the writer's original host-clock domain.
    func presentationTime(for hostTime: CMTime) -> CMTime? {
        guard let origin, hostTime >= origin, !isPaused(at: hostTime), stoppedAt == nil || hostTime <= stoppedAt! else { return nil }
        return hostTime - excludedDuration(until: hostTime)
    }

    func elapsed(at hostTime: CMTime) -> Double {
        guard let origin else { return 0 }
        let end = min(hostTime, stoppedAt ?? hostTime)
        return max(0, (end - origin - excludedDuration(until: end)).seconds)
    }

    private func sampleTime(_ count: Int, sampleRate: Double) -> CMTime {
        if sampleRate == sampleRate.rounded(), sampleRate <= Double(Int32.max) {
            return CMTime(value: Int64(count), timescale: Int32(sampleRate))
        }
        return CMTime(seconds: Double(count) / sampleRate, preferredTimescale: 1_000_000_000)
    }

    /// Returns PCM sample ranges whose entire sample duration is outside pauses.
    func audioSampleRanges(start: CMTime, count: Int, sampleRate: Double) -> [Range<Int>] {
        guard count > 0, sampleRate > 0, sampleRate.isFinite, let origin else { return [] }
        let end = start + sampleTime(count, sampleRate: sampleRate)
        var intervals = [(max(start, origin), min(end, stoppedAt ?? end))]
        for pause in pauses {
            let pauseEnd = pause.end ?? end
            intervals = intervals.flatMap { begin, finish -> [(CMTime, CMTime)] in
                guard pause.start < finish, pauseEnd > begin else { return [(begin, finish)] }
                var result: [(CMTime, CMTime)] = []
                if begin < pause.start { result.append((begin, min(finish, pause.start))) }
                if pauseEnd < finish { result.append((max(begin, pauseEnd), finish)) }
                return result
            }
        }
        return intervals.compactMap { begin, finish in
            guard finish > begin else { return nil }
            // Host-clock timestamps rounded to nanoseconds must not lose a full sample.
            let roundingTolerance = 0.0001
            let lower = max(0, min(count, Int(ceil((begin - start).seconds * sampleRate - roundingTolerance))))
            let upper = max(0, min(count, Int(floor((finish - start).seconds * sampleRate + roundingTolerance))))
            return upper > lower ? lower..<upper : nil
        }
    }

    /// Supports both interleaved microphone PCM and planar ScreenCaptureKit PCM.
    /// Copying only retained sample bytes prevents paused audio from reaching AAC.
    func audioBuffers(from buffer: CMSampleBuffer) throws -> [CMSampleBuffer] {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw RecordingFailure.message("Le format audio de capture est incompatible.")
        }
        let asbd = description.pointee
        let sampleRate = asbd.mSampleRate
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        let ranges = audioSampleRanges(start: start, count: CMSampleBufferGetNumSamples(buffer), sampleRate: sampleRate)
        guard !ranges.isEmpty else { return [] }
        var listSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: nil)
        guard (sizeStatus == noErr || sizeStatus == kCMSampleBufferError_ArrayTooSmall), listSize > 0 else { throw RecordingFailure.message("Impossible de lire le format audio.") }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { memory.deallocate() }
        let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retainedBlock)
        guard status == noErr else { throw RecordingFailure.message("Impossible de lire les échantillons audio.") }
        defer { withExtendedLifetime(retainedBlock) {} }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        return try ranges.map { range in
            let hostPTS = start + sampleTime(range.lowerBound, sampleRate: sampleRate)
            guard let pts = presentationTime(for: hostPTS) else { throw RecordingFailure.message("Horodatage audio invalide.") }
            var bytes = Data()
            for source in buffers {
                let offset = range.lowerBound * bytesPerFrame
                let length = range.count * bytesPerFrame
                guard let data = source.mData, offset + length <= Int(source.mDataByteSize) else { throw RecordingFailure.message("Les données audio sont incomplètes.") }
                bytes.append(data.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: length)
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw RecordingFailure.message("Impossible de préparer le son.") }
            let copied = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
            guard copied == kCMBlockBufferNoErr else { throw RecordingFailure.message("Impossible de copier le son.") }
            var output: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: range.count, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &output) == noErr, let output else { throw RecordingFailure.message("Impossible de synchroniser le son.") }
            return output
        }
    }
}
