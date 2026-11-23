select_deskmote_xcode() {
  local developer version
  local candidates=(
    "/Applications/Xcode_27.2.app/Contents/Developer"
    "/Applications/Xcode.app/Contents/Developer"
  )
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then candidates=("$DEVELOPER_DIR"); fi
  for developer in "${candidates[@]}"; do
    [[ -x "$developer/usr/bin/xcodebuild" ]] || continue
    version="$(DEVELOPER_DIR="$developer" /usr/bin/xcodebuild -version)" || continue
    if [[ "$version" == $'Xcode 27.2\nBuild version 27B52' ]]; then
      export DEVELOPER_DIR="$developer"
      return 0
    fi
  done
  printf 'Xcode 27.2 (27B52) is required. Set DEVELOPER_DIR to its Contents/Developer.\n' >&2
  return 1
}

require_deskmote_platform() {
  local version
  version="$(sw_vers -productVersion)"
  if [[ "$(uname -m)" != arm64 || "${version%%.*}" -lt 27 ]]; then
    printf 'DeskMote requires macOS 27 or later on Apple silicon.\n' >&2
    return 1
  fi
}
