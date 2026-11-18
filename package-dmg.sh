#!/bin/bash
# Package only: never builds, launches, registers, or changes privacy grants.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd -P)
APP="$ROOT/build/Wakely.app"
OUT="$ROOT/dist"
if [ "${1:-}" = --help ]; then
  echo 'Usage: bash package-dmg.sh [new-output-name.dmg]'
  echo 'Requires a previously built build/Wakely.app. Refuses existing output.'
  exit 0
fi
NAME="${1:-Wakely.dmg}"
case "$NAME" in ''|.*|*/*|*\\*|*[!A-Za-z0-9._-]*|*.dmg.dmg) echo 'Use a simple new .dmg filename' >&2; exit 1;; esac
case "$NAME" in *.dmg) ;; *) echo 'Output must end in .dmg' >&2; exit 1;; esac
[ -d "$APP/Contents" ] && [ ! -L "$APP" ] || { echo 'Build Wakely.app first (no symlink bundles)' >&2; exit 1; }
[ ! -L "$OUT" ] || { echo 'Refusing symlink dist directory' >&2; exit 1; }
mkdir -p "$OUT"
[ "$(cd "$OUT" && pwd -P)" = "$ROOT/dist" ] || exit 1
[ ! -e "$OUT/$NAME" ] && [ ! -L "$OUT/$NAME" ] || { echo 'Output already exists; choose a new name' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
STAGE=$(mktemp -d "$OUT/.wakely-stage.XXXXXXXX")
cleanup() {
  # Only remove the exact newly-created canonical staging directory.
  case "$STAGE" in "$OUT"/.wakely-stage.*)
    if [ -d "$STAGE" ] && [ ! -L "$STAGE" ] && [ "$(cd "$STAGE" && pwd -P)" = "$STAGE" ]; then
      rm -rf -- "$STAGE"
    fi;;
  esac
}
trap cleanup EXIT
BACKGROUND="$ROOT/Resources/DMGBackground.tiff"
[ -f "$BACKGROUND" ] && [ ! -L "$BACKGROUND" ] || { echo 'Missing Resources/DMGBackground.tiff; run tools/make-dmg-background.py' >&2; exit 1; }
mkdir "$STAGE/payload"
ditto "$APP" "$STAGE/payload/Wakely.app"
ln -s /Applications "$STAGE/payload/Applications"
mkdir "$STAGE/payload/.background"
cp "$BACKGROUND" "$STAGE/payload/.background/background.tiff"
cp "$ROOT/Resources/Wakely.icns" "$STAGE/payload/.VolumeIcon.icns"
chflags hidden "$STAGE/payload/.background" "$STAGE/payload/.VolumeIcon.icns" 2>/dev/null || true

# A writable image is required so Finder can persist the window layout and
# background into the volume's .DS_Store. The image is converted back to UDZO.
[ ! -e /Volumes/Wakely ] || { echo 'Unmount the existing /Volumes/Wakely first' >&2; exit 1; }
hdiutil create -volname Wakely -srcfolder "$STAGE/payload" -ov -format UDRW "$STAGE/writable.dmg" >/dev/null
MOUNT="/Volumes/Wakely"
hdiutil attach "$STAGE/writable.dmg" -nobrowse -noautoopen >/dev/null
[ -d "$MOUNT" ] || { echo 'The Wakely volume did not mount' >&2; exit 1; }
cleanup_mount() {
  if [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  fi
}
trap 'cleanup_mount; cleanup' EXIT
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Wakely"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {240, 160, 960, 608}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set shows icon preview of viewOptions to false
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Wakely.app" of container window to {180, 296}
    set position of item "Applications" of container window to {540, 296}
    close
  end tell
end tell
APPLESCRIPT
SetFile -a C "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" >/dev/null
trap cleanup EXIT
hdiutil convert "$STAGE/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$STAGE/image.dmg" >/dev/null
# A hard link publishes without overwriting an existing destination, even if a
# second packaging process selected the same output name while we were working.
ln "$STAGE/image.dmg" "$OUT/$NAME"
echo "Packaged $OUT/$NAME (layout written; not automatically notarized or left mounted)"
