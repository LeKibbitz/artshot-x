# Testing ArtShot X 0.5.0 · build 6

## Automated checks

```sh
bash scripts/test.sh
bash scripts/test-preview.sh
bash scripts/test-recording.sh
bash scripts/test-library.sh
bash scripts/test-capture-ui.sh
bash scripts/test-recording-overlays.sh
bash scripts/test-recording-controls.sh
bash scripts/test-recording-edit.sh
bash scripts/test-video-editor.sh
bash scripts/build.sh
```

- `test.sh` runs Swift Testing geometry and stitching tests. Geometry covers clipping, coordinate origins, negative display positions and Retina alignment. Stitching covers downward offsets, duplicates, fixed headings, fixed-footer rejection, missing overlap, ambiguous patterns, sparse text and malformed frames.
- `test-preview.sh` uses synthetic AppKit images and events to check native pixel dimensions, orientation, arrow/rectangle export, numbered-step placement and legibility, mixed-tool undo, numbering reuse, resize/export consistency, the toolbar and native fullscreen configuration. It does not show a capture window, request capture access or touch the clipboard.
- `test-recording.sh` generates synthetic video/audio tracks and exercises composition, trimming, source toggles, camera timing, rendered click/shortcut effects, MP4 output, replacement of an existing destination and preservation of the original. Camera regressions check circle/square/rounded/vertical-oval masks, centered 1×–3× zoom, legacy JSON without zoom, aspect fill without mirroring, normalized size/position, fixed-layout metadata, matching playback/export pixels and compatibility with older metadata. Audio checks decode the exported stream to verify both synthetic tones are mixed into one AAC track and that source toggles are respected. It also checks that ordinary typed text has no shortcut label and that Command labels respect keyboard layout. The pause harness also exercises a real AVAssetWriter with 75 screen/camera frames over 2.5 active seconds, delayed callbacks, pause before the first frame, stop while paused and compressed event timing. PCM checks compare exact interleaved/planar stereo sample contents across pause boundaries; spectral checks verify active 440/880 Hz tones survive while a 2000 Hz pause-only tone is absent from both the MOV and mixed MP4. It does not use ScreenCaptureKit, a physical camera or a microphone.
- `test-library.sh` checks complete history, chronological ordering, native PNG resolution, persistence across new library instances, targeted removal from the index, latest-image fallback and compatibility with the older `latest.json` format. It uses an isolated temporary directory and does not exercise moving user files to Trash.
- `test-capture-ui.sh` briefly presents synthetic AppKit content and checks thumbnail placement, layout, nonactivation, action routing, video copy disablement, save feedback and capture-menu states. It does not capture the screen or exercise global keyboard delivery.
- `test-recording-overlays.sh` uses synthetic AppKit images/events to exercise camera shapes and clipping, aspect fill, placeholder drawing, top-left/AppKit positioning, drag/clamp behavior and locked mouse pass-through. It also checks the Stop/Pause/Restart/Trash order, right-hand drag handle, Pause-to-Resume icon/label transition, all four callbacks, disabled finalization controls, an untruncated hour-scale timer, keyboard navigation, nonactivation and preserved placement. It requires a macOS login session and does not open physical camera hardware or record a screen.
- `test-recording-controls.sh` compiles the actual app controller and checks options layout, shortcut routing between preparation and recording, recorded-time labels, Pause/Resume states, disabled transition/finalization controls, cancellation of automatic restart when quitting, and cleanup without accessing camera hardware.
- `test-recording-edit.sh` exports low-amplitude synthetic tones and decodes the AAC to measure 50/100/200% gain and independent source mute. It verifies overlapping internal removals, removal-only tone exclusion, source/output mapping, full-removal rejection, camera gaps, clipped event lifetimes and byte-for-byte preservation of the original.
- `test-video-editor.sh` requires `ffmpeg` on PATH and a macOS login session. It creates synthetic media, exercises the actual controller's gains, passage removal/undo, playhead mapping, preparation locking and playback resumption, and checks visible controls at the initial/minimum window sizes. Its snapshot contains only the synthetic test window. It checks fullscreen capability, not a physical fullscreen transition.
- `build.sh` builds the app bundle, applies an ad-hoc signature and verifies that signature. It does not notarize the app or validate macOS permissions.

