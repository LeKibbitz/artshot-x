# ArtShot X

A local, open-source screenshot utility for macOS. Built from scratch with Swift, AppKit and ScreenCaptureKit.

## First preview

- Capture the display under your pointer or select a region.
- Open a captured image in a native preview.
- Copy or save a PNG, with basic arrows and rectangles.
- Open existing images without screen capture permission.
- Menu bar commands and independent keyboard shortcuts.

This is an early preview. Screen recording, GIF export, scrolling capture, OCR and persistent history are not included yet.

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode or Command Line Tools). There are no third-party dependencies.

```sh
bash scripts/test.sh
bash scripts/test-preview.sh
bash scripts/build.sh
open "dist/ArtShot X.app"
```

The app appears in the menu bar and opens its capture panel. Grant **Screen & System Audio Recording** access in macOS Privacy & Security when prompted, then relaunch the app if macOS requests it. Existing images can be opened without this permission.

For an immediate editor test, click **Essayer une image**. Draw an arrow or rectangle, undo with Command-Z, copy with Command-C or save a PNG with Command-S.

| Shortcut | Action |
| --- | --- |
| Control + Option + Command + 5 | Capture a display |
| Control + Option + Command + 6 | Select a region |
| Control + Option + Command + 7 | Open the capture panel |

These shortcuts intentionally differ from existing screenshot tools. If registration fails, the menu bar and panel commands remain available. ArtShot X does not change macOS shortcuts or disable other applications.

Select a region by dragging. Press Return to confirm or Escape to cancel. The capture stays on the display where selection began.

## Development and distribution

The build script creates an app signed locally with an ad-hoc signature. It is not a notarized distribution build. Build from source for this preview; a signed release pipeline will be added separately.

Screen and image processing happen on your Mac. There are no accounts, uploads, analytics or remote services. Private reference media and research notes are excluded from this repository.

See [architecture](docs/architecture.md) and [testing](docs/testing.md).

## License

MIT. ArtShot X is an independent project and is not affiliated with CleanShot.
