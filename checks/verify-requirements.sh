#!/bin/sh
# Verify the XPC peer requirements SEPARATE the two configs, using requirement
# strings produced by the ACTUAL Swift PeerConfig builder (via checks/reqtool),
# not a shell duplicate. Also assert each preserved product embeds the expected
# FBTeamID / FBIdentityClass.
# Usage: checks/verify-requirements.sh <debug/FanBoost.app> <release/FanBoost.app>
set -e
DBG="$1"; REL="$2"
[ -d "$DBG" ] && [ -d "$REL" ] || { echo "usage: $0 <debug.app> <release.app>"; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEAM=JXGJ4K9KR9
APP_ID=com.kamilkovac.FanBoost
H_ID=com.kamilkovac.FanBoostHelper

REQTOOL="$ROOT/build/reqtool"
swiftc "$ROOT/Shared/PeerRequirement.swift" "$ROOT/checks/reqtool.swift" -o "$REQTOOL"
req() { "$REQTOOL" "$1" "$TEAM" "$2"; } # <bundleID> <apple-development|developer-id>

fail=0
# <label> <product> <requirement> <expect: pass|fail>
check() {
    if codesign --verify -R="$3" "$2" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$4" ]; then echo "OK: $1 ($got as expected)"
    else echo "FAIL: $1 expected $4 got $got"; fail=1; fi
}

check "debug app vs debug req"       "$DBG" "$(req $APP_ID apple-development)" pass
check "debug app vs release req"     "$DBG" "$(req $APP_ID developer-id)"      fail
check "release app vs release req"   "$REL" "$(req $APP_ID developer-id)"      pass
check "release app vs debug req"     "$REL" "$(req $APP_ID apple-development)" fail

DH="$DBG/Contents/MacOS/FanBoostHelper"; RH="$REL/Contents/MacOS/FanBoostHelper"
check "debug helper vs debug req"     "$DH" "$(req $H_ID apple-development)" pass
check "debug helper vs release req"   "$DH" "$(req $H_ID developer-id)"      fail
check "release helper vs release req" "$RH" "$(req $H_ID developer-id)"      pass
check "release helper vs debug req"   "$RH" "$(req $H_ID apple-development)" fail

# Assert embedded config values in each preserved product.
assert_plist() { # <label> <plistfile> <key> <expected>
    got=$(plutil -extract "$3" raw "$2" 2>/dev/null || echo "<missing>")
    if [ "$got" = "$4" ]; then echo "OK: $1 $3=$got"
    else echo "FAIL: $1 $3 expected $4 got $got"; fail=1; fi
}
tmp=$(mktemp -d)
for pair in "$DBG:apple-development" "$REL:developer-id"; do
    app=${pair%:*}; cls=${pair#*:}
    assert_plist "app($cls)" "$app/Contents/Info.plist" FBTeamID "$TEAM"
    assert_plist "app($cls)" "$app/Contents/Info.plist" FBIdentityClass "$cls"
    segedit "$app/Contents/MacOS/FanBoostHelper" -extract __TEXT __info_plist "$tmp/h.plist"
    assert_plist "helper($cls)" "$tmp/h.plist" FBTeamID "$TEAM"
    assert_plist "helper($cls)" "$tmp/h.plist" FBIdentityClass "$cls"
done
rm -rf "$tmp"

[ "$fail" -eq 0 ] && echo "verify-requirements: PASS" || { echo "verify-requirements: FAIL"; exit 1; }
