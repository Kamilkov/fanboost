#!/bin/sh
# Verify Hardened Runtime is on and NO library-validation/DYLD exception
# entitlements are present, for both the app and its embedded helper.
# Usage: checks/verify-hardened.sh <FanBoost.app>
set -e
APP="$1"
[ -d "$APP" ] || { echo "usage: $0 <FanBoost.app>"; exit 2; }
HELPER="$APP/Contents/MacOS/FanBoostHelper"
[ -f "$HELPER" ] || { echo "FAIL: embedded helper missing at $HELPER"; exit 1; }

fail=0
for bin in "$APP" "$HELPER"; do
    # Hardened Runtime shows as the 'runtime' flag in codesign output.
    if codesign -dvvv "$bin" 2>&1 | grep -q "flags=.*runtime"; then
        echo "OK: runtime flag on $bin"
    else
        echo "FAIL: no Hardened Runtime flag on $bin"; fail=1
    fi
    # No exception entitlements that would defeat library validation / HR.
    ents=$(codesign -d --entitlements - --xml "$bin" 2>/dev/null || true)
    for bad in \
        com.apple.security.cs.disable-library-validation \
        com.apple.security.cs.allow-dyld-environment-variables \
        com.apple.security.cs.allow-unsigned-executable-memory; do
        if printf '%s' "$ents" | grep -q "$bad"; then
            echo "FAIL: $bin carries exception entitlement $bad"; fail=1
        fi
    done
    # Notarization prerequisites, enforced only on the Developer ID
    # (distribution/Release) signature — Apple Development (Debug) legitimately
    # has neither a secure timestamp nor a get-task-allow prohibition.
    if codesign -dvvv "$bin" 2>&1 | grep -q "Authority=Developer ID Application"; then
        if codesign -dvvv "$bin" 2>&1 | grep -q "^Timestamp="; then
            echo "OK: secure timestamp on $bin"
        else
            echo "FAIL: Developer ID $bin has no secure timestamp (notarization blocker)"; fail=1
        fi
        if printf '%s' "$ents" | grep -q "com.apple.security.get-task-allow"; then
            echo "FAIL: Developer ID $bin carries get-task-allow (notarization blocker)"; fail=1
        else
            echo "OK: no get-task-allow on $bin"
        fi
    fi
done

# Bundle must still be sealed. Capture stderr in a variable — no temp file.
if err=$(codesign --verify --deep --strict "$APP" 2>&1); then
    echo "OK: --deep --strict sealing"
else
    echo "FAIL: --deep --strict"; printf '%s\n' "$err"; fail=1
fi
[ "$fail" -eq 0 ] && echo "verify-hardened: PASS" || { echo "verify-hardened: FAIL"; exit 1; }
