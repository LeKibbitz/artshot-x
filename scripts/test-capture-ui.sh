#!/bin/bash
set -euo pipefail

# Requires a macOS login session; briefly presents only a nonactivating test thumbnail.
ui_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ui_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/artshot-ui-tests.XXXXXX")"
ui_test_binary="$ui_test_dir/CaptureUISmokeTests"
trap 'if [[ -f "$ui_test_binary" ]]; then unlink "$ui_test_binary"; fi; rmdir "$ui_test_dir"' EXIT

xcrun swiftc -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ui_project_root/Sources/ArtShotX/CaptureLibrary.swift" \
  "$ui_project_root/Sources/ArtShotX/QuickAccessController.swift" \
  "$ui_project_root/Sources/ArtShotX/CapturePanelController.swift" \
  "$ui_project_root/Tests/CaptureUISmokeTests.swift" \
  -o "$ui_test_binary"

"$ui_test_binary"
