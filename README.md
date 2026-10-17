# ArtShot X

A local, open-source screenshot and screen recording utility for macOS. Built with Swift, AppKit and ScreenCaptureKit.

## Version 0.3.0 · build 3

- Capture the display under your pointer or select a region.
- Get a floating thumbnail at the bottom left, with **Delete**, **Edit**, **Save** and **Copy** actions. Copy is available for images.
- Annotate images with arrows, rectangles and numbered steps; undo annotations, copy the result or save a PNG.
- Reopen recent screenshots and recordings across app launches. Originals stay on your Mac.
- Stitch a vertical scrolling screenshot while you scroll the underlying app manually.
- Record a display or region, optionally with live camera, system audio, microphone, click indicators and shortcut labels.
- Preview the camera before recording; choose a circle, square or rounded rectangle, adjust its size and drag it into position. One fixed layout applies to the entire video.
- Use a compact horizontal recording bar for elapsed time, Stop, Cancel and showing the camera. Command–Option–Shift–7 brings it back during recording.
- Edit a recording by toggling captured sources and effects, trimming its start/end and exporting an MP4 with one mixed audio track. The cursor, when enabled, is baked into the screen video.

The app runs in the background with a menu bar icon. Launching it does not open a panel or editor. The interface is currently in French. GIF export, OCR and window-specific capture are not included.

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode or Command Line Tools). There are no third-party dependencies.

```sh
bash scripts/test.sh
bash scripts/test-preview.sh
bash scripts/test-recording.sh
bash scripts/test-library.sh
bash scripts/test-capture-ui.sh
bash scripts/test-recording-overlays.sh
bash scripts/test-recording-controls.sh
bash scripts/build.sh
open "dist/ArtShot X.app"
```

Open the menu bar icon or use the capture panel shortcut. Grant screen recording access in macOS Privacy & Security when prompted, then relaunch if macOS requests it. Camera and microphone permissions are requested only when selected. Click and shortcut overlays require Accessibility access. Existing images and the sample editor work without screen capture permission.

| Shortcut | Action |
| --- | --- |
| Command + Option + Shift + 5 | Capture a display |
| Command + Option + Shift + 6 | Select a region |
| Command + Option + Shift + 7 | Open the capture panel, or reveal the active recording bar |

The shortcuts use physical number-row keys on AZERTY and QWERTY. If a shortcut conflicts, menu bar and panel commands remain available. ArtShot X does not change macOS shortcuts or disable other apps.

For a region, drag to select, press Return to confirm or Escape to cancel. Selection stays on one display. For a scrolling capture, select the document content, scroll downward in small increments and pause after each increment. Click **Terminer** to assemble the image or **Annuler** to cancel. Uncertain alignment, upward scrolling and fixed footers are rejected. Limits are 20,000 pixels of height, 32 million pixels and 200 captured positions.

Enable the camera in the recording options to see its live preview. Choose its shape and size, then drag it within the selected display or region. The setting is saved as a single layout for the recording; there is no animated camera movement or timeline of layout changes. Its last setup is remembered for the next recording. Camera controls are locked once recording starts.

After recording, choose **Modifier** on the thumbnail to open the video editor. Camera and audio sources are retained as separate tracks in the original MOV; click and shortcut indicators are stored as event metadata. Only special keys and Command shortcuts receive labels; ordinary typed text is not recorded as keyboard events. Screen video still contains whatever is visibly displayed. Sources not selected at recording time cannot be added later.

Recent originals are stored under `~/Library/Application Support/ArtShot X/`. Image annotations and video edit choices are session-local; exported PNGs and MP4s contain the applied edits. The menu offers recent captures and a Finder shortcut to local storage.

## Development and distribution

The build script creates an app signed locally with an ad-hoc signature by default. It is not a notarized distribution build. Ad-hoc rebuilds can invalidate macOS capture permissions even while the Settings switch remains enabled. To reuse an existing stable development signing identity, set `ARTSHOT_SIGNING_IDENTITY` when running the build script; the script does not create or install certificates.

Automated checks cover geometry, image editing, stitching, persistence, camera shapes/placement, overlay controls and video export. Earlier version 0.2.0 acceptance verified a native-resolution screenshot and a recording with camera, system audio and microphone, followed by MP4 export. The new 0.3.0 live camera setup and compact recording bar still require hardware acceptance. Multi-display behavior, audiovisual synchronization and live scrolling also need broader acceptance.

Processing stays on your Mac. There are no accounts, uploads, analytics or remote services. Private reference media and research notes are excluded from this repository.

See [architecture](docs/architecture.md) and [testing](docs/testing.md).

## License

MIT. ArtShot X is independent and is not affiliated with CleanShot.