The Swift Testing harness adds developer framework search paths when required by Command Line Tools. Standalone AppKit/media tests use the host architecture.

These checks use synthetic inputs. They do not establish that live screen recording, microphone/system audio capture, camera input, global event monitoring or hardware synchronization works on a particular Mac.

## Manual acceptance still required

1. Launch and relaunch the app. Confirm only its menu bar icon appears until a command is chosen. Test Command–Option–Shift–5/6/7 on AZERTY and QWERTY; verify menu access when a hotkey is already registered by another app. During recording, shortcut 7 must reveal the floating remote rather than the capture panel.
2. Open an existing image or the sample. Add arrows, rectangles and numbered steps; undo across tools. Resize and enter/leave native fullscreen. Copy and save a PNG, then inspect it in another app.
3. Request a screenshot without screen access. Confirm the permission message and absence of a bogus result. Grant access, relaunch if requested, and capture a display and a region. Check Return, Escape and redraw behavior.
4. Confirm the thumbnail appears at the bottom left without stealing focus. Exercise edit, PNG save, copy and delete. Relaunch and reopen recent images/videos. Confirm deletion sends the app-owned original to Trash and that externally opened files remain intact.
5. Test a secondary display to the left/below the primary display, mixed Retina scales, and a display disconnect during selection/capture. Compare exported pixel dimensions and selected regions.
6. Select a static scrolling document. Scroll downward in small increments with pauses, then finish. Inspect every seam and the last movement. Test no movement, cancellation, a fixed heading, repeated patterns, a large jump, upward motion and a fixed footer; uncertain matches must produce an error or recovery state rather than a corrupt image.
7. Record a display and a region with optional sources disabled. Stop from both the floating controls and menu. Inspect the thumbnail and original, edit a trim and export an MP4. Test cancellation during startup and recording, and quitting during recording/finalization.
8. Enable the live camera before starting. Confirm a real image appears, then test circle, square, rounded rectangle and vertical oval, 1×–3× centered zoom, 12–45% size, all four edges and drag clamping within a region. Start recording and verify that camera shape/size/position/zoom stay fixed, clicks reach the app underneath, and the on-screen crop/position matches playback and MP4 export. Move the remote using its right-hand handle and reveal it with shortcut 7 without moving the camera. Check that the last camera setup returns for the next recording.
9. Enable camera, microphone and system audio individually, then together. Exercise permission refusal, missing/busy devices, rapid camera toggle, cancellation while permission/startup is pending, silence and device disconnection. Check that cancellation/closing options stops the camera and that no old callback affects the next recording. Check speech/visual synchronization and output duration on real hardware; confirm usable screen footage is preserved if an optional source provides no samples.
10. Enable click and shortcut indicators. Test Accessibility refusal/approval, click placement inside a selected region, special keys, AZERTY Command shortcuts and ordinary typing. Toggle effects and sources in the editor; compare preview with the exported MP4, including effects around trim boundaries. Confirm the cursor stays visible when it was captured.
11. Record, pause for several seconds, then resume repeatedly with camera and both audio sources enabled. Confirm the red timer freezes while paused, and exported screen, camera, audio and click/shortcut times contain no pause gap or stale paused content. Stop while paused and inspect the final duration.
12. Restart while running and while paused. Verify that the previous take appears once in recents without a thumbnail interrupting the new take, the timer resets, and display/region, sources, camera shape/size/position stay identical. Repeat several times, then stop; confirm all archived takes reopen. Exercise camera failure and library-write failure around a restart without losing a completed take.
13. Trash a running and a paused take. Confirm only the current recording project enters macOS Trash, it never appears in recent captures, earlier archived takes remain available, and camera hardware/overlay/remote close. Check cancellation during startup separately.
14. Remove multiple internal passages, including overlapping selections. Check original-time labels, mark-start/end buttons, undo and alignment of camera/audio/click indicators across every splice. Adjust microphone and system sound independently to 0%, 50%, 100%, 150% and 200%, compare playback and MP4, and retain the original.
15. Export over an existing file and attempt to export over the original. Test an invalid trim and an unwritable destination. Failures must preserve existing files. Check that closing an editor during export does not lose a completed recording.

