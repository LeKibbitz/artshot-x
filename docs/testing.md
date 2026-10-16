# Testing the preview

## Automated

```sh
bash scripts/test.sh
bash scripts/test-preview.sh
bash scripts/build.sh
```

Geometry tests check screen-coordinate conversion, clipping, negative display origins and pixel scale. Build verification includes the local app signature. These checks do not grant or simulate screen recording access.

The AppKit smoke harness checks native pixel dimensions, asymmetric image orientation, arrow/rectangle export, undo and empty-image errors without touching the clipboard or opening a window.

The test script uses Swift Testing included with Swift 6 and adds the developer framework search path when required by Command Line Tools. A full Xcode installation is not required.

## Manual acceptance

1. Launch the app and open an existing image. Confirm preview, arrow/rectangle, undo, copy and PNG save.
2. Without screen access, request a screenshot. Confirm a clear permission message and no empty output.
3. Grant access in macOS, relaunch if required, and capture a display. Confirm the correct display and original resolution.
4. Start a region capture, draw a rectangle, adjust it by drawing again, and press Return. Confirm the exported region and dimensions.
5. Repeat and press Escape. Confirm no output window opens.
6. Test on a second display, including a display positioned left of or below the primary one and mixed Retina scales.
7. Try a conflicting shortcut. Menu and panel actions must remain usable.
8. Save an annotated image and reopen it elsewhere. Confirm annotations match the preview and the source resolution is preserved.

Copy overwrites the system clipboard only when the user requests it. Save uses a normal save panel. No capture is uploaded.

## First preview validation

On 2026-10-16, the release app built and passed local signature verification with Swift 6.3.3 on Apple Silicon. All 6 geometry tests and the AppKit export smoke harness passed. The installed app was launched; its sample image, arrow/rectangle controls, undo button and PNG save panel were exercised. The saved PNG retained its 2000 × 1300 pixel dimensions.

Screen capture authorization had not yet been granted to this new app. Live display/region capture, keyboard shortcuts, clipboard interoperability and a physical multi-display setup still require manual acceptance. The UI is an early preview, not a completed feature-parity release.

The native full-screen fix was subsequently verified in a separate app instance: the preview's accessibility control changed from a zoom button to a full-screen button, clicking it entered full-screen mode, and Control-Command-F returned to the original window size. The AppKit smoke harness and release build still passed. The capture panel remains a fixed-size utility window.
