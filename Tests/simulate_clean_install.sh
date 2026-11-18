#!/bin/bash
# Clean-install simulation. Packages the real app, mounts its DMG read-only,
# copies it into a throwaway Applications folder, and launches that copy with an
# isolated HOME. It never writes /Applications, changes privacy grants, opens
# System Settings, installs the helper, or arms anything.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
APP="$ROOT/build/Wakely.app"
[ -d "$APP" ] || { echo "Build Wakely.app first" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

TMP=$(mktemp -d "$ROOT/build/clean-install-sim.XXXXXXXX")
DMG_NAME="Wakely-sim-$$.dmg"
DMG="$ROOT/dist/$DMG_NAME"
MNT="$TMP/mounted"
cleanup() {
  if mount | grep -Fq "on $MNT "; then hdiutil detach "$MNT" -quiet || true; fi
  case "$DMG" in "$ROOT/dist/"Wakely-sim-*.dmg) rm -f -- "$DMG";; esac
  case "$TMP" in "$ROOT/build/clean-install-sim."*) rm -rf -- "$TMP";; esac
}
trap cleanup EXIT

echo "== packaging"
if bash package-dmg.sh "$DMG_NAME"; then
  echo "== mount read-only"
  mkdir -p "$MNT"
  hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet
  [ -d "$MNT/Wakely.app/Contents" ]
  [ -L "$MNT/Applications" ]
  [ "$(readlink "$MNT/Applications")" = "/Applications" ]
  [ -f "$MNT/Install.txt" ]
  codesign --verify --deep --strict "$MNT/Wakely.app"
  echo "== drag to a throwaway Applications folder"
  mkdir -p "$TMP/Applications" "$TMP/home"
  ditto "$MNT/Wakely.app" "$TMP/Applications/Wakely.app"
  hdiutil detach "$MNT" -quiet
  rm -rf -- "$MNT"
  KIND="DMG"
else
  echo "DMG creation is unavailable in this sandbox; simulating the same download"
  echo "and drag with a zip of the identical staging layout."
  mkdir -p "$TMP/stage" "$TMP/Downloads" "$TMP/Applications" "$TMP/home"
  ditto "$APP" "$TMP/stage/Wakely.app"
  ln -s /Applications "$TMP/stage/Applications"
  printf '%s\n' 'Drag Wakely.app to Applications.' > "$TMP/stage/Install.txt"
  ditto -c -k --sequesterRsrc --keepParent "$TMP/stage" "$TMP/Downloads/Wakely.zip"
  ditto -x -k "$TMP/Downloads/Wakely.zip" "$TMP/Downloads"
  ditto "$TMP/Downloads/stage/Wakely.app" "$TMP/Applications/Wakely.app"
  KIND="zip fallback (DMG not verified in this environment)"
fi
codesign --verify --deep --strict "$TMP/Applications/Wakely.app"

echo "== first launch from the copied bundle (isolated HOME)"
SIM_APP="$TMP/Applications/Wakely.app/Contents/MacOS/Wakely"
HOME="$TMP/home" CFFIXED_USER_HOME="$TMP/home" "$SIM_APP" \
  --render-permission-preview "$TMP/permission" > "$TMP/permission.log" 2>&1
grep -q "Rendered permission onboarding previews" "$TMP/permission.log"
for permission in accessibility location notifications helper; do
  [ -s "$TMP/permission-$permission.png" ]
done
HOME="$TMP/home" CFFIXED_USER_HOME="$TMP/home" "$SIM_APP" \
  --render-ui-preview "$TMP/components.png" --component=cleaningLock > "$TMP/components.log" 2>&1
[ -s "$TMP/components.png" ]

echo "== permission metadata"
for key in NSLocationUsageDescription NSLocationWhenInUseUsageDescription NSAppleEventsUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$TMP/Applications/Wakely.app/Contents/Info.plist" | grep -q .
done

echo "PASS: $KIND, app copies to Applications, launches relocated and renders permission onboarding"
echo "Scope: no real download quarantine, notarization, TCC grant, System Settings pane, helper install or input lock was exercised."
