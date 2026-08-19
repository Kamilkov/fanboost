#!/bin/sh
# capture-fan installer. Run as your normal user; it uses sudo for the
# privileged parts (root-owned smc copy + sudoers rule), then loads the
# LaunchAgent as you.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=/usr/local/libexec/capture-fan
SUDOERS=/etc/sudoers.d/capture-fan
PLIST_SRC="$DIR/com.kamilkovac.capture-fan.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.kamilkovac.capture-fan.plist"

echo "==> Installing root-owned smc binary to $DEST"
sudo mkdir -p "$DEST"
sudo cp "$DIR/vendor/smcFanControl/smc-command/smc" "$DEST/smc"
sudo chown root:wheel "$DEST/smc"
sudo chmod 755 "$DEST/smc"

echo "==> Installing sudoers rule (exact commands only)"
sudo tee "$SUDOERS" >/dev/null <<EOF
$(id -un) ALL=(root) NOPASSWD: $DEST/smc -k F0Md -w 01, $DEST/smc -k F0Tg -w 00806d45, $DEST/smc -k F0Md -w 00
EOF
sudo chmod 440 "$SUDOERS"
sudo visudo -c -f "$SUDOERS"

echo "==> Loading LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
# The tracked plist is portable; resolve the watcher path at install time.
sed "s|__WATCHER_PATH__|$DIR/watcher.sh|" "$PLIST_SRC" > "$PLIST_DST"
launchctl bootout "gui/$(id -u)/com.kamilkovac.capture-fan" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "==> Done. Log: ~/Library/Logs/capture-fan.log"
