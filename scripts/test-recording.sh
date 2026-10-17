#!/bin/bash
set -euo pipefail
recording_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$recording_project_root"
testDirectory="$(mktemp -d -t artshot-recording-test)"
trap 'rm -f "$testDirectory/test" "$testDirectory/ScreenRecorder.swift"; rmdir "$testDirectory"' EXIT
cp Sources/ArtShotX/ScreenRecorder.swift "$testDirectory/ScreenRecorder.swift"
# Same-file extension exercises real private finalization without adding test hooks to the app.
cat >> "$testDirectory/ScreenRecorder.swift" <<'SWIFT'

// Immutable test buffers cross queues through an explicitly scoped test-only box.
struct RecordingTestBox<Value>: @unchecked Sendable { let value: Value }

extension ScreenRecorder {
    @MainActor
    static func testInterruptedFinalization(at url: URL) async throws -> (URL?, String?) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
        for index in 0..<15 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error! }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw writer.error! }
        }
        let recorder = ScreenRecorder()
        recorder.writer = writer
        recorder.url = url
        recorder.startTime = .zero
        recorder.lastTime = CMTime(value: 14, timescale: 30)
        recorder.screenInput = input
        recorder.failure = RecordingFailure.message("Synthetic display disconnect")
        let result = try await recorder.finish(cancel: false)
        return (result, recorder.completionWarning)
    }
    @MainActor
    static func testPublicPauseAndCameraCache() async throws {
        let recorder = ScreenRecorder()
        await recorder.setPaused(true)
        let initialElapsed = await recorder.elapsedDuration()
        precondition(initialElapsed == 0)
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel)
        let frame = RecordingTestBox(value: pixel!)
        recorder.receiveCameraFrame(frame.value)
        let updated = await withCheckedContinuation { continuation in
            recorder.queue.async { continuation.resume(returning: recorder.cameraImage === frame.value && recorder.timeline.isPaused) }
        }
        precondition(updated, "Camera cache must continue updating during pause")
        await recorder.setPaused(false)
        let resumedElapsed = await recorder.elapsedDuration()
        precondition(resumedElapsed == 0)
    }

    @MainActor
    static func testPausedMedia(at url: URL) async throws -> URL? {
        let recorder = ScreenRecorder()
        recorder.options = RecordingOptions(camera: true, microphone: true, systemAudio: true, cursor: false, clicks: true, keys: true)
        recorder.size = CGSize(width: 64, height: 48)
        recorder.url = url
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        recorder.writer = writer
        let (screenInput, screenAdaptor) = recorder.makeVideoInput(width: 64, height: 48)
        writer.add(screenInput)
        recorder.screenInput = screenInput
        recorder.screenAdaptor = screenAdaptor
        let (cameraInput, cameraAdaptor) = recorder.makeVideoInput(width: 640, height: 480)
        writer.add(cameraInput)
        recorder.cameraInput = cameraInput
        recorder.cameraAdaptor = cameraAdaptor
        recorder.systemInput = try recorder.makeAudioInput(writer: writer, channels: 2)
        recorder.micInput = try recorder.makeAudioInput(writer: writer, channels: 1)
        func pixel(red: UInt8, green: UInt8, blue: UInt8) -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<48 { for x in 0..<64 {
                let offset = y * stride + x * 4
                bytes[offset] = blue; bytes[offset + 1] = green; bytes[offset + 2] = red; bytes[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            return buffer!
        }
        let red = RecordingTestBox(value: pixel(red: 240, green: 15, blue: 15))
        let blue = RecordingTestBox(value: pixel(red: 15, green: 15, blue: 240))
        let green = RecordingTestBox(value: pixel(red: 15, green: 240, blue: 15))
        await withCheckedContinuation { continuation in recorder.queue.async {
            recorder.active = true
            recorder.screenImage = green.value
            recorder.timeline.setPaused(true, at: .zero)
            recorder.writeFrame(at: RecordingPauseChecks.time(0.5))
            precondition(recorder.startTime == nil, "Pause before the first frame must not start the writer")
            recorder.timeline.setPaused(false, at: RecordingPauseChecks.time(1))
            continuation.resume()
        } }
        for index in 0..<150 {
            let host = RecordingPauseChecks.time(1 + Double(index) / 30)
            let paused = (30..<60).contains(index) || (90..<105).contains(index) || index >= 120
            let frequency = paused ? 2000.0 : 440.0
            let system = RecordingTestBox(value: try RecordingPauseChecks.makePCM(start: host, channels: 2, planar: true) { sample, _ in Float(sin(2 * Double.pi * frequency * (host.seconds + Double(sample) / 48000)) * 0.25) })
            let micFrequency = paused ? 2000.0 : 880.0
            let microphone = RecordingTestBox(value: try RecordingPauseChecks.makePCM(start: host) { sample, _ in Float(sin(2 * Double.pi * micFrequency * (host.seconds + Double(sample) / 48000)) * 0.25) })
            if !paused && index > 0 {
                let deadline = Date().addingTimeInterval(5)
                while !screenInput.isReadyForMoreMediaData || !cameraInput.isReadyForMoreMediaData || !recorder.systemInput!.isReadyForMoreMediaData || !recorder.micInput!.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error! }
                    if Date() > deadline { throw RecordingFailure.message("Pause fixture writer stalled") }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            recorder.receiveCameraFrame(paused ? green.value : blue.value)
            await withCheckedContinuation { continuation in recorder.queue.async {
                if [30, 90, 120].contains(index) { recorder.timeline.setPaused(true, at: host) }
                if [60, 105].contains(index) { recorder.timeline.setPaused(false, at: host) }
                recorder.screenImage = paused ? green.value : red.value
                recorder.writeFrame(at: host)
                recorder.appendAudio(system.value, input: recorder.systemInput, system: true)
                recorder.appendAudio(microphone.value, input: recorder.micInput, system: false)
                if [6, 36, 66, 96, 114, 126].contains(index) {
                    recorder.recordEvent(at: host, x: 0.5, y: 0.5, label: index == 66 ? "⌘C" : nil)
                }
                if index == 63 {
                    recorder.recordEvent(at: RecordingPauseChecks.time(2.2), x: nil, y: nil, label: "⌘V")
                    let before = recorder.systemSamples
                    let delayed = try! RecordingPauseChecks.makePCM(start: RecordingPauseChecks.time(2.2)) { sample, _ in Float(sin(2 * Double.pi * 2000 * Double(sample) / 48000) * 0.25) }
                    recorder.appendAudio(delayed, input: recorder.systemInput, system: true)
                    precondition(recorder.systemSamples == before, "Delayed paused audio must be discarded after Resume")
                }
                continuation.resume()
            } }
        }
        let elapsed = await recorder.elapsedDuration()
        precondition(abs(elapsed - 2.5) < 0.000001, "Clock must freeze during the final pause")
        return try await recorder.finish(cancel: false)
    }

}
SWIFT
swiftc -target "$(uname -m)-apple-macosx14.0" -parse-as-library Sources/ArtShotX/RecordingMedia.swift Sources/ArtShotX/RecordingTimeline.swift Sources/ArtShotX/CameraLayout.swift Sources/ArtShotX/CameraVideoCompositor.swift "$testDirectory/ScreenRecorder.swift" Tests/test-recording.swift Tests/test-recording-pause.swift -o "$testDirectory/test"
"$testDirectory/test"
