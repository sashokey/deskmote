#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
release_version="$(python3 -c 'import json; print(json.load(open(".github/release.json"))["version"])')"
version="${DESKMOTE_VERSION:-$release_version}"
app="$(bash Scripts/build.sh full)"
mkdir -p dist
archive="dist/DeskMote-$version.zip"
test ! -e "$archive" || { printf 'Archive already exists: %s\n' "$archive" >&2; exit 1; }
staging="$(mktemp -d dist/.deskmote-package.XXXXXXXX)"
trap 'rm -rf "$staging"' EXIT
pending="$staging/DeskMote-$version.zip"
extracted="$staging/extracted"
ditto -c -k --sequesterRsrc --keepParent "$app" "$pending"
ditto -x -k "$pending" "$extracted"
python3 Scripts/check_bundle.py "$extracted/DeskMote.app" full "$version" "$(git rev-parse --verify HEAD)"
python3 Tests/Widgets/CheckIntent.py "$extracted/DeskMote.app"
checksum="$(shasum -a 256 "$pending" | awk '{ print $1 }')"
python3 -c 'import os, sys; os.link(sys.argv[1], sys.argv[2], follow_symlinks=False)' "$pending" "$archive"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf 'sha256=%s\n' "$checksum" >> "$GITHUB_OUTPUT"; fi
printf '%s  %s\n' "$checksum" "$archive"
