#!/bin/bash
set -euo pipefail
scroll_preview_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$scroll_preview_root"
scroll_preview_dir="$(mktemp -d -t artshot-scrolling-preview)"
trap 'find "$scroll_preview_dir" -type f -delete; rmdir "$scroll_preview_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -emit-library -emit-module -module-name ArtShotCore Sources/ArtShotCore/*.swift -o "$scroll_preview_dir/libArtShotCore.dylib" -emit-module-path "$scroll_preview_dir/ArtShotCore.swiftmodule"
python3 - "$scroll_preview_dir" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
for section in pathlib.Path('Tests/ScrollingPreviewControllerTests.swift').read_text().split('// HARNESS: ')[1:]:
    name, body = section.split('\n', 1)
    source = pathlib.Path('Sources/ArtShotX') / name
    (out / name).write_text((source.read_text() if name != 'Main.swift' and source.exists() else '') + '\n' + body)
PY
scroll_preview_sources=()
for source_file in Sources/ArtShotX/*.swift; do
  case "$source_file" in */main.swift) ;; *)
    if [[ -f "$scroll_preview_dir/$(basename "$source_file")" ]]; then
      scroll_preview_sources+=("$scroll_preview_dir/$(basename "$source_file")")
    else
      scroll_preview_sources+=("$source_file")
    fi;;
  esac
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -I "$scroll_preview_dir" -L "$scroll_preview_dir" -lArtShotCore -Xlinker -rpath -Xlinker "$scroll_preview_dir" "${scroll_preview_sources[@]}" "$scroll_preview_dir/Main.swift" -o "$scroll_preview_dir/test"
"$scroll_preview_dir/test"
