#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
edit_test_dir="$(mktemp -d -t artshot-edit-test)"
trap 'rm -f "$edit_test_dir/test"; rmdir "$edit_test_dir"' EXIT
swiftc -target "$(uname -m)-apple-macosx14.0" -parse-as-library Sources/ArtShotX/RecordingMedia.swift Sources/ArtShotX/CameraLayout.swift Sources/ArtShotX/CameraVideoCompositor.swift Tests/test-recording-edit.swift -o "$edit_test_dir/test"
"$edit_test_dir/test"
