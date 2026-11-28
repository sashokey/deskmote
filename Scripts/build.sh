#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
source Scripts/lib/xcode.sh
source Scripts/lib/release_binary.sh

variant="${1:-}"
case "$variant" in
  full) configuration=full; excluded_targets='' ;;
  base) configuration=base; excluded_targets='CommandShift|NaturalSwitch|BatteryRun|DeskMoteApps|DeskMoteFinder|DeskMoteFinderService' ;;
  no-finder) configuration=no_finder; excluded_targets='DeskMoteFinder|DeskMoteFinderService' ;;
  *) printf 'Usage: bash Scripts/build.sh {full|base|no-finder} [--local vN]\n' >&2; exit 2 ;;
esac
shift
if [[ "$#" -ne 0 && ( "$#" -ne 2 || "$1" != --local || "$variant" != full ) ]]; then
  printf 'Use --local vN with the full variant.\n' >&2
  exit 2
fi

require_deskmote_platform
select_deskmote_xcode
release_version="$(python3 -c 'import json; print(json.load(open(".github/release.json"))["version"])')"
version="${DESKMOTE_VERSION:-$release_version}"
[[ "$version" =~ ^v[1-9][0-9]*$ ]] || { printf 'Version must be vN.\n' >&2; exit 2; }
revision="$(git rev-parse --verify HEAD)"
if [[ -n "${GITHUB_SHA:-}" && "$revision" != "$GITHUB_SHA" ]]; then
  printf 'Checked-out commit differs from the CI commit.\n' >&2
  exit 1
fi

if [[ "$#" -ne 0 ]]; then
  tag="$2"
  [[ "$tag" =~ ^v[1-9][0-9]*$ && "$tag" == "$version" && "$tag" == "$release_version" ]] ||
    { printf 'The release tag and configured version must match.\n' >&2; exit 1; }
  [[ "$(git rev-parse --verify "refs/tags/$tag^{commit}")" == "$revision" ]] ||
    { printf 'HEAD must be the release tag commit.\n' >&2; exit 1; }
  checkout_status="$(git status --porcelain --untracked-files=normal)"
  [[ -z "$checkout_status" ]] ||
    { printf 'The release checkout must be clean.\n' >&2; exit 1; }
fi

build_dir="${DESKMOTE_BUILD_DIR:-$root/build}"
mkdir -p "$build_dir"
output="$(mktemp -d "$build_dir/$variant.XXXXXXXX")"
number="${version#v}"
xcodebuild build \
  -project DeskMote.xcodeproj \
  -scheme DeskMote \
  -configuration Release \
  -derivedDataPath "$output/DerivedData" \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  DESKMOTE_VARIANT="$configuration" \
  CODE_SIGNING_ALLOWED=NO \
  LD_GENERATE_MAP_FILE=YES \
  CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  MARKETING_VERSION="$number.0.0" CURRENT_PROJECT_VERSION="$number" \
  DESKMOTE_PUBLIC_VERSION="$version" DESKMOTE_SOURCE_REVISION="$revision" \
  2>&1 | tee "$output/xcodebuild.log" >&2

if [[ -n "$excluded_targets" ]] &&
  grep -Eq "Target '($excluded_targets)' in project" "$output/xcodebuild.log"; then
  printf 'The %s build includes an excluded target.\n' "$variant" >&2
  exit 1
fi

python3 Scripts/check_release_inputs.py "$variant" "$output/DerivedData" >&2
app="$output/DerivedData/Build/Products/Release/DeskMote.app"
binary="$app/Contents/MacOS/DeskMote"
cp LICENSE "$app/Contents/Resources/LICENSE"
strip_release_binary "$binary" >&2
verify_release_binary "$binary" >&2

sign() {
  codesign --force --sign - --timestamp=none --options runtime "$@"
}
if [[ -d "$app/Contents/PlugIns/DeskMoteFinder.appex" ]]; then
  finder="$app/Contents/PlugIns/DeskMoteFinder.appex"
  sign "$finder/Contents/XPCServices/DeskMoteFinderService.xpc"
  sign --entitlements Extensions/FinderFileCreator/Finder.entitlements "$finder"
fi
sign "$app"

python3 Scripts/check_availability_warnings.py "$output/xcodebuild.log" >&2
python3 Scripts/check_bundle.py "$app" "$variant" "$version" "$revision" >&2
printf '%s\n' "$app"
