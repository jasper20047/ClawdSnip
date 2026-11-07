#!/bin/zsh
# Build with a matching SDK; --output builds without replacing a running installation.
set -euo pipefail
cd "$(dirname "$0")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/ClawdSnip.app"
BIN="$APP/Contents/MacOS/ClawdSnip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
if [[ -z "${SDKROOT:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    export SDKROOT="$(xcrun --show-sdk-path)"
  fi
fi
mkdir -p .build/modules
swiftc -sdk "$SDKROOT" -target "$(uname -m)-apple-macosx15.0" -module-cache-path .build/modules -O -swift-version 5 -j1 \
  -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation -framework VideoToolbox -framework Carbon -framework ServiceManagement \
  -o "$BIN" main.swift RecordingOptions.swift RecordingFile.swift ScreenRecorder.swift RecordingUI.swift RegionSelector.swift HotKeyRules.swift GlobalHotKeys.swift SettingsUI.swift AppStatusMenu.swift
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  "$BIN" --render-icon "$ICONSET/icon_${s}x${s}.png" "$s"
  "$BIN" --render-icon "$ICONSET/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
SIGN_DIR="$HOME/Library/Application Support/ClawdSnip"
KC="$SIGN_DIR/signing.keychain-db"
if [[ -f "$KC" ]] && security find-identity -v -p codesigning "$KC" | grep -q '"ClawdSnip Local Signing"'; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/signing.pass")" "$KC"
  codesign --force --keychain "$KC" --sign "ClawdSnip Local Signing" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
if [[ "${1:-}" == --output ]]; then
  [[ $# -eq 2 ]] || { print -u2 'Usage: ./build.sh --output /absolute/path/ClawdSnip.app'; exit 1; }
  DEST="$2"
  [[ ! -e "$DEST" ]] || { print -u2 "Output exists: $DEST"; exit 1; }
  mkdir -p "$(dirname "$DEST")"
  ditto "$APP" "$DEST"
  codesign --verify --strict "$DEST"
  print "built: $DEST"
else
  DEST="$HOME/Applications/ClawdSnip.app"
  mkdir -p "$HOME/Applications"
  NEW="$HOME/Applications/.ClawdSnip-new-$$.app"
  OLD="$HOME/Applications/.ClawdSnip-backup-$(date +%Y%m%d-%H%M%S).app"
  ditto "$APP" "$NEW"
  codesign --verify --strict "$NEW"
  if pgrep -x ClawdSnip >/dev/null; then
    osascript -e 'tell application id "local.fwj.ClawdSnip" to quit'
    for attempt in {1..60}; do
      pgrep -x ClawdSnip >/dev/null || break
      sleep 1
    done
    if pgrep -x ClawdSnip >/dev/null; then
      print -u2 "ClawdSnip is still saving. Installer stopped; staged app: $NEW"
      exit 1
    fi
  fi
  if [[ -e "$DEST" ]]; then mv "$DEST" "$OLD"; fi
  if ! mv "$NEW" "$DEST"; then
    [[ ! -e "$OLD" ]] || mv "$OLD" "$DEST"
    exit 1
  fi
  print "installed: $DEST"
  [[ ! -e "$OLD" ]] || print "backup: $OLD"
fi