Synthetic tests do not establish live capture or physical media-device acceptance. The user confirmed that the new 0.3.0 live camera thumbnail and shape/size settings are visible on their Mac. The preview-to-recording transition and recording toolbar Stop action also passed a real camera capture. Version 0.4.0 Pause/Resume, Restart and Trash remain pending hardware validation; the earlier recording does not validate those transitions. Physical shortcut 7 delivery during recording remains a separate manual check. Record hardware results separately with the macOS version, display setup, enabled sources and permission state.

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

## 0.3.0 camera setup acceptance — 2026-10-17

On macOS 26.6.2 with the built-in Retina display, the installed app received physical camera frames and enabled Start only after a frame arrived. The user confirmed seeing the live thumbnail and its shape/size controls. No screen/camera test media is published.

A new 18.53-second capture with the final camera pipeline produced independent H.264 screen (1512 × 982) and camera (640 × 480) tracks. The stored fixed camera layout retained the selected circle and 21.2% width. The floating recording bar exposed its running timer, Stop, camera and Cancel actions; Stop finalized the MOV and returned the result thumbnail. Inspecting the raw screen track confirmed that ArtShot X camera/control windows were excluded, avoiding a second baked-in camera overlay.

Real media exposed empty screen-track edits before the first frame. The compositor now checks nonempty segment mappings and pads screen gaps without shifting audio, trim or event times. Regression coverage includes delayed screen start and an audio tail longer than the screen. A full 12.433-second real recording exported to H.264 plus one stereo AAC track, decoded without errors; original media and metadata hashes stayed unchanged.

The fresh 18.53-second camera recording also exported successfully to an 18.567-second H.264 MP4 (30 fps rounding), with no audio because microphone/system audio were disabled for that test. Full decode passed. The installed build 4 binary and the final release build have identical SHA-256 hashes; no further permission reset was needed after this capture.

## 0.4.0 floating remote validation — 2026-10-17

All automated harnesses passed, including the real-writer pause/audio regression suite, the controller lifecycle checks and the AppKit remote layout/callback checks. The release bundle was built and its signature verified, then installed as version 0.4.0 build 5. The previously approved screen-capture authorization reset was applied only to ArtShot X; the installed capture panel then reported access available.

A real screen-only take on the built-in Retina display displayed the new floating remote, with Stop, red elapsed time, Pause, Restart, Trash and a drag handle exposed through accessibility. It produced a valid 2.433-second H.264 MOV at 1512 × 982 with no completion warning. Camera and audio were disabled for this take. Live Pause/Resume, Restart and Trash transitions were not established: the observation tool lost access to the controls before those actions could be verified. Their synthetic coverage does not replace this pending hardware acceptance. No real test media or private diagnostic output is published.

## 0.5.0 editing and camera validation — 2026-10-17

The recording, recording-edit, camera-overlay, recording-controls and video-editor harnesses passed. Decoded 440 Hz amplitude changed from 0.049971 at 100% to 0.099948 at 200%; microphone amplitude changed from 0.049995 to 0.099994. A 50% system setting decoded at 0.024990. Removed intervals' synthetic tones were absent within the test tolerance. Camera tests covered all four masks, fixed outer geometry, centered zoom in live preview and composed output, and older metadata without zoom.

A local copy of the earlier real four-track recording was exported with two internal removals, system gain 60%, microphone gain 170%, and a vertical oval at 2× zoom. The resulting 9.433333-second MP4 contained H.264 video at 1512 × 982 and one stereo AAC stream; full decode completed without errors. Original MOV and sidecar hashes were unchanged. This exercises real recorded media offline, not a new live camera session.

Version 0.5.0 build 6 was installed and signature-verified. The installed and release executables have identical SHA-256 hashes: `89e31e0d7e4ce742b309ef2b778d43a47973cbdec6560f71f458a3751c26c48a`. Only ArtShot X's previously authorized screen-capture permission was renewed; the relaunched capture panel reported access available. New live oval/zoom camera acceptance remains separate from the synthetic geometry/render checks. Private media and screenshots are excluded from Git.
