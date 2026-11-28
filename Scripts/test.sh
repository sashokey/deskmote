#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
source Scripts/lib/xcode.sh
require_deskmote_platform
select_deskmote_xcode

variant="${1:-}"
case "$variant" in
  full|base) ;;
  *) printf 'Usage: bash Scripts/test.sh {full|base}\n' >&2; exit 2 ;;
esac
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/deskmote-$variant-tests.XXXXXXXX")"
xcodebuild test \
  -project DeskMote.xcodeproj \
  -scheme DeskMote \
  -configuration Debug \
  -derivedDataPath "$test_dir" \
  -resultBundlePath "$test_dir/Tests.xcresult" \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  DESKMOTE_VARIANT="$variant" DESKMOTE_APPS_TEST_HOOKS=YES CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$test_dir/xcodebuild.log"
python3 Scripts/check_availability_warnings.py "$test_dir/xcodebuild.log"

if [[ "$variant" == full ]]; then
  swift=(xcrun swiftc -swift-version 6 -target arm64-apple-macos27.0 -module-cache-path "$test_dir/module-cache" -parse-as-library)
  "${swift[@]}" Modules/BatteryRun/*.swift Tests/BatteryRun/*.swift -o "$test_dir/BatteryRunTests"
  "$test_dir/BatteryRunTests" --without-battery
  "${swift[@]}" Modules/BatteryRun/BatteryRunModule.swift Tests/BatteryRun/WindowPresentation/WindowPresentationTests.swift \
    -o "$test_dir/BatteryRunWindowPresentationTests"
  "$test_dir/BatteryRunWindowPresentationTests"
  "${swift[@]}" Extensions/FinderFileCreator/{FileCreator,FinderSync,NewFileType,FinderFileCreationIPC}.swift \
    Tests/FinderFileCreator/FileCreatorTests.swift \
    -o "$test_dir/FinderFileCreatorTests"
  "$test_dir/FinderFileCreatorTests"
  "${swift[@]}" Extensions/FinderFileCreator/{FileCreator,NewFileType,FinderFileCreationIPC,FinderFileCreationServer}.swift \
    Tests/FinderFileCreator/FinderFileCreationIPCTests.swift -o "$test_dir/FinderFileCreationIPCTests"
  "$test_dir/FinderFileCreationIPCTests"
fi
