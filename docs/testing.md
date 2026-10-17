# Testing ArtShot X 0.3.0 · build 3

## Automated checks

```sh
bash scripts/test.sh
bash scripts/test-preview.sh
bash scripts/test-recording.sh
bash scripts/test-library.sh
bash scripts/test-capture-ui.sh
bash scripts/test-recording-overlays.sh
bash scripts/test-recording-controls.sh
bash scripts/build.sh
```

- `test.sh` runs Swift Testing geometry and stitching tests. Geometry covers clipping, coordinate origins, negative display positions and Retina alignment. Stitching covers downward offsets, duplicates, fixed headings, fixed-footer rejection, missing overlap, ambiguous patterns, sparse text and malformed frames.
- `test-preview.sh` uses synthetic AppKit images and events to check native pixel dimensions, orientation, arrow/rectangle export, numbered-step placement and legibility, mixed-tool undo, numbering reuse, resize/export consistency, the toolbar and native fullscreen configuration. It does not show a capture window, request capture access or touch the clipboard.
- `test-recording.sh` generates synthetic video/audio tracks and exercises composition, trimming, source toggles, camera timing, rendered click/shortcut effects, MP4 output, replacement of an existing destination and preservation of the original. Camera regressions check circle/square/rounded masks, aspect fill without mirroring, normalized size/position, fixed-layout metadata, matching playback/export pixels and compatibility with older metadata. Audio checks decode the exported stream to verify both synthetic tones are mixed into one AAC track and that source toggles are respected. It also checks that ordinary typed text has no shortcut label and that Command labels respect keyboard layout. It does not use ScreenCaptureKit, a physical camera or a microphone.
- `test-library.sh` checks complete history, chronological ordering, native PNG resolution, persistence across new library instances, targeted removal from the index, latest-image fallback and compatibility with the older `latest.json` format. It uses an isolated temporary directory and does not exercise moving user files to Trash.
- `test-capture-ui.sh` briefly presents synthetic AppKit content and checks thumbnail placement, layout, nonactivation, action routing, video copy disablement, save feedback and capture-menu states. It does not capture the screen or exercise global keyboard delivery.
- `test-recording-overlays.sh` uses synthetic AppKit images/events to exercise camera shapes and clipping, aspect fill, placeholder drawing, top-left/AppKit positioning, drag/clamp behavior and locked mouse pass-through. It also checks compact bar layout, states, callbacks, nonactivation and closing. It requires a macOS login session and does not open physical camera hardware or record a screen.
- `build.sh` builds the app bundle, applies an ad-hoc signature and verifies that signature. It does not notarize the app or validate macOS permissions.

The Swift Testing harness adds developer framework search paths when required by Command Line Tools. Standalone AppKit/media tests use the host architecture.

These checks use synthetic inputs. They do not establish that live screen recording, microphone/system audio capture, camera input, global event monitoring or hardware synchronization works on a particular Mac.

- `test-recording-controls.sh` compiles the actual app controller and checks options layout, shortcut routing between preparation and recording, disabled finalization controls and cleanup without accessing camera hardware.

## Manual acceptance still required

