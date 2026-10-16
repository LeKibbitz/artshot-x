#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  echo 'Usage: scripts/build.sh [release|debug]' >&2
  exit 2
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$project_dir/dist/ArtShot X.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/ArtShotX" "$app_dir/Contents/MacOS/ArtShotX"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
chmod +x "$app_dir/Contents/MacOS/ArtShotX"
signing_identity="${ARTSHOT_SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
