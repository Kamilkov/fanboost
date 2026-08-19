#!/bin/sh
# capture-fan: while the screen is being captured/shared (Snagit, Teams,
# QuickTime, ...), force the fan to BOOST_RPM; afterwards hand control
# back to macOS automatic fan management.
#
# Runs as a LaunchAgent. Privileged SMC writes go through a root-owned
# copy of the smc CLI allowed via /etc/sudoers.d/capture-fan (exact
# argument match, NOPASSWD).

SMC=/usr/local/libexec/capture-fan/smc
PROBE="$(dirname "$0")/iscaptured"
LOG="$HOME/Library/Logs/capture-fan.log"
POLL=5

# 3800.0 as IEEE-754 float, little-endian hex — what the flt SMC key expects.
BOOST_TG=00806d45   # 0x456D8000 = 3800.0

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

boost() {
    sudo -n "$SMC" -k F0Md -w 01 >/dev/null && \
    sudo -n "$SMC" -k F0Tg -w "$BOOST_TG" >/dev/null && \
    log "capture started -> fan forced to 3800 RPM"
}

restore() {
    sudo -n "$SMC" -k F0Md -w 00 >/dev/null && \
    log "capture ended -> fan back to automatic"
}

# If the agent is killed/unloaded mid-capture, never leave the fan forced.
trap 'restore; exit 0' INT TERM

state=idle
log "watcher started"
while :; do
    "$PROBE" >/dev/null 2>&1
    r=$?
    if [ "$r" -eq 0 ] && [ "$state" = idle ]; then
        boost && state=capturing
    elif [ "$r" -eq 1 ] && [ "$state" = capturing ]; then
        restore && state=idle
    elif [ "$r" -ge 2 ]; then
        # Probe itself broke (macOS update removed the symbol?). Fail safe:
        # restore auto once, then keep retrying slowly.
        [ "$state" = capturing ] && restore && state=idle
        log "probe error (exit $r) — check iscaptured after a macOS update"
        sleep 60
    fi
    sleep "$POLL"
done
