#!/bin/bash
set -euo pipefail
selection_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$selection_root"
selection_dir="$(mktemp -d -t artshot-selection)"
trap 'find "$selection_dir" -type f -delete; rmdir "$selection_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -emit-library -emit-module -module-name ArtShotCore Sources/ArtShotCore/*.swift -o "$selection_dir/libArtShotCore.dylib" -emit-module-path "$selection_dir/ArtShotCore.swiftmodule"
cat Sources/ArtShotX/SelectionOverlay.swift Sources/ArtShotX/CapturePanelController.swift Tests/SelectionAdjustmentTests.swift > "$selection_dir/SelectionTests.swift"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -I "$selection_dir" -L "$selection_dir" -lArtShotCore -Xlinker -rpath -Xlinker "$selection_dir" "$selection_dir/SelectionTests.swift" -o "$selection_dir/test"
"$selection_dir/test"
