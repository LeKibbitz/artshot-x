#!/bin/bash
set -euo pipefail
editor_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$editor_root"
editor_test_dir="$(mktemp -d -t artshot-video-editor)"
trap 'find "$editor_test_dir" -type f -delete; find "$editor_test_dir" -depth -type d -empty -delete' EXIT
mkdir "$editor_test_dir/audio" "$editor_test_dir/silent"
ffmpeg -v error -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=4' -f lavfi -i 'sine=frequency=440:duration=4' -f lavfi -i 'sine=frequency=880:duration=4' -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a aac "$editor_test_dir/audio/capture.mov"
ffmpeg -v error -i "$editor_test_dir/audio/capture.mov" -map 0:v -c copy "$editor_test_dir/silent/capture.mov"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -emit-library -emit-module -module-name ArtShotCore Sources/ArtShotCore/*.swift -o "$editor_test_dir/libArtShotCore.dylib" -emit-module-path "$editor_test_dir/ArtShotCore.swiftmodule"
cp Sources/ArtShotX/VideoPreviewWindowController.swift "$editor_test_dir/VideoPreviewWindowController.swift"
cat Tests/VideoEditorSmokeTests.swift >> "$editor_test_dir/VideoPreviewWindowController.swift"
editor_sources=()
for source_file in Sources/ArtShotX/*.swift; do
  case "$source_file" in */main.swift|*/VideoPreviewWindowController.swift) ;; *) editor_sources+=("$source_file");; esac
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -I "$editor_test_dir" -L "$editor_test_dir" -lArtShotCore -Xlinker -rpath -Xlinker "$editor_test_dir" "${editor_sources[@]}" "$editor_test_dir/VideoPreviewWindowController.swift" -o "$editor_test_dir/test"
"$editor_test_dir/test" "$editor_test_dir" "$editor_root/replica/clone-screens/video-editor.png"
