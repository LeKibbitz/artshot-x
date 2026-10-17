#!/bin/bash
set -euo pipefail
recording_controls_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$recording_controls_root"
controls_test_dir="$(mktemp -d -t artshot-recording-controls)"
trap 'find "$controls_test_dir" -type f -delete; rmdir "$controls_test_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -emit-library -emit-module -module-name ArtShotCore Sources/ArtShotCore/*.swift -o "$controls_test_dir/libArtShotCore.dylib" -emit-module-path "$controls_test_dir/ArtShotCore.swiftmodule"
cp Sources/ArtShotX/RecordingController.swift "$controls_test_dir/RecordingController.swift"
cat Tests/RecordingControlsSmokeTests.swift >> "$controls_test_dir/RecordingController.swift"
recording_control_sources=()
for source_file in Sources/ArtShotX/*.swift; do
  case "$source_file" in */main.swift|*/RecordingController.swift) ;; *) recording_control_sources+=("$source_file");; esac
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -I "$controls_test_dir" -L "$controls_test_dir" -lArtShotCore -Xlinker -rpath -Xlinker "$controls_test_dir" "${recording_control_sources[@]}" "$controls_test_dir/RecordingController.swift" -o "$controls_test_dir/test"
"$controls_test_dir/test"
