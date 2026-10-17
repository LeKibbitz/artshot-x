# ArtShot X 0.6.0 architecture · build 7

ArtShot X is an AppKit menu bar app with explicit capture actions. Startup creates its controllers and status item without displaying a window. Screenshots finish in a nonactivating thumbnail; opening an editor is a separate action.

| Component | Responsibility |
| --- | --- |
| `AppDelegate` | Menu bar, capture coordination, transient windows, recent items and quit handling. |
| `GlobalShortcuts` | Carbon hotkeys for Command–Option–Shift–5/6/7 without observing ordinary typing. |
| `CaptureService` | ScreenCaptureKit screenshots; display targeting, exclusion of ArtShot X and Retina pixel preservation. |
| `CapturePanelController` / `CaptureTargetOutline` | Compact nonactivating target/action toolbar and mouse-transparent prepared-region outline. |
| `SelectionOverlayController` | Single-display region selection with Return/Escape confirmation. |
| `ScrollingCaptureController` / `ScrollStitcher` | Settled-frame capture, conservative vertical registration and image assembly. |
| `QuickAccessController` | Bottom-left thumbnail with delete/edit/save/copy actions; image copying only. |
| `CaptureLibrary` | Atomic local index and persistent screenshot/recording originals. |
| `AnnotationCanvas` / `PreviewWindowController` | Arrow, rectangle and numbered-step annotations, undo, PNG export and clipboard copying. |
| `RecordingController` / `ScreenRecorder` | Recording lifecycle, pause/resume, take restart/discard, fixed camera setup and independent media tracks. |
| `LiveCameraSource` | One camera session feeds both the live preview and the original camera video track. |
| `RecordingTimeline` | Host-clock pause intervals, compressed media/event timestamps and PCM trimming across pause boundaries. |
| `CameraOverlayController` / `RecordingControlBar` | Nonactivating live camera preview and compact horizontal recording controls. |
| `CameraLayout` / `CameraVideoCompositor` | Normalized camera placement, circle/square/rounded/vertical-oval masks and centered digital zoom and a shared playback/export renderer. |
| `RecordingComposition` / `VideoPreviewWindowController` | Source/effect toggles, trimming, passage removal, per-source gain, preview and MP4 export. |

## Capture context and focus

Shortcut 7 presents a nonactivating `NSPanel` on the pointer's display. Zone/Display changes the prepared target; Photo/Scroll/Video consumes that target. Zone selection returns to the bar with dimensions and a mouse-transparent outline instead of taking a screenshot. Recording options accept the prepared region without a second selection. Shortcuts 5/6 retain their immediate display/region capture behavior.

The toolbar, selection, video options and scroll HUD never activate ArtShot X. Selection temporarily acquires keyboard focus through a nonactivating panel for Return/Escape, then closes before the next action. Transient panels join all Spaces and applications, with fullscreen-auxiliary behavior. The capture flow no longer hides or reorders editors, nor tries to activate a remembered external application; ScreenCaptureKit already excludes ArtShot X windows. Explicit editor/open-file commands retain normal app activation.

## Images and scrolling

UI controllers belong to the main actor. The coordinator prevents overlapping capture operations. Public region rectangles use global AppKit points with a bottom-left origin; the capture layer converts them into display-local coordinates and native pixels. A region belongs to one display.

Scrolling is manual. A nonactivating HUD leaves input with the underlying app while periodic screenshots wait for stable content. Registration compares grayscale samples at native vertical resolution, ignores duplicate frames and tolerates a fixed heading in the top quarter. It rejects ambiguous overlap, upward movement, oversized movement and detected fixed footers. The user can return to a known position and retry a smaller downward scroll.

The output contains the initial frame followed by newly revealed bottom strips. Each strip is copied into its own bitmap to avoid retaining every full screenshot. Limits are 20,000 output rows, 32 million output pixels and 200 positions. Finishing checks the current viewport again so the final movement is not silently omitted. Cancellation returns no image.

Image previews retain an immutable source and an in-memory annotation list. Numbered steps increment on placement; undo reuses the next available number. Export flattens annotations at source pixel resolution. Closing the editor discards its annotation session; the local original remains available.

## Recordings and edits

ScreenCaptureKit supplies screen frames and optional system audio. AVFoundation supplies optional camera and microphone inputs. A serial recording queue owns frame rendering and media writing. `LiveCameraSource` owns one camera session on a hardware queue, forwards its pixel buffers to the recorder and coalesces preview images to the main actor. Camera authorization occurs only when its option is enabled; starting a camera recording waits for a usable preview frame. The original MOV keeps screen and camera video tracks separate, as well as system and microphone audio tracks. A JSON sidecar stores recording options and timestamped click/shortcut events.

