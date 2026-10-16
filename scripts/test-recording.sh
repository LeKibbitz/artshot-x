#!/bin/bash
set -euo pipefail
recording_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$recording_project_root"
testDirectory="$(mktemp -d -t artshot-recording-test)"
trap 'rm -f "$testDirectory/test" "$testDirectory/ScreenRecorder.swift"; rmdir "$testDirectory"' EXIT
cp Sources/ArtShotX/ScreenRecorder.swift "$testDirectory/ScreenRecorder.swift"
# Same-file extension exercises real private finalization without adding test hooks to the app.
cat >> "$testDirectory/ScreenRecorder.swift" <<'SWIFT'

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
}
SWIFT
swiftc -target "$(uname -m)-apple-macosx14.0" -parse-as-library Sources/ArtShotX/RecordingMedia.swift "$testDirectory/ScreenRecorder.swift" Tests/test-recording.swift -o "$testDirectory/test"
"$testDirectory/test"
