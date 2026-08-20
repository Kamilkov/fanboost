#!/bin/bash
# Build a drag-to-Applications DMG for FanBoost. GPL-2.0.
# Usage: scripts/make-dmg.sh [path/to/FanBoost.app] [output.dmg]
# Defaults: DerivedData Release app; build/FanBoost-<version>.dmg.
# Refuses to overwrite an existing output file.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$REPO/DerivedData/Build/Products/Release/FanBoost.app}"
[ $# -le 2 ] || { echo "usage: $0 [FanBoost.app] [output.dmg]" >&2; exit 2; }

[ -d "$APP" ] || { echo "error: app bundle not found: $APP" >&2; exit 1; }
case "$APP" in *.app) ;; *) echo "error: input must be a .app bundle: $APP" >&2; exit 1;; esac
[ -f "$APP/Contents/Info.plist" ] || { echo "error: no Contents/Info.plist — not an app bundle: $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "error: code signature invalid: $APP" >&2; exit 1; }

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
OUT="${2:-$REPO/build/FanBoost-$VERSION.dmg}"
case "$OUT" in *.dmg) ;; *) echo "error: output must end in .dmg: $OUT" >&2; exit 1;; esac
[ ! -e "$OUT" ] || { echo "error: refusing to overwrite existing $OUT" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

STAGE="$(mktemp -d /tmp/fanboost-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

/usr/bin/ditto "$APP" "$STAGE/FanBoost.app"   # ditto preserves the signature seal
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "FanBoost" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$OUT"
echo "created: $OUT"
