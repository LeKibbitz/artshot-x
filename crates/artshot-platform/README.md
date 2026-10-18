# ArtShot native platform

`list_displays`, `capture`, `capture_png` use xcap native display capture. Dimensions and region coordinates are physical pixels. Region origin is local to the chosen display; display origin is global top-left. macOS backing scale is applied to CoreGraphics monitor bounds. Do not infer gaps/adjacency on mixed-scale macOS displays from physical rectangles; use Tauri display placement for window positioning.

macOS 14+: build the helper with `swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 crates/artshot-platform/native/macos/*.swift -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker crates/artshot-platform/native/macos/Info.plist -o artshot-native`. For Intel use `x86_64-apple-macos14.0`; universal builds require lipo. Embed the helper in the signed parent app with camera and microphone usage descriptions. ScreenCaptureKit captures while excluding parent PID and helper PID. Screen, camera, system audio and microphone remain independent tracks in capture.mov. The AVFoundation compositor exports cuts, trim, gains and camera circle/square/roundedRectangle/verticalOval layouts, size, zoom and position. `NativeBridge` serializes JSON line requests; protect it with a mutex.

Helper actions:
- permission `{request:bool}`
- current_display (returns displayId and local physical cursor x/y)
- preview_camera `{displayId,region?,cameraLayout?}` / preview_status / stop_preview
- capture `{displayId,region?,path,excludePid}`
- start `{displayId,region?,excludePid,directory?,camera,microphone,systemAudio,cursor,cameraLayout?}`
- pause / resume / stop / status
- inspect `{path}`
- export `{path,destination,start?,end?,cuts?:[{start,end}],systemGain?,microphoneGain?,camera?,cameraLayout?}`

Stop and inspect return path, duration, width, height, camera, system_audio, microphone. cameraLayout uses shape, widthFraction, centerX, centerY, zoom. Camera preview shares the recorder's hardware session and is excluded from screen capture. Start can reuse a live preview without handing the camera between sessions. preview_status returns the latest layout after dragging the native overlay. Windows CameraPreview supplies pre-record JPEGs; stop it before starting Recorder.

Windows 11: `media::Recorder` uses bundled FFmpeg gdigrab and DirectShow camera. The default camera is discovered with `list_devices`. WASAPI captures default output loopback and default microphone into independent WAVs. WASAPI audio resumes after the first screen frame is acknowledged by FFmpeg progress. Optional click/shortcut monitoring saves events.json; export remaps these through cuts. Ordinary typing is never captured. The same camera stream produces camera-preview.jpg via atomic JPEG updates at 5fps for the host overlay. Pause finishes the current MKV segment and pauses WAV acquisition; resume launches a new MKV segment and resumes WAVs. `stop_with_audio` returns segments and audio paths. Concatenate segments, probe the assembled file, set manifest audio flags, and export with `export_mp4`, supplying the WAV paths. Exclude application HWNDs using WDA_EXCLUDEFROMCAPTURE in the host. Bundle FFmpeg and FFprobe executables. Recorder's external screen process and WASAPI clocks can differ during device startup: hardware A/V synchronization requires Windows integration verification.

Verification: `cargo test -p artshot-platform --lib`; `cargo run -p artshot-platform --example export_smoke` generates real synthetic multi-track media and verifies camera/cut/gain export; `cargo run -p artshot-platform --example capture_smoke` captures a real 128x96 native region and checks its pixels dimensions.