The live camera can be configured before recording as a circle, square, rounded rectangle or 3:4 vertical oval. Its width is 12–45% of the selected display/region width, constrained to fit; drag placement is clamped inside that area. The normalized center and shape frame use a top-left origin, converted to global AppKit coordinates for the overlay. The preview uses aspect fill without mirroring. A shared geometry function applies a centered 1×–3× digital zoom within the fixed mask; size and position are independent of zoom. Older layout JSON without a zoom value decodes as 1×.

The camera layout is frozen at recording start and saved in the recording metadata. A single shape, size, position and zoom applies to the whole video; there are no per-frame transforms or layout keyframes. UserDefaults remembers the last setup for future recordings. The camera window and control bar are excluded from screen capture along with other ArtShot X windows; the independent camera track is composed later. The locked camera overlay lets mouse events pass through to the underlying app.

During recording, Command–Option–Shift–7 reveals a floating horizontal remote rather than the capture panel. It provides Stop with a red recorded-time display, Pause/Resume, Restart, Trash and a drag handle at the right. It can be moved independently without changing the fixed camera layout.

Pause suspends media writing and event recording for the take. `RecordingTimeline` retains the original host-clock pause intervals so late audio/event callbacks can still be classified. Resume removes those intervals from screen, camera, audio and event timestamps; PCM buffers crossing a pause boundary are split and trimmed. The visible timer reads the same timeline. Screen and camera capture stay available for the live preview, and stopping while paused ends at the last written video frame.

Restart finalizes the previous take and archives it through a separate library callback before starting another recorder. It does not display a result thumbnail between takes. Display, selected region, enabled sources and fixed camera layout are retained; the elapsed time resets. The existing live camera source is detached from the old recorder and bound to the new one instead of reopening camera hardware.

Trash finalizes the current take, moves its app-owned project folder to macOS Trash and leaves it out of capture history. It then closes the recording UI and stops the camera. Previously archived takes remain in history. Stop follows the normal completion path and presents the result thumbnail.

Click positions are normalized within the selected capture area. Shortcut labels include special keys and Command shortcuts, using the current keyboard layout; ordinary typed characters are not stored as keyboard events. Enabling these overlays requests Accessibility access. A selected cursor is rendered by ScreenCaptureKit into the screen video and cannot be removed in the editor.

The video editor builds an AVFoundation composition for source toggles, start/end trimming and internal passage removal. `RecordingEditTimeline` subtracts sorted, merged removals from the retained source range and maps between original and output times. Each retained segment is inserted into screen, camera and audio tracks at the same output offset. Screen/camera media gaps remain explicit; removed events are omitted and surviving event lifetimes end at a splice. The UI uses original seconds for selecting removals and provides session-local undo.

Microphone and system gains are independent, from 0 to 2. AVFoundation's documented per-track gain range is 0 to 1, so amplification above unity uses a second synchronized copy with the fractional remainder, summed by the explicit audio mix. This same mix is attached to AVPlayerItem and MP4 export. Zero gain omits the source. No normalization or limiter is applied; high gain can clip. Export flattens selected sources into one AAC track while the original MOV keeps separate tracks.

 A custom Core Image video compositor applies the stored camera layout and mask during both playback and export, preserving the same placement and clipping. Recordings from older versions without layout metadata retain their legacy rectangular placement. Native drawing supplies click/shortcut effects during preview; Core Animation supplies those effects during MP4 export. Edits do not rewrite the original tracks. Export writes a temporary file alongside the destination and replaces the destination only after completion; exporting over the original is rejected.

## Local storage and boundaries

`~/Library/Application Support/ArtShot X/Captures/` contains screenshot originals and the capture index. `Recordings/<UUID>/` contains each original MOV and its metadata. Recent items survive relaunch; the menu displays the most recent 20 entries. Delete moves an app-owned capture or recording project to Trash. It does not authorize deletion outside app storage.

No server, database, login or network upload is involved. There is no durable annotation/edit project format yet. The app uses public macOS APIs and requires macOS 14 or newer.

Synthetic tests cover geometry, annotations, stitching, persistence, camera masks and placement, overlay controls, media composition and export. Earlier 0.2.0 hardware acceptance is recorded in the testing document. Version 0.3.0 live camera setup and a recording stopped through the toolbar were exercised on the built-in display. The new 0.4.0 pause/resume timeline, restart lifecycle and recording Trash workflow require hardware acceptance. Audiovisual synchronization, external display layouts and device failures require broader manual acceptance.
