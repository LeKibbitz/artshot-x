#!/bin/bash
set -euo pipefail
focus_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$focus_root"
focus_dir="$(mktemp -d -t artshot-capture-focus)"
trap 'find "$focus_dir" -type f -delete; rmdir "$focus_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -emit-library -emit-module -module-name ArtShotCore Sources/ArtShotCore/*.swift -o "$focus_dir/libArtShotCore.dylib" -emit-module-path "$focus_dir/ArtShotCore.swiftmodule"
python3 - "$focus_dir" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
for section in pathlib.Path('Tests/CaptureFocusSmokeTests.swift').read_text().split('// HARNESS: ')[1:]:
    name, body = section.split('\n', 1)
    source = pathlib.Path('Sources/ArtShotX') / name
    (out / name).write_text((source.read_text() if name != 'Main.swift' and source.exists() else '') + '\n' + body)
PY
focus_sources=()
for source_file in Sources/ArtShotX/*.swift; do
  case "$source_file" in */main.swift) ;; *)
    if [[ -f "$focus_dir/$(basename "$source_file")" ]]; then
      focus_sources+=("$focus_dir/$(basename "$source_file")")
    else
      focus_sources+=("$source_file")
    fi;;
  esac
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library -I "$focus_dir" -L "$focus_dir" -lArtShotCore -Xlinker -rpath -Xlinker "$focus_dir" "${focus_sources[@]}" "$focus_dir/Main.swift" -o "$focus_dir/test"
"$focus_dir/test"
