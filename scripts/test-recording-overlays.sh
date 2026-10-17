#!/bin/bash
set -euo pipefail

overlay_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
overlay_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/artshot-overlay-tests.XXXXXX")"
overlay_test_binary="$overlay_test_dir/RecordingOverlaySmokeTests"
trap 'if [[ -f "$overlay_test_binary" ]]; then unlink "$overlay_test_binary"; fi; rmdir "$overlay_test_dir"' EXIT

xcrun swiftc -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  "$overlay_project_root/Sources/ArtShotX/CameraLayout.swift" \
  "$overlay_project_root/Sources/ArtShotX/CameraOverlayController.swift" \
  "$overlay_project_root/Sources/ArtShotX/RecordingControlBar.swift" \
  "$overlay_project_root/Tests/RecordingOverlaySmokeTests.swift" \
  -o "$overlay_test_binary"

"$overlay_test_binary"
