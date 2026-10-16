# ArtShot X 0.2.0 architecture

ArtShot X is an AppKit menu bar app with explicit capture actions. Startup creates its controllers and status item without displaying a window. Screenshots finish in a nonactivating thumbnail; opening an editor is a separate action.

| Component | Responsibility |
| --- | --- |
| `AppDelegate` | Menu bar, capture coordination, transient windows, recent items and quit handling. |
| `GlobalShortcuts` | Carbon hotkeys for Command–Option–Shift–5/6/7 without observing ordinary typing. |
| `CaptureService` | ScreenCaptureKit screenshots; display targeting, exclusion of ArtShot X and Retina pixel preservation. |
| `SelectionOverlayController` | Single-display region selection with Return/Escape confirmation. |
| `ScrollingCaptureController` / `ScrollStitcher` | Settled-frame capture, conservative vertical registration and image assembly. |
| `QuickAccessController` | Bottom-left thumbnail with delete/edit/save/copy actions; image copying only. |
| `CaptureLibrary` | Atomic local index and persistent screenshot/recording originals. |
| `AnnotationCanvas` / `PreviewWindowController` | Arrow, rectangle and numbered-step annotations, undo, PNG export and clipboard copying. |
| `RecordingController` / `ScreenRecorder` | Recording options, permissions, device capture, screen capture and independent media tracks. |
| `RecordingComposition` / `VideoPreviewWindowController` | Source/effect toggles, trimming, preview and MP4 export. |

## Images and scrolling

UI controllers belong to the main actor. The coordinator prevents overlapping capture operations. Public region rectangles use global AppKit points with a bottom-left origin; the capture layer converts them into display-local coordinates and native pixels. A region belongs to one display.

Scrolling is manual. A nonactivating HUD leaves input with the underlying app while periodic screenshots wait for stable content. Registration compares grayscale samples at native vertical resolution, ignores duplicate frames and tolerates a fixed heading in the top quarter. It rejects ambiguous overlap, upward movement, oversized movement and detected fixed footers. The user can return to a known position and retry a smaller downward scroll.

The output contains the initial frame followed by newly revealed bottom strips. Each strip is copied into its own bitmap to avoid retaining every full screenshot. Limits are 20,000 output rows, 32 million output pixels and 200 positions. Finishing checks the current viewport again so the final movement is not silently omitted. Cancellation returns no image.

Image previews retain an immutable source and an in-memory annotation list. Numbered steps increment on placement; undo reuses the next available number. Export flattens annotations at source pixel resolution. Closing the editor discards its annotation session; the local original remains available.

## Recordings and edits

ScreenCaptureKit supplies screen frames and optional system audio. AVFoundation supplies optional camera and microphone inputs. A serial recording queue owns frame rendering and media writing. The original MOV keeps screen and camera video tracks separate, as well as system and microphone audio tracks. A JSON sidecar stores recording options and timestamped click/shortcut events.

Click positions are normalized within the selected capture area. Shortcut labels include special keys and Command shortcuts, using the current keyboard layout; ordinary typed characters are not stored as keyboard events. Enabling these overlays requests Accessibility access. A selected cursor is rendered by ScreenCaptureKit into the screen video and cannot be removed in the editor.

The video editor builds an AVFoundation composition for source toggles and start/end trimming. Native drawing supplies click/shortcut effects during preview; Core Animation supplies those effects during MP4 export. Edits do not rewrite the original tracks. Export writes a temporary file alongside the destination and replaces the destination only after completion; exporting over the original is rejected.

## Local storage and boundaries

`~/Library/Application Support/ArtShot X/Captures/` contains screenshot originals and the capture index. `Recordings/<UUID>/` contains each original MOV and its metadata. Recent items survive relaunch; the menu displays the most recent 20 entries. Delete moves an app-owned capture or recording project to Trash. It does not authorize deletion outside app storage.

No server, database, login or network upload is involved. There is no durable annotation/edit project format yet. The app uses public macOS APIs and requires macOS 14 or newer.

Synthetic tests cover geometry, annotations, stitching, media composition and export. Hardware permissions, live audiovisual synchronization, external display layouts and device failures require separate manual acceptance.
