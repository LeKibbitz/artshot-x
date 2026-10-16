# Native capture preview

The first slice implements a complete local image workflow: command → display/region selection → screenshot → editable preview → clipboard/PNG.

| Layer | Choice | Reason |
| --- | --- | --- |
| Application | Swift Package executable, AppKit | Menu bar and transient native windows; builds without an Xcode project. |
| Capture | ScreenCaptureKit / SCScreenshotManager | Public macOS 14+ screenshot APIs; explicit display targeting. |
| Selection | Transparent AppKit overlay | Keyboard cancellation and accurate display-local geometry. |
| Editing | AppKit image canvas | Original pixels retained; annotations flattened at export. |
| Shortcuts | Carbon RegisterEventHotKey | Global commands without keyboard event surveillance. |
| Storage | User-selected PNG files | No database, server, login or background upload. |
| Tests | Swift XCTest | Display geometry, clipping, coordinate origin and Retina scaling. |

All UI ownership is on the main actor. The coordinator serializes capture requests. Region rectangles use global AppKit coordinates (origin at the bottom left); the capture layer converts into display-local coordinates and pixels. Selection is limited to a single display per capture.

The capture service excludes the current application from ScreenCaptureKit content. The coordinator hides its windows before capture and opens a new preview on completion. Cancellation does not create an image. Missing screen access is surfaced with a route to the relevant system settings; the application never changes permissions itself.

Each preview owns an immutable source image and in-memory annotations. Copy and save render annotations into a new image. Closing an unsaved preview discards this in-memory session. A versioned project format and persistent history are later work.

No HTTP endpoints or SQL schema are needed for this local slice. The domain boundaries are CaptureService, SelectionOverlayController, PreviewWindowController and the application coordinator.

## Next slices

1. Harden display changes, window capture, shortcut configuration and exports.
2. Add OCR and durable local history.
3. Add screen recording with explicit media source permissions and recovery.
4. Research scrolling capture independently.

The three main risks are permissions and display geometry, high-resolution rendering, and future audiovisual synchronization.
