#!/usr/bin/env bash
# Install i3 and the X tools needed to run it on WSL2 (Ubuntu 26.04), and the
# i3 config from this repo (config/i3/).
# Usage: ./install-i3.sh            install packages and the i3 config
#        ./install-i3.sh --config   only (re)install the i3 config, e.g. after git pull
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY_CONFIG=0
[[ "${1:-}" == "--config" ]] && ONLY_CONFIG=1

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

if [[ $ONLY_CONFIG -eq 0 ]]; then
  if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Warning: this does not look like WSL. Continuing anyway..." >&2
  fi

  echo "==> Updating package lists"
  sudo apt-get update

  echo "==> Installing i3 and X utilities"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    i3 i3status i3lock dmenu rofi \
    xserver-xephyr xinit x11-xserver-utils x11-utils x11-apps \
    xterm dbus-x11 feh x11-xkb-utils xdotool \
    fonts-dejavu-core fonts-noto-color-emoji \
    iproute2
fi

# ---------------------------------------------------------------- i3 config
# ~/.config/i3/
#   config                 from config/i3/config, replaced on every run
#   generated/theme.conf   colours (set-theme.sh)
#   generated/bar.conf     the bar (set-theme.sh; plain one from config/i3/bar.conf)
#   config.d/custom.conf   your own settings, never overwritten
CFG_DIR="$HOME/.config/i3"
CFG="$CFG_DIR/config"
GEN="$CFG_DIR/generated"
MARKER='^# i3 config from wsl-ubuntu-i3'
mkdir -p "$GEN" "$CFG_DIR/config.d" "$HOME/.local/bin"

# An older config (stock i3 config patched by earlier versions of these
# scripts): remember its theme and back it up once before replacing it.
OLD_THEME=""
if [[ -f "$CFG" ]] && ! grep -q "$MARKER" "$CFG"; then
  OLD_THEME="$(sed -n 's/^# theme: //p' "$CFG" | head -1)"
  if [[ ! -e "$CFG.pre-wsl-i3" ]]; then
    cp -a "$CFG" "$CFG.pre-wsl-i3"
    echo "==> Backed up your old i3 config to $CFG.pre-wsl-i3"
  fi
fi

# Alt+Enter runs this terminal wrapper
install -m 755 "$REPO/tools/i3-term" "$HOME/.local/bin/i3-term"
# Alt+Shift+f runs this: make the i3 window fill its monitor
install -m 755 "$REPO/tools/i3-fit" "$HOME/.local/bin/i3-fit"

# Files the config includes; create the ones that don't exist yet
[[ -f "$GEN/bar.conf" ]] || cp "$REPO/config/i3/bar.conf" "$GEN/bar.conf"
[[ -f "$GEN/theme.conf" ]] || printf '# No theme set yet. Run ./set-theme.sh <theme> to pick one.\n' > "$GEN/theme.conf"
[[ -f "$CFG_DIR/config.d/custom.conf" ]] || cp "$REPO/config/i3/custom.conf" "$CFG_DIR/config.d/custom.conf"

# Check the new config before putting it in place
if command -v i3 >/dev/null 2>&1 && ! i3 -C -c "$REPO/config/i3/config" >/dev/null 2>&1; then
  echo "The i3 config has errors, so your current one was kept. Details:" >&2
  i3 -C -c "$REPO/config/i3/config" >&2 || true
  echo "If the errors are in config.d/custom.conf, fix that file and run: $0 --config" >&2
  exit 1
fi
cp "$REPO/config/i3/config" "$CFG"
echo "==> Installed $CFG"

# Carry the colour theme over from an old config
if [[ -n "$OLD_THEME" ]] && ! grep -q '^# theme: ' "$GEN/theme.conf"; then
  "$REPO/set-theme.sh" "$OLD_THEME"
fi

# Reload any running i3 so it picks up the new config
for sock in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/i3/ipc-socket.*; do
  [[ -S "$sock" ]] && i3-msg -s "$sock" reload >/dev/null 2>&1 || true
done

echo
if [[ $ONLY_CONFIG -eq 1 ]]; then
  echo "Done. Your own i3 settings go in $CFG_DIR/config.d/custom.conf"
  exit 0
fi
echo "Done. Start i3 with one of:"
echo "  ./start-i3-wslg.sh            (i3 in a window, uses WSLg, nothing to install on Windows)"
echo "  ./start-i3-windows-xserver.sh (full screen via VcXsrv/X410 on Windows)"
echo "  ./setup-xrdp.sh               (full desktop via Windows Remote Desktop)"
echo "Your own i3 settings go in $CFG_DIR/config.d/custom.conf"
