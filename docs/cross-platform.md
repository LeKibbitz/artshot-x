# macOS and Windows 11 direction

Date: 2026-10-18.

## Product decision and current status

ArtShot X targets macOS and Windows 11. Windows 10 is outside the requested scope. The first Windows package will be a preview distributed to external testers; no physical Windows test machine is currently available to this development session.

Version 0.6.2 is still a macOS-only Swift/AppKit application. No Windows executable or installer exists yet. This document records the target architecture and migration sequence, not implemented Windows support.

## Required final deliverables

The finished product must be downloadable and installable by ordinary users. Source code, build scripts or a successful CI build alone do not satisfy delivery.

- **macOS:** a versioned `.dmg` containing ArtShot X, installable into Applications.
- **Windows 11:** a versioned `.exe` setup installer with an application entry, shortcuts and an uninstall entry.
- Publish both artifacts on GitHub Releases with the supported OS/CPU architectures, version, checksums and short installation instructions.
- Installation and normal use must require no terminal, compiler, Rust, Node.js, Xcode or other development tools. The installer must handle required runtime dependencies.
- Verify download, installation, first launch, permission onboarding, the supported capture/edit/export flows, upgrade from the previous preview and removal of the application on each target OS. Upgrades must preserve local captures and settings.
- Validate the distributed packages, not only development builds. Record signing/notarization status accurately; establish release signing identities before claiming a signed public distribution.

Early previews may contain a clearly stated subset of features. They do not count as the finished product until the agreed capture, scrolling, recording and editing scope has passed acceptance on both systems. Windows hardware acceptance will use external testers as agreed.

## Target architecture

| Area | Choice | Reason |
| --- | --- | --- |
| Shared domain and image processing | Rust | Share capture/project models, geometry, scrolling alignment, annotation operations and edit decisions across systems. |
| Shared editor, library and settings | TypeScript/React with Tauri 2 | Share the ordinary application interface while calling local Rust commands. |
| macOS capture and transient overlays | ScreenCaptureKit, AVFoundation and AppKit, retaining a Swift adapter where useful | Preserve integration with screen permissions, system audio, camera, Spaces and nonactivating windows. |
| Windows capture and transient overlays | Windows Graphics Capture and Win32 through Microsoft's Rust bindings | Use native display/window capture, global shortcuts, DPI information and capture-window exclusion. |
| Windows audio | WASAPI loopback for system output, separate microphone capture | Keep microphone and system sound separately editable. |
| Storage | Local files and a versioned project manifest | Preserve originals, require no account and keep media on the user's computer. |
| Packaging | Platform-specific macOS bundle and Windows installer | Compile and test each system's actual backend. |

The editor can be shared; the selection overlay, recording remote and camera overlay must prove their behavior on each operating system. Tauri does not itself provide screen recording, scroll stitching, synchronized audio or a guarantee of nonactivation over fullscreen apps.

Capture frames remain in native buffers/files. Do not send live video frames as JSON or base64 through the web interface. Commands carry intent, identifiers and metadata; the interface accesses only authorized local preview resources. The capture layer must exclude ArtShot windows independently of whether those windows are implemented natively or with a webview.

Rust does not remove OS permissions or automatically port Apple media APIs. Windows rendering and MP4 export require their own media implementation or a separately validated shared media engine. That implementation choice must be established with real multi-source recordings before promising video parity.

## Existing work to preserve

- Keep the installed Swift application and its capture/recording flows working during migration.
- Port and compare `ScrollStitcher` against the existing synthetic test vectors.
- Normalize coordinate origins, display IDs and physical pixels explicitly; do not copy AppKit's global bottom-left convention into Windows.
- Separate the timing/cut/layout mathematics from `CMSampleBuffer`, `CGImage` and other Apple objects before sharing it.
- Treat current camera layouts, passage removals, source volumes and originals as compatibility requirements. Never rewrite existing recording projects during an experiment.
- Keep existing Swift UI tests as behavior references for handles, focus, thumbnail actions and recording controls.

## Delivery order and acceptance gates

### 1. Prove native capture on both systems

Create a separate development app identity so it cannot replace the installed Mac app or reset its permissions. Establish Rust/Tauri build prerequisites and a Windows CI build. Validate display enumeration, physical pixel dimensions, multi-monitor origins, exclusion of the app's own windows and capture error reporting on both systems.

### 2. First Windows preview: screenshot to annotated PNG

Complete one useful flow before adding recording:

1. Launch silently in the tray/menu bar and invoke a global capture command (S01).
2. Select and adjust a region without switching the source application (S03/S04), or capture the whole display.
3. Show a floating result with Delete, Edit, Save and Copy (S06/S09).
4. Open the shared image editor with arrow, rectangle and numbered steps, plus undo (S07).
5. Save/copy a correctly sized PNG and reopen the original from the local library (S11).

Windows shortcut mappings must be checked for conflicts, keyboard layout and accessibility. Do not assume replacing Command with the Windows key will work for every combination. The preview must name its supported commands and report registration failures.

Generate a Windows installer only after the Windows build and automated tests pass. Label the first package as a preview with explicit supported functions. An external tester must then verify installation, capture, focus, clipboard, PNG saving and reopening on a physical Windows 11 session. CI cannot establish interactive desktop capture, GPU, camera or audio behavior.

### 3. Scrolling capture

Reuse the common alignment engine and add native frame acquisition. Verify the complete-image thumbnail, accepted/rejected positions, finish/cancel behavior and PNG seams on real scrolling documents (S12). Retain conservative rejection of unreliable alignments.

### 4. Recording and editing parity

Add display/region video first, then independent system/microphone audio, camera with shape/size/centered zoom, cursor/click/shortcut effects, pause/resume and the floating remote (S14). Validate a common recording-project contract and the media backend before adding source toggles, gain, passage removal, undo and MP4 export. Screen, camera, audio and event metadata must remain synchronized across pauses and cuts.

Linux is not part of this requested milestone. The shared design must not imply that its screen capture backend already exists.

## Tests and release evidence

| Layer | Evidence required |
| --- | --- |
| Shared Rust code | Unit/property or fixture tests on macOS and Windows, including malformed inputs and parity with existing algorithms. |
| Shared interface | Interaction tests for annotations, undo, selection state, error states and local file workflows. |
| Windows build | Native compilation, tests and installer generation on a Windows CI runner. |
| Real Windows behavior | External tester results for Windows version, display/DPI setup, hardware, foreground app and enabled capture sources. |
| macOS regression | Existing capture, focus, recording and export checks before switching any installed functionality to the new stack. |

The principal risks are mixed display scaling/negative coordinates, preserving foreground focus and fullscreen context, and synchronized video/audio capture plus export. A successful build alone does not close any of those hardware acceptance gates.

## Primary references

- [Tauri architecture and platform support](https://v2.tauri.app/start/)
- [Artcraft development stack: Rust/Tauri and React/TypeScript](https://github.com/storytold/artcraft/blob/main/_docs/dev_setup.md)
- [Microsoft Windows screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)
- [Microsoft Rust bindings for Windows APIs](https://github.com/microsoft/windows-rs)
- [Window exclusion from capture](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)
- [WASAPI loopback recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)
