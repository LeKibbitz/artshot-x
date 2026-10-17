# ArtShot X

A local, open-source screenshot and screen recording utility for macOS. Built with Swift, AppKit and ScreenCaptureKit.

## Version 0.6.2 · build 9

- Open an adjustable selection directly over the current app. Draw, move or resize the region with eight handles, then choose **Photo**, **Défilement** or **Vidéo** from the compact floating bar. **Écran** selects the entire display.
- Capture the display under your pointer or select a region directly with shortcuts 5 and 6.
- Get a floating thumbnail at the bottom left, with **Delete**, **Edit**, **Save** and **Copy** actions. Copy is available for images.
- Annotate images with arrows, rectangles and numbered steps; undo annotations, copy the result or save a PNG.
- Reopen recent screenshots and recordings across app launches. Originals stay on your Mac.
- Stitch a vertical scrolling screenshot while you scroll the underlying app manually. A floating thumbnail shows the entire assembled image and updates as new portions are accepted.
- Record a display or region, optionally with live camera, system audio, microphone, click indicators and shortcut labels.
- Preview the camera before recording; choose a circle, square, rounded rectangle or vertical oval, adjust its size and centered 1×–3× digital zoom, and drag it into position. One fixed layout applies to the entire video.
- Use a floating recording remote with Stop and a red timer, Pause/Resume, Restart, Trash and a drag handle on the right. Command–Option–Shift–7 brings it back during recording.
- Edit a recording by toggling captured sources and effects, trimming its start/end, removing internal passages with undo, adjusting microphone/system volume independently from 0 to 200%, and exporting an MP4 with one mixed audio track. The cursor, when enabled, is baked into the screen video.

The app runs in the background with a menu bar icon. Launching it does not open a panel or editor. The interface is currently in French. GIF export, OCR and window-specific capture are not included.

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode or Command Line Tools). There are no third-party runtime dependencies. The optional video-editor UI test uses `ffmpeg` on PATH.

```sh
bash scripts/test.sh
bash scripts/test-preview.sh
bash scripts/test-recording.sh
bash scripts/test-library.sh
bash scripts/test-capture-ui.sh
bash scripts/test-capture-focus.sh
bash scripts/test-selection-adjustment.sh
bash scripts/test-scrolling-preview.sh
bash scripts/test-scrolling-preview-controller.sh
bash scripts/test-recording-overlays.sh
bash scripts/test-recording-controls.sh
bash scripts/test-recording-edit.sh
bash scripts/test-video-editor.sh
bash scripts/build.sh
open "dist/ArtShot X.app"
```

Open the menu bar icon or use Command–Option–Shift–7. The capture bar stays over the current application and Space, including fullscreen, without activating ArtShot X or raising its editors. Grant screen recording access in macOS Privacy & Security when prompted, then relaunch if macOS requests it. Camera and microphone permissions are requested only when selected. Click and shortcut overlays require Accessibility access. Existing images and the sample editor work without screen capture permission.

| Shortcut | Action |
| --- | --- |
| Command + Option + Shift + 5 | Capture a display |
| Command + Option + Shift + 6 | Select a region |
| Command + Option + Shift + 7 | Draw and adjust a capture region, or reveal the active recording bar |

The shortcuts use physical number-row keys on AZERTY and QWERTY. If a shortcut conflicts, menu bar and panel commands remain available. ArtShot X does not change macOS shortcuts or disable other apps.

With shortcut 7, draw a rectangle immediately. Release the mouse to enable the actions; no Return confirmation is needed. Drag inside the selection to move it, or use its eight handles to resize it. The selection stays adjustable until you choose **Photo**, **Défilement** or **Vidéo**; each action uses the latest region. **Écran** selects the entire display without drawing, and **Zone** clears it for a new rectangle. Video opens recording options with the area already selected. The **Plus** menu contains recent media and image-opening commands; the information button shows permissions and shortcut issues. Close or Escape dismisses preparation.

With shortcut 6, drag to select, press Return to capture directly or Escape to cancel. Selection stays on one display. For a scrolling capture, select the document content, scroll downward in small increments and pause after each increment. The floating preview appears with the first image, then shrinks to keep the complete growing capture visible. It updates after each accepted scroll position. Drag the panel if it covers content you need. Click **Terminer** to save the assembled capture or **Annuler** to cancel. Uncertain alignment, upward scrolling and fixed footers are rejected. Limits are 20,000 pixels of height, 32 million pixels and 200 captured positions.

Enable the camera in the recording options to see its live preview. Choose its shape, size and zoom, then drag it within the selected display or region. The vertical oval has a 3:4 frame; digital zoom crops the camera image centrally without resizing or moving that frame. The setting is saved as a single layout for the recording; there is no animated camera movement or timeline of layout changes. Its last setup is remembered for the next recording. Camera controls are locked once recording starts.

The timer counts recorded time and stops while paused. Resume continues the same take without keeping the paused interval in the recording. Restart saves the previous take in recent captures and starts a new take from zero with the same display/region, sources and fixed camera layout. The live camera session stays available between takes. Trash ends the current take and moves its recording project to macOS Trash without adding it to history; earlier saved takes are retained.

After recording, choose **Modifier** on the thumbnail to open the video editor. Camera and audio sources are retained as separate tracks in the original MOV; click and shortcut indicators are stored as event metadata. Only special keys and Command shortcuts receive labels; ordinary typed text is not recorded as keyboard events. Screen video still contains whatever is visibly displayed. Sources not selected at recording time cannot be added later.

In the video editor, **Son du Mac** and **Microphone** each have a 0–200% volume slider: 0 mutes, 100% preserves the recorded level, and 200% doubles the signal amplitude. High gains can clip loud recordings. The player and MP4 use the same settings. To remove a passage, move playback to its start and click **Début ici**, then to its end and click **Fin ici**, followed by **Retirer ce passage**. You can also enter times directly, in original-video seconds. Repeat for multiple cuts; **Annuler le retrait** restores the last removal. The retained screen, camera, sound and indicators move together. **Enregistrer MP4…** writes the result without replacing the original.

Recent originals are stored under `~/Library/Application Support/ArtShot X/`. Image annotations and video edit choices are session-local; exported PNGs and MP4s contain the applied edits. The menu offers recent captures and a Finder shortcut to local storage.

## Development and distribution

The build script creates an app signed locally with an ad-hoc signature by default. It is not a notarized distribution build. Ad-hoc rebuilds can invalidate macOS capture permissions even while the Settings switch remains enabled. To reuse an existing stable development signing identity, set `ARTSHOT_SIGNING_IDENTITY` when running the build script; the script does not create or install certificates.

Automated checks cover geometry, image editing, stitching, persistence, camera shapes/placement, overlay controls and video export. Earlier version 0.2.0 acceptance verified a native-resolution screenshot and a recording with camera, system audio and microphone, followed by MP4 export. Version 0.3.0 acceptance confirmed the live camera thumbnail and its controls, plus an 18.53-second screen/camera take stopped through the toolbar. The new 0.4.0 Pause/Resume, Restart and Trash workflows still require hardware acceptance. Multi-display behavior, audiovisual synchronization and live scrolling also need broader acceptance.

Processing stays on your Mac. There are no accounts, uploads, analytics or remote services. Private reference media and research notes are excluded from this repository.

See [architecture](docs/architecture.md) and [testing](docs/testing.md).

## License

MIT. ArtShot X is independent and is not affiliated with CleanShot.
