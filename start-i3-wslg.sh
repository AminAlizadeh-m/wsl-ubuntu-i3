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

# List monitors as WSLg reports them, one per line:
#   "<n> <WIDTHxHEIGHT> <output> <primary 0/1> <x> <y>"
# from "xrandr --listmonitors" lines like: " 0: +*rdp-0 1920/518x1200/324+0+0  rdp-0"
list_monitors() {
  xrandr --listmonitors 2>/dev/null | awk '
    NR > 1 { split($3, a, /[\/x+]/)
             print NR - 1, a[1] "x" a[3], $NF, ($2 ~ /\*/) ? 1 : 0, a[5] + 0, a[6] + 0 }'
}

if [[ $LIST -eq 1 ]]; then
  echo "Monitors (use with --monitor N):"
  list_monitors | while read -r n size out primary x y; do
    echo "  $n: $size at +$x+$y ($out)$([[ $primary == 1 ]] && echo '  primary')"
  done
  exit 0
fi

# Pick the monitor: --monitor N, --monitor largest, else primary, else the first.
PRIMARY_LINE=$(list_monitors | awk '$4 == 1 {print; exit}')
[[ -z "$PRIMARY_LINE" ]] && PRIMARY_LINE=$(list_monitors | head -1)
case "$MONITOR" in
  "")      MON_LINE="$PRIMARY_LINE" ;;
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
read -r _ MON_SIZE MON_OUTPUT _ MON_X MON_Y <<<"$MON_LINE" || true
# Fallback if xrandr gave nothing: size of the whole X screen
[[ -z "${MON_SIZE:-}" ]] && MON_SIZE=$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
MON_SIZE="${MON_SIZE:-1920x1080}"
# Is the chosen monitor somewhere other than the primary one?
OTHER_MONITOR=0
[[ -n "$MON_LINE" && "$MON_LINE" != "$PRIMARY_LINE" ]] && OTHER_MONITOR=1

FULLSCREEN=0
case "$MODE" in
  auto)
    read -r W H < <(tr 'x' ' ' <<<"$MON_SIZE")
    SIZE="$((W * 9 / 10))x$((H * 9 / 10))"
    ;;
  full|fullscreen)
    SIZE="$MON_SIZE"
    FULLSCREEN=1
    ;;
  [0-9]*x[0-9]*)
    SIZE="$MODE"
    ;;
  *)
    echo "Unknown size '$MODE'. Use auto, full or WIDTHxHEIGHT (e.g. 1920x1080)." >&2
    exit 1
    ;;
esac

# Is an X server really answering on :DNUM?
display_alive() { DISPLAY=":$DNUM" xdpyinfo >/dev/null 2>&1; }

# A crashed Xephyr leaves its lock and socket files behind, which would block
# the display number. Remove them if nothing is actually running there.
clean_stale() {
  display_alive && return 0
  rm -f "/tmp/.X$DNUM-lock" "/tmp/.X11-unix/X$DNUM" 2>/dev/null || true
}

if display_alive; then
  echo "Display :$DNUM is already in use. Pick another: $0 $MODE $((DNUM + 1))${MONITOR:+ --monitor $MONITOR}" >&2
  exit 1
fi
clean_stale

echo "==> Starting Xephyr on :$DNUM ($SIZE$([[ $FULLSCREEN -eq 1 ]] && echo ', fullscreen')${MON_OUTPUT:+ on $MON_OUTPUT})  -- press Ctrl+Shift to grab/release keyboard"
echo "    Moving the window to another monitor? Maximize it there and i3 resizes,"
echo "    or start on that monitor:  $0 full --monitor N   (list: $0 --monitors)"

# start_xephyr <extra args...>: start Xephyr and wait until it really answers.
start_xephyr() {
  # -noreset: keep running (and keep the keyboard setup) when a short-lived
  # client like xdpyinfo or setxkbmap disconnects. The EXIT trap stops Xephyr.
  Xephyr ":$DNUM" -screen "$SIZE" "$@" -resizeable -ac -br -noreset \
    -title "i3 (WSL)" >"/tmp/xephyr-$DNUM.log" 2>&1 &
  XPID=$!
  for _ in $(seq 1 100); do
    kill -0 "$XPID" 2>/dev/null || return 1
    display_alive && return 0
    sleep 0.1
  done
  kill "$XPID" 2>/dev/null || true
  return 1
}

XARGS=()
# Fullscreen on the primary monitor: Xephyr can do that itself. On another
# monitor, open a normal window first, move it there, then make it fullscreen
# (Xephyr's own -output option crashes under WSLg).
[[ $FULLSCREEN -eq 1 && $OTHER_MONITOR -eq 0 ]] && XARGS=(-fullscreen)

if ! start_xephyr "${XARGS[@]}"; then
  echo "Xephyr failed to start. Log:" >&2
  cat "/tmp/xephyr-$DNUM.log" >&2
  clean_stale
  exit 1
fi
WATCH_PID=""
# Every step must be allowed to fail: with set -e a failing command would end
# the trap early and leave the Xephyr window open.
trap 'kill $WATCH_PID 2>/dev/null || true; kill "$XPID" 2>/dev/null && wait "$XPID" 2>/dev/null || true; clean_stale || true' EXIT

# Move the window to the chosen monitor (and make it fullscreen there).
if [[ $OTHER_MONITOR -eq 1 ]]; then
  if command -v xdotool >/dev/null 2>&1 &&
     WID=$(timeout 5 xdotool search --sync --name '^i3 \(WSL\)$' 2>/dev/null | head -1) &&
     [[ -n "$WID" ]]; then
    xdotool windowmove "$WID" "${MON_X:-0}" "${MON_Y:-0}" 2>/dev/null || true
    if [[ $FULLSCREEN -eq 1 ]]; then
      sleep 0.3
      xdotool windowstate --add FULLSCREEN "$WID" 2>/dev/null ||
        echo "    (Couldn't make it fullscreen; maximize the window instead.)"
    fi
  else
    echo "    (Couldn't move the window automatically; drag it to $MON_OUTPUT and maximize it.)"
  fi
fi

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
  release_modifiers
}

# Tell Xephyr that all modifier keys are up.
release_modifiers() {
  command -v xdotool >/dev/null 2>&1 || return 0
  DISPLAY=":$DNUM" xdotool keyup Alt_L Alt_R Meta_L Meta_R Super_L Super_R \
    Control_L Control_R Shift_L Shift_R 2>/dev/null || true
}
fix_keyboard

# Keys released while another window has focus (e.g. Alt+Tab to a Windows
# app) never reach Xephyr, so Alt stays held: every d opens the launcher and
# every Enter a terminal. tools/unstick-keys.py compares the held modifier
# keys with WSLg's X server (which follows the real keyboard) and releases
# any that are only stuck inside Xephyr.
UNSTICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools/unstick-keys.py"
if command -v xdotool >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [[ -f "$UNSTICK" ]]; then
  python3 -I "$UNSTICK" "$DISPLAY" ":$DNUM" &
  WATCH_PID=$!
fi

echo "==> Launching i3 (modifier is Alt; Alt+Enter = terminal, Alt+Shift+e = exit)"
DISPLAY=":$DNUM" WAYLAND_DISPLAY= dbus-launch --exit-with-session i3
