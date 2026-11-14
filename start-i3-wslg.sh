#!/usr/bin/env bash
# Run i3 inside a nested X server (Xephyr) displayed through WSLg.
# Usage: ./start-i3-wslg.sh [auto|full|WIDTHxHEIGHT] [display-number]
#   auto  (default) window sized to 90% of your primary monitor
#   full  fullscreen on your primary monitor
#   e.g. ./start-i3-wslg.sh full
#        ./start-i3-wslg.sh 2560x1440 2
set -euo pipefail

MODE="${1:-auto}"
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

# Print the primary monitor's size as WIDTHxHEIGHT, as WSLg reports it.
monitor_size() {
  local size
  # "xrandr --listmonitors" lines look like: " 0: +*XWAYLAND0 1920/518x1200/324+0+0  XWAYLAND0"
  # Prefer the primary monitor (marked with *), otherwise take the first one.
  size=$(xrandr --listmonitors 2>/dev/null | awk '
    NR > 1 { split($3, a, /[\/x+]/); s = a[1] "x" a[3]
             if ($2 ~ /\*/) { print s; found = 1; exit }
             if (!first) first = s }
    END    { if (!found && first) print first }')
  # Fallback: size of the whole X screen
  [[ -z "$size" ]] && size=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
  echo "${size:-1920x1080}"
}

EXTRA=()
case "$MODE" in
  auto)
    read -r W H < <(monitor_size | tr 'x' ' ')
    SIZE="$((W * 9 / 10))x$((H * 9 / 10))"
    ;;
  full|fullscreen)
    SIZE=$(monitor_size)
    EXTRA=(-fullscreen)
    ;;
  [0-9]*x[0-9]*)
    SIZE="$MODE"
    ;;
  *)
    echo "Unknown size '$MODE'. Use auto, full or WIDTHxHEIGHT (e.g. 1920x1080)." >&2
    exit 1
    ;;
esac

if [[ -e "/tmp/.X11-unix/X$DNUM" ]]; then
  echo "Display :$DNUM is already in use. Pick another: $0 $MODE $((DNUM + 1))" >&2
  exit 1
fi

echo "==> Starting Xephyr on :$DNUM ($SIZE${EXTRA:+, fullscreen})  -- press Ctrl+Shift to grab/release keyboard"
echo "    Tip: you can also resize or maximize the window; i3 adapts to the new size."
Xephyr ":$DNUM" -screen "$SIZE" "${EXTRA[@]}" -resizeable -ac -br -reset -terminate \
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