1. Launch and relaunch the app. Confirm only its menu bar icon appears until a command is chosen. Test Command–Option–Shift–5/6/7 on AZERTY and QWERTY; verify menu access when a hotkey is already registered by another app. During recording, shortcut 7 must reveal the horizontal recording bar rather than the capture panel.
2. Open an existing image or the sample. Add arrows, rectangles and numbered steps; undo across tools. Resize and enter/leave native fullscreen. Copy and save a PNG, then inspect it in another app.
3. Request a screenshot without screen access. Confirm the permission message and absence of a bogus result. Grant access, relaunch if requested, and capture a display and a region. Check Return, Escape and redraw behavior.
4. Confirm the thumbnail appears at the bottom left without stealing focus. Exercise edit, PNG save, copy and delete. Relaunch and reopen recent images/videos. Confirm deletion sends the app-owned original to Trash and that externally opened files remain intact.
5. Test a secondary display to the left/below the primary display, mixed Retina scales, and a display disconnect during selection/capture. Compare exported pixel dimensions and selected regions.
6. Select a static scrolling document. Scroll downward in small increments with pauses, then finish. Inspect every seam and the last movement. Test no movement, cancellation, a fixed heading, repeated patterns, a large jump, upward motion and a fixed footer; uncertain matches must produce an error or recovery state rather than a corrupt image.
7. Record a display and a region with optional sources disabled. Stop from both the floating controls and menu. Inspect the thumbnail and original, edit a trim and export an MP4. Test cancellation during startup and recording, and quitting during recording/finalization.
8. Enable the live camera before starting. Confirm a real image appears, then test circle, square and rounded rectangle, 12–45% size, all four edges and drag clamping within a region. Start recording and verify that camera shape/size/position stay fixed, clicks reach the app underneath, and the on-screen crop/position matches playback and MP4 export. Move/reveal the recording bar with shortcut 7 without moving the camera. Check that the last camera setup returns for the next recording.
9. Enable camera, microphone and system audio individually, then together. Exercise permission refusal, missing/busy devices, rapid camera toggle, cancellation while permission/startup is pending, silence and device disconnection. Check that cancellation/closing options stops the camera and that no old callback affects the next recording. Check speech/visual synchronization and output duration on real hardware; confirm usable screen footage is preserved if an optional source provides no samples.
10. Enable click and shortcut indicators. Test Accessibility refusal/approval, click placement inside a selected region, special keys, AZERTY Command shortcuts and ordinary typing. Toggle effects and sources in the editor; compare preview with the exported MP4, including effects around trim boundaries. Confirm the cursor stays visible when it was captured.
11. Export over an existing file and attempt to export over the original. Test an invalid trim and an unwritable destination. Failures must preserve existing files. Check that closing an editor during export does not lose a completed recording.

Synthetic tests do not establish live capture or physical media-device acceptance. The new 0.3.0 camera setup, preview-to-recording lifecycle and recording bar remain pending hardware validation; the earlier 0.2.0 acceptance below does not validate these additions. Record hardware results separately with the macOS version, display setup, enabled sources and permission state.

Copy changes the system clipboard only on request. Save/export uses a native save panel. Captures stay local.

## Earlier 0.2.0 local validation — 2026-10-17

The 16 geometry/stitching tests and the preview, recording, library and capture-UI harnesses passed. The recording harness also exercised interrupted stream finalization and sidecar-write failure against a real AVAssetWriter, preserving valid MOV output. The release app was installed at `~/Applications/ArtShot X.app` and its signature verified.

The installed capture panel was inspected through macOS accessibility and screenshot tools: capture, region, scrolling, recording, recent media and permission actions were visible, and no hotkey registration failure was reported. This establishes successful registration, not physical key delivery. The changed ad-hoc signature left macOS showing screen recording enabled while both the preflight check and a real ScreenCaptureKit recording attempt were denied by TCC. Reauthorization of the installed bundle is required. No live capture success or physical camera/microphone acceptance is claimed.

For a developer UI check, launch the executable with `--show-capture-panel`. Normal launch has no window.

## Earlier 0.2.0 capture acceptance — 2026-10-17

After the user authorized replacing only the ArtShot X screen-recording entry and authenticated with Touch ID, the installed app was re-added and relaunched. A real display capture produced a 3024 × 1964 PNG and the lower-left thumbnail with Delete/Edit/Save/Copy actions. The user confirmed the three physical shortcuts (Command–Option–Shift–5/6/7).

A real 12.43-second MOV contained H.264 screen footage at 1512 × 982, H.264 camera footage at 640 × 480, system audio (stereo AAC), microphone audio (mono AAC) and click metadata. All four media tracks decoded without errors. This confirms received media and usable files; subjective sound quality and audiovisual synchronization were not measured.

The live export exposed a compatibility issue: separate system/microphone MP4 tracks could cause a player to select only one source. Export now uses an explicit audio mix, preserving separate sources only in the original MOV. Regression tests verify that system 440 Hz and microphone 880 Hz tones coexist in one exported AAC stream, and that system-only, microphone-only and silent exports respect the toggles. Re-exporting the real recording yielded a 12.433333-second MP4 with one H.264 video stream and one stereo AAC stream, decoded without errors.

The corrected binary was installed and its capture authorization renewed. A subsequent real PNG capture succeeded. Test recordings and exports remain local and are excluded from Git.
