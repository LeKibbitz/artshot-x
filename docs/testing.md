# Testing ArtShot X 0.2.0

## Automated checks

```sh
bash scripts/test.sh
bash scripts/test-preview.sh
bash scripts/test-recording.sh
bash scripts/test-library.sh
bash scripts/test-capture-ui.sh
bash scripts/build.sh
```

- `test.sh` runs Swift Testing geometry and stitching tests. Geometry covers clipping, coordinate origins, negative display positions and Retina alignment. Stitching covers downward offsets, duplicates, fixed headings, fixed-footer rejection, missing overlap, ambiguous patterns, sparse text and malformed frames.
- `test-preview.sh` uses synthetic AppKit images and events to check native pixel dimensions, orientation, arrow/rectangle export, numbered-step placement and legibility, mixed-tool undo, numbering reuse, resize/export consistency, the toolbar and native fullscreen configuration. It does not show a capture window, request capture access or touch the clipboard.
- `test-recording.sh` generates synthetic video/audio tracks and exercises composition, trimming, source toggles, camera timing, rendered click/shortcut effects, MP4 output, replacement of an existing destination and preservation of the original. It also checks that ordinary typed text has no shortcut label and that Command labels respect keyboard layout. It does not use ScreenCaptureKit, a physical camera or a microphone.
- `test-library.sh` checks complete history, chronological ordering, native PNG resolution, persistence across new library instances, targeted removal from the index, latest-image fallback and compatibility with the older `latest.json` format. It uses an isolated temporary directory and does not exercise moving user files to Trash.
- `test-capture-ui.sh` briefly presents synthetic AppKit content and checks thumbnail placement, layout, nonactivation, action routing, video copy disablement, save feedback and capture-menu states. It does not capture the screen or exercise global keyboard delivery.
- `build.sh` builds the app bundle, applies an ad-hoc signature and verifies that signature. It does not notarize the app or validate macOS permissions.

The Swift Testing harness adds developer framework search paths when required by Command Line Tools. Standalone AppKit/media tests use the host architecture.

These checks use synthetic inputs. They do not establish that live screen recording, microphone/system audio capture, camera input, global event monitoring or hardware synchronization works on a particular Mac.

## Manual acceptance still required

1. Launch and relaunch the app. Confirm only its menu bar icon appears until a command is chosen. Test Command–Option–Shift–5/6/7 on AZERTY and QWERTY; verify menu access when a hotkey is already registered by another app.
2. Open an existing image or the sample. Add arrows, rectangles and numbered steps; undo across tools. Resize and enter/leave native fullscreen. Copy and save a PNG, then inspect it in another app.
3. Request a screenshot without screen access. Confirm the permission message and absence of a bogus result. Grant access, relaunch if requested, and capture a display and a region. Check Return, Escape and redraw behavior.
4. Confirm the thumbnail appears at the bottom left without stealing focus. Exercise edit, PNG save, copy and delete. Relaunch and reopen recent images/videos. Confirm deletion sends the app-owned original to Trash and that externally opened files remain intact.
5. Test a secondary display to the left/below the primary display, mixed Retina scales, and a display disconnect during selection/capture. Compare exported pixel dimensions and selected regions.
6. Select a static scrolling document. Scroll downward in small increments with pauses, then finish. Inspect every seam and the last movement. Test no movement, cancellation, a fixed heading, repeated patterns, a large jump, upward motion and a fixed footer; uncertain matches must produce an error or recovery state rather than a corrupt image.
7. Record a display and a region with optional sources disabled. Stop from both the floating controls and menu. Inspect the thumbnail and original, edit a trim and export an MP4. Test cancellation during startup and recording, and quitting during recording/finalization.
8. Enable camera, microphone and system audio individually, then together. Exercise permission refusal, missing/busy devices, silence and device disconnection. Check speech/visual synchronization and output duration on real hardware; confirm usable screen footage is preserved if an optional source provides no samples.
9. Enable click and shortcut indicators. Test Accessibility refusal/approval, click placement inside a selected region, special keys, AZERTY Command shortcuts and ordinary typing. Toggle effects and sources in the editor; compare preview with the exported MP4, including effects around trim boundaries. Confirm the cursor stays visible when it was captured.
10. Export over an existing file and attempt to export over the original. Test an invalid trim and an unwritable destination. Failures must preserve existing files. Check that closing an editor during export does not lose a completed recording.

No live capture or physical media-device acceptance is claimed for version 0.2.0 by the synthetic test suite. Record hardware results separately with the macOS version, display setup, enabled sources and permission state.

Copy changes the system clipboard only on request. Save/export uses a native save panel. Captures stay local.

## Local validation — 2026-10-17

The 16 geometry/stitching tests and the preview, recording, library and capture-UI harnesses passed. The recording harness also exercised interrupted stream finalization and sidecar-write failure against a real AVAssetWriter, preserving valid MOV output. The release app was installed at `~/Applications/ArtShot X.app` and its signature verified.

The installed capture panel was inspected through macOS accessibility and screenshot tools: capture, region, scrolling, recording, recent media and permission actions were visible, and no hotkey registration failure was reported. This establishes successful registration, not physical key delivery. The changed ad-hoc signature required screen-recording reauthorization; real captures and physical camera/microphone checks remain pending.

For a developer UI check, launch the executable with `--show-capture-panel`. Normal launch has no window.
