import AppKit
import ScreenCaptureKit
import AVFoundation
import ApplicationServices

@main struct Bridge {
    static func emit(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: value); print(String(decoding: data, as: UTF8.self)); fflush(stdout) }
    static func inspect(_ url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let screen = tracks.first else { throw RecordingFailure.message("No video track") }
        let size = try await screen.load(.naturalSize)
        let metadata = RecordingMetadata.read(url)
        var result: [String: Any] = ["ok":true,"path":url.path,"duration":duration,"width":Int(size.width),"height":Int(size.height),"camera":metadata?.hasCamera ?? (tracks.count > 1),"system_audio":metadata?.hasSystemAudio ?? false,"microphone":metadata?.hasMicrophone ?? false]
        if let warning = metadata?.warning { result["warning"] = warning }
        return result
    }
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var eventMonitors: [Any] = []
        var previewSource: LiveCameraSource?
        var previewError: String?
        var previewLayout = CameraLayout()
        var overlay: CameraOverlayController?
        var recorder: ScreenRecorder?
        while let line = await Task.detached(operation: { readLine() }).value {
            do {
                let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let action = o["action"] as? String ?? ""
                switch action {
                case "permission": emit(["ok": CGPreflightScreenCaptureAccess(), "requested": (o["request"] as? Bool == true ? CGRequestScreenCaptureAccess() : false)])
                case "current_display":
                    let screen = NSScreen.screens.first(where: {$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main
                    guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw RecordingFailure.message("No current display") }
                    let point = NSEvent.mouseLocation
                    emit(["ok":true,"displayId":number.uint32Value,"x":Int((point.x-screen.frame.minX)*screen.backingScaleFactor),"y":Int((screen.frame.maxY-point.y)*screen.backingScaleFactor)])
                case "preview_camera":
                    guard recorder == nil else { throw RecordingFailure.message("Recording already active") }
                    if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                        guard await AVCaptureDevice.requestAccess(for: .video) else { throw RecordingFailure.message("Camera permission denied") }
                    }
                    let id = (o["displayId"] as! NSNumber).uint32Value
                    guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { throw RecordingFailure.message("Display unavailable") }
                    if let layout = o["cameraLayout"] as? [String: Any] { previewLayout = try JSONDecoder().decode(CameraLayout.self, from: JSONSerialization.data(withJSONObject: layout)) }
                    var area = screen.frame
                    if let r = o["region"] as? [String: NSNumber] {
                        let scale = screen.backingScaleFactor
                        let x=r["x"]!.doubleValue/scale,y=r["y"]!.doubleValue/scale,w=r["width"]!.doubleValue/scale,h=r["height"]!.doubleValue/scale
                        area=CGRect(x:screen.frame.minX+x,y:screen.frame.maxY-y-h,width:w,height:h)
                    }
                    let panel = overlay ?? CameraOverlayController()
                    panel.onLayoutChanged = { layout in previewLayout = layout }
                    panel.show(in:area,layout:previewLayout,editable:true);overlay=panel
                    if previewSource == nil {
                        previewError = nil
                        let source = LiveCameraSource(onImage: { image in overlay?.update(image:image) }, onFailure: { error in previewError=error.localizedDescription;recorder?.cameraFailed(error) })
                        do { try await source.start(); previewSource=source } catch { panel.close();overlay=nil;throw error }
                    }
                    emit(["ok":true,"preview":true,"cameraLayout":try JSONSerialization.jsonObject(with:JSONEncoder().encode(previewLayout))])
                case "preview_status":
                    if let previewError { throw RecordingFailure.message(previewError) }
                    emit(["ok":true,"preview":previewSource != nil,"cameraLayout":try JSONSerialization.jsonObject(with:JSONEncoder().encode(previewLayout))])
                case "stop_preview":
                    guard recorder == nil else { throw RecordingFailure.message("Cannot stop preview during recording") }
                    await previewSource?.stop();previewSource=nil;overlay?.close();overlay=nil;previewError=nil
                    emit(["ok":true])
                case "capture":
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let id = (o["displayId"] as! NSNumber).uint32Value
                    guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecordingFailure.message("Display unavailable") }
                    let pids = [ProcessInfo.processInfo.processIdentifier, (o["excludePid"] as? NSNumber)?.int32Value ?? -1]
                    let apps = content.applications.filter { pids.contains($0.processID) }
                    let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
                    let scale = Double(filter.pointPixelScale)
                    let config = SCStreamConfiguration()
                    config.width = Int(Double(display.width) * scale); config.height = Int(Double(display.height) * scale)
                    if let r = o["region"] as? [String: NSNumber] {
                        let x = r["x"]!.doubleValue, y = r["y"]!.doubleValue, w = r["width"]!.doubleValue, h = r["height"]!.doubleValue
                        guard x >= 0, y >= 0, w > 0, h > 0, x + w <= Double(config.width), y + h <= Double(config.height) else { throw RecordingFailure.message("Invalid capture region") }
                        config.sourceRect = CGRect(x: x / scale, y: y / scale, width: w / scale, height: h / scale)
                        config.width = Int(w); config.height = Int(h)
                    }
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    try png.write(to: URL(fileURLWithPath: o["path"] as! String), options: .atomic)
                    emit(["ok": true])
                case "start":
                    guard recorder == nil else { throw RecordingFailure.message("Recording already active") }
                    let value = ScreenRecorder()
                    if let directory = o["directory"] as? String { value.recordingDirectory = URL(fileURLWithPath: directory, isDirectory: true) }
                    value.excludedProcessID = (o["excludePid"] as? NSNumber)?.int32Value
                    var options = RecordingOptions()
                    options.camera = o["camera"] as? Bool ?? false; options.microphone = o["microphone"] as? Bool ?? false
                    options.systemAudio = o["systemAudio"] as? Bool ?? false; options.cursor = o["cursor"] as? Bool ?? true
                    options.clicks = o["clicks"] as? Bool ?? false; options.keys = o["keys"] as? Bool ?? false
                    if (options.clicks || options.keys) && !AXIsProcessTrusted() { throw RecordingFailure.message("Accessibility permission is required to record clicks or shortcuts") }
                    if let layout = o["cameraLayout"] as? [String: Any] { options.cameraLayout = try JSONDecoder().decode(CameraLayout.self, from: JSONSerialization.data(withJSONObject: layout)) }
                    if previewSource != nil, let overlay { options.cameraLayout = overlay.currentLayout }
                    if options.camera && AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                        guard await AVCaptureDevice.requestAccess(for: .video) else { throw RecordingFailure.message("Camera permission denied") }
                    }
                    if options.microphone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecordingFailure.message("Microphone permission denied") }
                    }
                    let id = (o["displayId"] as! NSNumber).uint32Value
                    var rect: CGRect?
                    if let r = o["region"] as? [String: NSNumber] {
                        let scale = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id })?.backingScaleFactor ?? 1
                        rect = CGRect(x: r["x"]!.doubleValue / scale, y: r["y"]!.doubleValue / scale, width: r["width"]!.doubleValue / scale, height: r["height"]!.doubleValue / scale)
                    }
                    if options.camera, let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
                        let panel = overlay ?? CameraOverlayController()
                        let area = rect.map { CGRect(x: screen.frame.minX + $0.minX, y: screen.frame.maxY - $0.maxY, width: $0.width, height: $0.height) } ?? screen.frame
                        panel.show(in: area, layout: options.cameraLayout ?? .default, editable: false)
                        value.onCameraImage = { image in Task { @MainActor in panel.update(image: image) } }
                        overlay = panel
                    }
                    if options.camera, let previewSource { await previewSource.setBufferHandler { frame in value.receiveCameraFrame(frame) } }
                    if !options.camera { await previewSource?.stop();previewSource=nil;overlay?.close();overlay=nil }
                    do { try await value.start(displayID: id, sourceRect: rect, options: options, externalCamera:options.camera && previewSource != nil); recorder = value }
                    catch { _ = try? await value.finish(cancel: true); overlay?.close(); overlay = nil; throw error }
                    if options.clicks || options.keys, let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
                        let source = rect ?? CGRect(origin: .zero, size: screen.frame.size)
                        let clicks = options.clicks, keys = options.keys
                        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown,.keyDown], handler: { event in
                            if event.type == .keyDown {
                                if keys, let label = RecordingShortcutLabel.make(event) { value.addEvent(label:label) }
                            } else if clicks {
                                let point = NSEvent.mouseLocation
                                let x = point.x - screen.frame.minX - source.minX
                                let y = screen.frame.maxY - point.y - source.minY
                                if x >= 0 && y >= 0 && x <= source.width && y <= source.height { value.addEvent(x:Double(x/source.width),y:Double(y/source.height)) }
                            }
                        }) { eventMonitors.append(monitor) }
                    }
                    emit(["ok": true])
                case "status":
                    if let recorder {
                        let (paused,elapsed,error) = await recorder.currentStatus()
                        if let error { throw RecordingFailure.message(error) }
                        emit(["ok":true,"active":true,"paused":paused,"elapsed":elapsed])
                    } else { emit(["ok":true,"active":false,"paused":false,"elapsed":0]) }
                case "pause", "resume":
                    guard let recorder else { throw RecordingFailure.message("No recording") }
                    await recorder.setPaused(action == "pause"); emit(["ok": true])
                case "stop":
                    guard let value = recorder else { throw RecordingFailure.message("No recording") }
                    for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }; eventMonitors = []
                    recorder = nil; overlay?.close(); overlay = nil
                    await previewSource?.setBufferHandler(nil)
                    await previewSource?.stop();previewSource=nil
                    let url = try await value.finish(cancel: false)
                    emit(try await inspect(url!))
                case "inspect":
                    emit(try await inspect(URL(fileURLWithPath: o["path"] as! String)))
                case "export":
                    var edit = RecordingEdit()
                    edit.start = o["start"] as? Double ?? 0; edit.end = o["end"] as? Double ?? Double.greatestFiniteMagnitude
                    edit.systemAudioVolume = o["systemGain"] as? Double ?? 1; edit.microphoneVolume = o["microphoneGain"] as? Double ?? 1
                    edit.camera = o["camera"] as? Bool ?? true
                    edit.clicks = o["clicks"] as? Bool ?? true; edit.keys = o["keys"] as? Bool ?? true
                    edit.cuts = (o["cuts"] as? [[String: Double]] ?? []).map { RecordingCut(start: $0["start"] ?? 0, end: $0["end"] ?? 0) }
                    let source = URL(fileURLWithPath: o["path"] as! String)
                    if var metadata = RecordingMetadata.read(source), let layout = o["cameraLayout"] as? [String: Any] {
                        metadata.options.cameraLayout = try JSONDecoder().decode(CameraLayout.self, from: JSONSerialization.data(withJSONObject: layout))
                        try JSONEncoder().encode(metadata).write(to: RecordingMetadata.sidecar(for: source), options: .atomic)
                    }
                    try await RecordingComposition.export(url: source, edit: edit, to: URL(fileURLWithPath: o["destination"] as! String)); emit(["ok": true])
                default: throw RecordingFailure.message("Unknown native action")
                }
            } catch { emit(["ok": false, "error": error.localizedDescription]) }
        }
        if let recorder { _ = try? await recorder.finish(cancel: true) }
        await previewSource?.stop();overlay?.close()
    }
}
