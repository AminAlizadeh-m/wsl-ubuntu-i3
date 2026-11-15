#!/usr/bin/env bash
# Install plain, classic i3: Ubuntu's i3 packages and nothing else.
# No themes, no extra services, no config files: on first start i3 runs its
# own setup wizard and writes its stock config, exactly like a fresh i3.
#
# Works on normal Ubuntu and on WSL:
#   - Ubuntu: log out, pick "i3" on the login screen, log in.
#   - WSL:    also installs Xephyr (a window to show i3 in) and xterm, then
#             start i3 with:  ./install-i3-classic.sh start
#
# Usage: ./install-i3-classic.sh          install
#        ./install-i3-classic.sh start    (WSL) open i3 in a window
set -euo pipefail

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

if [[ "${1:-}" == "start" ]]; then
  # Open a window (Xephyr) on display :1 and run i3 in it
  Xephyr :1 -screen 1600x900 -resizeable -ac -br -noreset >/dev/null 2>&1 &
  XPID=$!
  trap 'kill "$XPID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do
    DISPLAY=:1 xdpyinfo >/dev/null 2>&1 && break
    sleep 0.1
  done
  DISPLAY=:1 WAYLAND_DISPLAY= i3
  exit 0
fi

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

# i3 = i3-wm + i3status + i3lock + dmenu (the classic set)
PKGS=(i3)
# WSL has no desktop to log into, so i3 needs a window to run in, and a terminal
is_wsl && PKGS+=(xserver-xephyr x11-utils xterm)

echo "==> Installing: ${PKGS[*]}"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"

echo
echo "Done. Classic i3 is installed."
if is_wsl; then
  echo "Start it with:  $0 start"
else
  echo "Log out, choose 'i3' on the login screen (gear icon), and log in."
fi
echo "On first start, i3 asks whether to create a config and which modifier key"
echo "to use (Win or Alt). Mod+Enter opens a terminal, Mod+d opens dmenu."
