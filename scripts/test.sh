#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# Swift 6 Command Line Tools ship Swift Testing but may omit XCTest. Some CLT
# versions expose the framework directory as -I rather than -F to SwiftPM.
developer_dir="$(xcode-select -p)"
framework_dir=""
for candidate in \
  "$developer_dir/Library/Developer/Frameworks" \
  "$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  "$developer_dir/Library/Frameworks"; do
  if [[ -d "$candidate/Testing.framework" ]]; then
    framework_dir="$candidate"
    break
  fi
done

test_args=(--disable-xctest --enable-swift-testing)
if [[ -n "$framework_dir" ]]; then
  test_args+=(-Xswiftc -F -Xswiftc "$framework_dir")
  test_args+=(-Xlinker -F -Xlinker "$framework_dir")
  test_args+=(-Xlinker -rpath -Xlinker "$framework_dir")
fi
testing_support_dir="$developer_dir/Library/Developer/usr/lib"
if [[ -f "$testing_support_dir/lib_TestingInterop.dylib" ]]; then
  # Some CLT builds embed an incomplete relative path in Testing.framework.
  test_args+=(-Xlinker -rpath -Xlinker "$testing_support_dir")
fi
swift test "${test_args[@]}" "$@"
