#!/usr/bin/env bash
# Run i3 inside a nested X server (Xephyr) displayed through WSLg.
# Usage: ./start-i3-wslg.sh [auto|full|WIDTHxHEIGHT] [display-number] [--monitor N|largest]
#   auto  (default) window sized to 90% of the monitor
#   full  fullscreen on the monitor
#   --monitor N        use monitor N (1, 2, ... as listed by --monitors)
#   --monitor largest  use the biggest monitor
#   --monitors         list your monitors and exit
#   Without --monitor, your primary Windows monitor is used.
#   e.g. ./start-i3-wslg.sh full --monitor 2
#        ./start-i3-wslg.sh full --monitor largest
#        ./start-i3-wslg.sh 2560x1440 2
set -euo pipefail

MODE="auto"; DNUM="1"; MONITOR=""; LIST=0
pos=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --monitor)   MONITOR="${2:?--monitor needs a number or 'largest'}"; shift ;;
    --monitor=*) MONITOR="${1#*=}" ;;
    --monitors)  LIST=1 ;;
    *) if [[ $pos -eq 0 ]]; then MODE="$1"; else DNUM="$1"; fi; pos=$((pos + 1)) ;;
  esac
  shift
done

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

# List monitors as WSLg reports them, one per line: "<n> <WIDTHxHEIGHT> <output> <primary 0/1>"
# from "xrandr --listmonitors" lines like: " 0: +*XWAYLAND0 1920/518x1200/324+0+0  XWAYLAND0"
list_monitors() {
  xrandr --listmonitors 2>/dev/null | awk '
    NR > 1 { split($3, a, /[\/x+]/)
             print NR - 1, a[1] "x" a[3], $NF, ($2 ~ /\*/) ? 1 : 0 }'
}

if [[ $LIST -eq 1 ]]; then
  echo "Monitors (use with --monitor N):"
  list_monitors | while read -r n size out primary; do
    echo "  $n: $size ($out)$([[ $primary == 1 ]] && echo '  primary')"
  done
  exit 0
fi

# Pick the monitor: --monitor N, --monitor largest, else primary, else the first.
MON_LINE=""
case "$MONITOR" in
  "")      MON_LINE=$(list_monitors | awk '$4 == 1 {print; exit}')
           [[ -z "$MON_LINE" ]] && MON_LINE=$(list_monitors | head -1) ;;
  largest) MON_LINE=$(list_monitors | awk '{split($2, s, "x"); a = s[1] * s[2]
                                            if (a > best) { best = a; line = $0 } } END { print line }') ;;
  *[!0-9]*) echo "--monitor must be a number or 'largest'." >&2; exit 1 ;;
  *)       MON_LINE=$(list_monitors | awk -v n="$MONITOR" '$1 == n {print; exit}')
           if [[ -z "$MON_LINE" ]]; then
             echo "There is no monitor $MONITOR. Your monitors:" >&2
             list_monitors | awk '{print "  " $1 ": " $2 " (" $3 ")"}' >&2
             exit 1
           fi ;;
esac
MON_SIZE=$(awk '{print $2}' <<<"$MON_LINE")
MON_OUTPUT=$(awk '{print $3}' <<<"$MON_LINE")
# Fallback if xrandr gave nothing: size of the whole X screen
[[ -z "$MON_SIZE" ]] && MON_SIZE=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
MON_SIZE="${MON_SIZE:-1920x1080}"

EXTRA=()
case "$MODE" in
  auto)
    read -r W H < <(tr 'x' ' ' <<<"$MON_SIZE")
    SIZE="$((W * 9 / 10))x$((H * 9 / 10))"
    ;;
  full|fullscreen)
    SIZE="$MON_SIZE"
    EXTRA=(-fullscreen)
    # Put the fullscreen window on the chosen monitor
    [[ -n "$MON_OUTPUT" ]] && EXTRA+=(-output "$MON_OUTPUT")
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
  echo "Display :$DNUM is already in use. Pick another: $0 $MODE $((DNUM + 1))${MONITOR:+ --monitor $MONITOR}" >&2
  exit 1
fi

WHERE=""; [[ " ${EXTRA[*]} " == *" -output "* ]] && WHERE=" on $MON_OUTPUT"
echo "==> Starting Xephyr on :$DNUM ($SIZE${EXTRA:+, fullscreen}$WHERE)  -- press Ctrl+Shift to grab/release keyboard"
echo "    Moving the window to another monitor? Maximize it there and i3 resizes,"
echo "    or start on that monitor:  $0 full --monitor N   (list: $0 --monitors)"

# start_xephyr <extra args...>: start Xephyr and wait until it's ready; 1 if it died
start_xephyr() {
  Xephyr ":$DNUM" -screen "$SIZE" "$@" -resizeable -ac -br -reset -terminate \
    -title "i3 (WSL)" >"/tmp/xephyr-$DNUM.log" 2>&1 &
  XPID=$!
  for _ in $(seq 1 50); do
    [[ -e "/tmp/.X11-unix/X$DNUM" ]] && return 0
    kill -0 "$XPID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 0
}

if ! start_xephyr "${EXTRA[@]}"; then
  # Some Xephyr builds can't place a fullscreen window on a given output; try without it
  if [[ " ${EXTRA[*]} " == *" -output "* ]] && start_xephyr -fullscreen; then
    echo "    (Couldn't pick the monitor; drag the window to it and maximize instead.)"
  else
    echo "Xephyr failed to start. Log:" >&2
    cat "/tmp/xephyr-$DNUM.log" >&2
    exit 1
  fi
fi

trap 'kill "$XPID" 2>/dev/null || true' EXIT

# WSLg can hand Xephyr a confused keyboard: Alt counted as always held, so
# every Enter opens a terminal and every d opens the launcher. Load a clean
# keyboard layout into Xephyr and release all modifier keys before i3 starts.
fix_keyboard() {
  local layout
  layout="${I3_KB_LAYOUT:-$(setxkbmap -query 2>/dev/null | awk '/^layout:/ {print $2}')}"
  if command -v setxkbmap >/dev/null 2>&1; then
    DISPLAY=":$DNUM" setxkbmap "${layout:-us}" 2>/dev/null ||
      DISPLAY=":$DNUM" setxkbmap us 2>/dev/null || true
  else
    echo "    (setxkbmap missing: sudo apt install x11-xkb-utils)"
  fi
  if command -v xdotool >/dev/null 2>&1; then
    DISPLAY=":$DNUM" xdotool keyup Alt_L Alt_R Meta_L Meta_R Super_L Super_R \
      Control_L Control_R Shift_L Shift_R 2>/dev/null || true
  fi
}
fix_keyboard

echo "==> Launching i3 (modifier is Alt; Alt+Enter = terminal, Alt+Shift+e = exit)"
DISPLAY=":$DNUM" WAYLAND_DISPLAY= dbus-launch --exit-with-session i3
