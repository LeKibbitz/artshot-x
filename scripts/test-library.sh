#!/bin/bash
set -euo pipefail

# Exercise the actual AppKit library in an isolated temporary directory.
library_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/artshot-library-tests.XXXXXX")"
library_test_binary="$library_test_dir/CaptureLibrarySmokeTests"
trap 'if [[ -f "$library_test_binary" ]]; then unlink "$library_test_binary"; fi; rmdir "$library_test_dir"' EXIT

xcrun swiftc -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  "$library_project_root/Sources/ArtShotX/CaptureLibrary.swift" \
  "$library_project_root/Tests/CaptureLibrarySmokeTests.swift" \
  -o "$library_test_binary"

"$library_test_binary"
