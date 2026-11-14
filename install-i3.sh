#!/usr/bin/env bash
# Install i3 and the X tools needed to run it on WSL2 (Ubuntu 26.04).
# Usage: ./install-i3.sh
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Warning: this does not look like WSL. Continuing anyway..." >&2
fi

echo "==> Updating package lists"
sudo apt-get update

echo "==> Installing i3 and X utilities"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  i3 i3status i3lock dmenu rofi \
  xserver-xephyr xinit x11-xserver-utils x11-utils x11-apps \
  xterm dbus-x11 feh \
  fonts-dejavu-core fonts-noto-color-emoji \
  iproute2

# Give i3 a config so the first-run wizard doesn't appear.
# The stock config uses Alt (Mod1) as the modifier, which is what we want on
# Windows, because Windows grabs most Win-key shortcuts before Linux sees them.
CFG_DIR="$HOME/.config/i3"
if [[ ! -f "$CFG_DIR/config" ]]; then
  echo "==> Creating $CFG_DIR/config (modifier = Alt)"
  mkdir -p "$CFG_DIR"
  cp /etc/i3/config "$CFG_DIR/config"
  # Alt+d: use rofi instead of dmenu. Replace the stock binding rather than
  # adding a second one, since i3 rejects duplicate keybindings.
  sed -i -E 's/^bindsym \$mod\+d exec .*dmenu.*/bindsym $mod+d exec --no-startup-id rofi -show drun/' \
    "$CFG_DIR/config"
  grep -q 'rofi -show drun' "$CFG_DIR/config" ||
    echo 'bindsym $mod+d exec --no-startup-id rofi -show drun' >> "$CFG_DIR/config"
  cat >> "$CFG_DIR/config" <<'CFG'

# --- WSL additions ---
# Solid background
exec --no-startup-id xsetroot -solid "#1e1e2e"
CFG
else
  echo "==> $CFG_DIR/config already exists, leaving it alone"
fi

echo
echo "Done. Start i3 with one of:"
echo "  ./start-i3-wslg.sh            (i3 in a window, uses WSLg, nothing to install on Windows)"
echo "  ./start-i3-windows-xserver.sh (full screen via VcXsrv/X410 on Windows)"
echo "  ./setup-xrdp.sh               (full desktop via Windows Remote Desktop)"
