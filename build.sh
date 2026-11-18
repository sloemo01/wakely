#!/bin/bash
# Build Wakely into a signed .app bundle with the Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"

# Swift module caches live outside the repo: Apple's IOKit module embeds a
# retired power-management key name, and this tree must stay free of it.
# Override with WAKELY_BUILD_CACHE when a shared cache is wanted.
BUILD_CACHE="${WAKELY_BUILD_CACHE:-$HOME/Library/Caches/Wakely/build}"
mkdir -p "$BUILD_CACHE"

APP="build/Wakely.app"
# Preserve the bundle directory: deleting it while a development copy is
# running makes Foundation cache missing sound/sprite resource lookups.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== compiling"
swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$BUILD_CACHE" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework ServiceManagement \
  -framework AVFoundation \
  -o "$APP/Contents/MacOS/Wakely" \
  Sources/*.swift

echo "== resources (byte-for-byte)"
rm -rf "$APP/Contents/Resources/Fonts/Pixel"
cp -R Resources/. "$APP/Contents/Resources/"
chmod -R u+w "$APP/Contents/Resources/Icons" 2>/dev/null || true
# the component SDK kit rides along so "describe a component" works out of the box
rm -rf "$APP/Contents/Resources/ComponentsKit"
mkdir -p "$APP/Contents/Resources/ComponentsKit/sdk"
cp -R harvest/components-kit/sdk/. "$APP/Contents/Resources/ComponentsKit/sdk/"
for f in README.txt AGENTS.md CLAUDE.md; do
  [ -f "harvest/components-kit/$f" ] && cp "harvest/components-kit/$f" "$APP/Contents/Resources/ComponentsKit/$f"
done

mkdir -p "$APP/Contents/Resources/SeedComponents"
cp -R harvest/components-kit/sdk/examples/. "$APP/Contents/Resources/SeedComponents/"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== helper targets"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Library/LaunchAgents"

