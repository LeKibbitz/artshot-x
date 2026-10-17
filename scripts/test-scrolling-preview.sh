#!/bin/bash
set -euo pipefail
preview_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preview_dir="$(mktemp -d -t artshot-scrolling-preview)"
trap 'if [[ -f "$preview_dir/test" ]]; then unlink "$preview_dir/test"; fi; rmdir "$preview_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  "$preview_root/Sources/ArtShotX/ScrollingPreviewView.swift" \
  "$preview_root/Tests/ScrollingPreviewSmokeTests.swift" -o "$preview_dir/test"
"$preview_dir/test"
