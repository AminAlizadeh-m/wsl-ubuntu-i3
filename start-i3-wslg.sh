#!/usr/bin/env bash
# Run i3 inside a nested X server (Xephyr) displayed through WSLg.
# Usage: ./start-i3-wslg.sh [WIDTHxHEIGHT] [display-number]
#   e.g. ./start-i3-wslg.sh 2560x1440 2
set -euo pipefail

SIZE="${1:-1920x1080}"
DNUM="${2:-1}"

if [[ -z "${DISPLAY:-}" ]]; then
  echo "DISPLAY is not set; WSLg does not seem to be running." >&2
  echo "Run 'wsl --update' in Windows PowerShell, then 'wsl --shutdown' and reopen Ubuntu." >&2
  exit 1
fi

# On some WSL versions /tmp/.X11-unix is mounted read-only, so Xephyr cannot
# create its socket there. Remount it read-write if needed.
if [[ ! -w /tmp/.X11-unix ]]; then
  echo "==> /tmp/.X11-unix is read-only, remounting read-write (needs sudo)"
  sudo mount -o remount,rw /tmp/.X11-unix || true
fi

if [[ -e "/tmp/.X11-unix/X$DNUM" ]]; then
  echo "Display :$DNUM is already in use. Pick another: $0 $SIZE $((DNUM + 1))" >&2
  exit 1
fi

echo "==> Starting Xephyr on :$DNUM ($SIZE)  -- press Ctrl+Shift to grab/release keyboard"
Xephyr ":$DNUM" -screen "$SIZE" -resizeable -ac -br -reset -terminate \
  -title "i3 (WSL)" >/tmp/xephyr-$DNUM.log 2>&1 &
XPID=$!

# Wait for the X server to come up
for _ in $(seq 1 50); do
  [[ -e "/tmp/.X11-unix/X$DNUM" ]] && break
  if ! kill -0 "$XPID" 2>/dev/null; then
    echo "Xephyr failed to start. Log:" >&2
    cat "/tmp/xephyr-$DNUM.log" >&2
    exit 1
  fi
  sleep 0.1
done

trap 'kill "$XPID" 2>/dev/null || true' EXIT

echo "==> Launching i3 (modifier is Alt; Alt+Enter = terminal, Alt+Shift+e = exit)"
DISPLAY=":$DNUM" WAYLAND_DISPLAY= dbus-launch --exit-with-session i3