if ls Helper/*.swift >/dev/null 2>&1; then
  swiftc \
    -swift-version 5 -O -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_CACHE" \
    -framework AppKit -framework IOKit -framework Foundation \
    -o "$APP/Contents/MacOS/WakelyHelper" \
    Sources/HelperProtocol.swift Helper/*.swift
  echo "   built WakelyHelper"
else
  echo "   WARNING: Helper/ has no sources yet; the daemon will be missing"
fi

if [ -f Watchdog/main.swift ]; then
  swiftc \
    -swift-version 5 -O -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_CACHE" \
    -framework AppKit -framework Foundation \
    -o "$APP/Contents/MacOS/WakelyWatchdog" \
    Sources/HelperProtocol.swift Watchdog/Policy.swift Watchdog/main.swift
  echo "   built WakelyWatchdog"
fi

cp Resources/dev.wakely.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/dev.wakely.agent.plist "$APP/Contents/Library/LaunchAgents/"

echo "== component tool (OSS kit checker)"
mkdir -p "$APP/Contents/Helpers"
swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$BUILD_CACHE" \
  Sources/ComponentValidator.swift Tools/ComponentTool/*.swift \
  -o "$APP/Contents/Helpers/wakely-component"
echo "   built wakely-component"

echo "== signing"
# Never create/unlock a keychain or embed its password during a build. Explicit
# configuration is fail-closed: a missing/locked identity must not fall back to
# ad-hoc and silently invalidate Accessibility grants. Setup is a separate action.
IDENT="${WAKELY_SIGN_IDENTITY:-}"
SIGN_KEYCHAIN="${WAKELY_SIGN_KEYCHAIN:-}"
LOCAL_SIGNING=0
LOCAL_CONFIG="$HOME/Library/Application Support/Wakely/Signing/identity.json"
if [ -z "$IDENT" ] && [ -f "$LOCAL_CONFIG" ]; then
  LOCAL_SETTINGS=$(python3 - "$LOCAL_CONFIG" <<'PY'
import json, pathlib, re, sys
config = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert config['mode'] == 'local-certificate'
assert config['name'] == 'Wakely Local Development'
assert re.fullmatch(r'[0-9A-Fa-f]{40}', config['identity'])
assert pathlib.Path(config['keychain']).is_file()
assert '\t' not in config['keychain'] and '\n' not in config['keychain']
print(config['identity'].upper() + '\t' + config['keychain'])
PY
  ) || { echo 'Invalid local signing configuration; refusing ad-hoc fallback' >&2; exit 1; }
  IFS=$'\t' read -r IDENT SIGN_KEYCHAIN <<< "$LOCAL_SETTINGS"
  LOCAL_SIGNING=1
fi
IDENT="${IDENT:--}"
SIGN_ARGS=(--sign "$IDENT")
if [ -n "$SIGN_KEYCHAIN" ]; then SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN"); fi
# Distribution builds opt in to hardened runtime and secure timestamps.
if [ "${WAKELY_DISTRIBUTION:-0}" = 1 ]; then
  if [ "$IDENT" = - ]; then echo "Distribution requires WAKELY_SIGN_IDENTITY" >&2; exit 1; fi
  if [ "$LOCAL_SIGNING" = 1 ]; then
    echo 'Developer ID distribution mode cannot use the local certificate; package local builds with package-dmg.sh instead' >&2
    exit 1
  fi
  SIGN_ARGS+=(--options runtime --timestamp)
fi
if [ "$LOCAL_SIGNING" = 1 ]; then SIGN_ARGS+=(--timestamp=none); fi
# Explicit, certificate-pinned designated requirements stay identical across
# rebuilds even when the binary's cdhash changes. Never pin local DRs to cdhash.
sign_target() {
  local target="$1" signing_id="$2"
  local args=("${SIGN_ARGS[@]}")
  if [ "$LOCAL_SIGNING" = 1 ]; then
    args+=(--requirements "=designated => identifier \"$signing_id\" and certificate leaf = H\"$IDENT\"")
  fi
  codesign --force --identifier "$signing_id" "${args[@]}" "$target"
}
# Nested code is signed BEFORE the app. A later `--deep` app signature would
# rewrite these explicit identifiers (verified: it renamed the watchdog), and
# the helper's peer requirement allowlists dev.wakely.watchdog by name.
# So the stable path signs nested code, then seals the app without --deep.
sign_nested() {
  local sign_args=("$@")
  for target in "$APP/Contents/MacOS/WakelyHelper" "$APP/Contents/MacOS/WakelyWatchdog" "$APP/Contents/Helpers/wakely-component"; do
    signing_id="dev.wakely.helper"
    if [ "${target##*/}" = "WakelyWatchdog" ]; then signing_id="dev.wakely.watchdog"; fi
    if [ "${target##*/}" = "wakely-component" ]; then signing_id="dev.wakely.component-tool"; fi
    [ -f "$target" ] || continue
    sign_target "$target" "$signing_id" || return 1
  done
}
if sign_nested "${SIGN_ARGS[@]}" \
   && sign_target "$APP" dev.wakely.app; then
  codesign --verify --deep --strict "$APP"
  if [ "$IDENT" = - ]; then
    echo "   ad-hoc development build; grants may reset after rebuild; not notarized"
  else
    echo "   signed as $IDENT; notarization is a separate step"
  fi
else
  echo "   ERROR: signing failed; refusing an identity-changing fallback" >&2
  exit 1
fi
for target in "$APP" "$APP/Contents/MacOS/WakelyHelper" "$APP/Contents/MacOS/WakelyWatchdog"; do
  [ -f "$target" ] || continue
  # Drain codesign's output: early awk exit can SIGPIPE codesign under pipefail.
  identifier=$(codesign -dv --verbose=2 "$target" 2>&1 | awk -F= '/^Identifier=/{if (!seen++) print $2}')
  echo "   ${target##*/}: ${identifier:-unsigned}"
done

# register with LaunchServices so wakely:// works
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "== built: $APP"
