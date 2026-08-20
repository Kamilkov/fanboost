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

# Nested executable code (frameworks, XPC services, nested apps) — discovered
# by walking the bundle, never hardcoded, so future embedded code is covered.
# Each item must be validly signed, hardened, and signed by the SAME team as
# the outer app unless explicitly allowlisted with its signer (none today).
APP_TEAM=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
# Team pinning is a distribution property: enforced when the outer app is
# Developer ID signed (Release). Xcode's Debug re-signs nested SPM content
# ad-hoc, which stays acceptable there (validity + hardened runtime still
# required in both configs).
APP_IS_DEVID=0
codesign -dvvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" && APP_IS_DEVID=1
ALLOWED_THIRD_PARTY="" # "path-suffix=TeamID" entries; empty by design
NESTED=$(find "$APP/Contents" -mindepth 1 -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) | sort)
# Bare nested Mach-O executables too (e.g. Sparkle's Autoupdate) — anything
# executable under Frameworks/ that is not inside an already-walked bundle's
# own inner tree and is a real file.
LOOSE=$(find "$APP/Contents/Frameworks" -type f -perm +111 ! -path '*.app/*' ! -path '*.xpc/*' 2>/dev/null | while read -r f; do
    file -b "$f" | grep -q 'Mach-O' && printf '%s\n' "$f"; done | sort)
NESTED="$NESTED
$LOOSE"
for nested in $NESTED; do
    if ! err=$(codesign --verify --strict "$nested" 2>&1); then
        echo "FAIL: invalid signature on nested $nested"; printf '%s\n' "$err"; fail=1
        continue
    fi
    info=$(codesign -dvvv "$nested" 2>&1)
    if printf '%s' "$info" | grep -q "flags=.*runtime"; then
        echo "OK: runtime flag on nested ${nested#"$APP"/}"
    else
        echo "FAIL: no Hardened Runtime flag on nested $nested"; fail=1
    fi
    nents=$(codesign -d --entitlements - --xml "$nested" 2>/dev/null || true)
    if printf '%s' "$info" | grep -q "Authority=Developer ID Application"; then
        printf '%s' "$info" | grep -q "^Timestamp=" \
            || { echo "FAIL: nested Developer ID $nested has no secure timestamp"; fail=1; }
        printf '%s' "$nents" | grep -q "com.apple.security.get-task-allow" \
            && { echo "FAIL: nested Developer ID $nested carries get-task-allow"; fail=1; }
    fi
    team=$(printf '%s' "$info" | sed -n 's/^TeamIdentifier=//p')
    if [ "$APP_IS_DEVID" -eq 1 ]; then
        case "$ALLOWED_THIRD_PARTY" in
            *"${nested##*/}=$team"*) echo "OK: allowlisted third-party ${nested#"$APP"/} ($team)" ;;
            *) if [ "$team" = "$APP_TEAM" ] && [ -n "$team" ] && [ "$team" != "not set" ]; then
                   echo "OK: team $team on nested ${nested#"$APP"/}"
               else
                   echo "FAIL: nested $nested signed by '$team', expected '$APP_TEAM' (not allowlisted)"; fail=1
               fi ;;
        esac
    fi
done

# Bundle must still be sealed. Capture stderr in a variable — no temp file.
if err=$(codesign --verify --deep --strict "$APP" 2>&1); then
    echo "OK: --deep --strict sealing"
else
    echo "FAIL: --deep --strict"; printf '%s\n' "$err"; fail=1
fi
[ "$fail" -eq 0 ] && echo "verify-hardened: PASS" || { echo "verify-hardened: FAIL"; exit 1; }
