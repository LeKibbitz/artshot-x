#!/bin/bash
set -euo pipefail

# Compile the actual AppKit preview sources independently of the SwiftPM app.
# AppKit requires a macOS login session, but this harness shows no windows.
preview_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preview_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/artshot-preview-tests.XXXXXX")"
preview_test_binary="$preview_test_dir/PreviewSmokeTests"
trap 'rm -f "$preview_test_binary"; rmdir "$preview_test_dir"' EXIT

xcrun swiftc -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  "$preview_project_root/Sources/ArtShotX/AnnotationCanvas.swift" \
  "$preview_project_root/Sources/ArtShotX/PreviewWindowController.swift" \
  "$preview_project_root/Tests/PreviewSmokeTests.swift" \
  -o "$preview_test_binary"

"$preview_test_binary"
