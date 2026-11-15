#!/usr/bin/env bash
# Run i3 inside a nested X server (Xephyr) displayed through WSLg.
# Usage: ./start-i3-wslg.sh [auto|full|WIDTHxHEIGHT] [display-number] [--monitor N|largest]
#   auto  (default) window sized to 90% of the monitor
#   full  fullscreen on the monitor
#   --monitor N        use monitor N (1, 2, ... as listed by --monitors)
#   --monitor largest  use the biggest monitor
#   --monitors         list your monitors and exit
#   --windows N        one i3 spread over N windows (2-4); i3 treats each window
#                      as a monitor. Window 1 goes on your primary monitor, the
#                      others on your other monitors (or side by side if you
#                      have fewer monitors than windows).
#   --dpi N            font scaling: 96 is normal, 120 = 125%, 144 = 150%
#   Without --monitor, your primary Windows monitor is used.
#   Look (also as environment variables, e.g. I3_DPI=120 ./start-i3-wslg.sh):
#     I3_TITLE         window title (default "i3 (WSL)")
#     I3_CURSOR_THEME  mouse cursor theme (default Adwaita), I3_CURSOR_SIZE (24)
#   e.g. ./start-i3-wslg.sh full --monitor 2
#        ./start-i3-wslg.sh full --monitor largest
#        ./start-i3-wslg.sh full --windows 2
#        ./start-i3-wslg.sh 2560x1440 2
set -euo pipefail

MODE="auto"; DNUM="1"; MONITOR=""; LIST=0; WINDOWS=1; DPI="${I3_DPI:-}"
pos=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --monitor)   MONITOR="${2:?--monitor needs a number or 'largest'}"; shift ;;
    --monitor=*) MONITOR="${1#*=}" ;;
    --monitors)  LIST=1 ;;
    --windows)   WINDOWS="${2:?--windows needs a number}"; shift ;;
    --windows=*) WINDOWS="${1#*=}" ;;
    --dpi)       DPI="${2:?--dpi needs a number, e.g. 120}"; shift ;;
    --dpi=*)     DPI="${1#*=}" ;;
    *) if [[ $pos -eq 0 ]]; then MODE="$1"; else DNUM="$1"; fi; pos=$((pos + 1)) ;;
  esac
  shift
done

if [[ -n "$DPI" ]] && ! [[ "$DPI" =~ ^[0-9]{2,3}$ ]]; then
  echo "--dpi must be a number like 96, 120 or 144." >&2
  exit 1
fi

if ! [[ "$WINDOWS" =~ ^[1-4]$ ]]; then
  echo "--windows must be 1, 2, 3 or 4." >&2
  exit 1
fi

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

# start_xephyr <screen args...>: start Xephyr and wait until it really answers.
start_xephyr() {
  # -noreset: keep running (and keep the keyboard setup) when a short-lived
  # client like xdpyinfo or setxkbmap disconnects. The EXIT trap stops Xephyr.
  Xephyr ":$DNUM" "$@" -ac -br -noreset ${DPI:+-dpi "$DPI"} \
    -title "${I3_TITLE:-i3 (WSL)}" >"/tmp/xephyr-$DNUM.log" 2>&1 &
  XPID=$!
  for _ in $(seq 1 100); do
    kill -0 "$XPID" 2>/dev/null || return 1
    display_alive && return 0
    sleep 0.1
  done
  kill "$XPID" 2>/dev/null || true
  return 1
}

# Where to move each window after it opens (left empty when nothing to move)
WIN_X=(); WIN_Y=(); WIN_FULL=()

# ---------------------------------------------------------------- one window
if [[ $WINDOWS -eq 1 ]]; then
  echo "==> Starting Xephyr on :$DNUM ($SIZE$([[ $FULLSCREEN -eq 1 ]] && echo ', fullscreen')${MON_OUTPUT:+ on $MON_OUTPUT})  -- press Ctrl+Shift to grab/release keyboard"
  echo "    Moving the window to another monitor? Maximize it there and i3 resizes,"
  echo "    or start on that monitor:  $0 full --monitor N   (list: $0 --monitors)"

  XARGS=(-screen "$SIZE" -resizeable)
  # Fullscreen on the primary monitor: Xephyr can do that itself. On another
  # monitor, open a normal window first, move it there, then make it fullscreen
  # (Xephyr's own -output option crashes under WSLg).
  [[ $FULLSCREEN -eq 1 && $OTHER_MONITOR -eq 0 ]] && XARGS+=(-fullscreen)
  if [[ $OTHER_MONITOR -eq 1 ]]; then
    WIN_X=("${MON_X:-0}"); WIN_Y=("${MON_Y:-0}"); WIN_FULL=("$FULLSCREEN")
  fi

# ---------------------------------------------------------------- several windows
# One X screen made of several windows (Xinerama); i3 sees each window as a
# monitor. Window 1 goes on the primary monitor, the next ones on the other
# monitors; windows that share a monitor are placed side by side.
else
  [[ -n "$MONITOR" ]] && echo "    (--monitor is ignored with --windows: windows are spread over your monitors.)"
  mapfile -t MONS < <(list_monitors | awk '$4 == 1'; list_monitors | awk '$4 != 1')
  [[ ${#MONS[@]} -eq 0 ]] && MONS=("1 $MON_SIZE ? 1 0 0")
  XARGS=(); WIN_X=(); WIN_Y=(); WIN_FULL=(); DESC=()
  for ((k = 0; k < WINDOWS; k++)); do
    # Which monitor, and how many windows share it
    if (( k < ${#MONS[@]} )); then m=$k; else m=0; fi
    if (( m == 0 )); then
      share=$(( WINDOWS > ${#MONS[@]} ? WINDOWS - ${#MONS[@]} + 1 : 1 ))
      idx=$(( k == 0 ? 0 : k - ${#MONS[@]} + 1 ))
    else
      share=1; idx=0
    fi
    read -r _ msize mout _ mx my <<<"${MONS[$m]}"
    read -r mw mh < <(tr 'x' ' ' <<<"$msize")
    full=0
    case "$MODE" in
      full|fullscreen)
        if (( share == 1 )); then w=$mw; h=$mh; x=$mx; y=$my; full=1
        else w=$(( mw / share )); h=$mh; x=$(( mx + idx * w )); y=$my; fi ;;
      auto)
        w=$(( mw * 9 / 10 / share )); h=$(( mh * 9 / 10 ))
        x=$(( mx + mw / 20 + idx * w )); y=$(( my + mh / 20 )) ;;
      *)
        read -r w h < <(tr 'x' ' ' <<<"$SIZE")
        x=$(( mx + idx * w )); y=$my ;;
    esac
    XARGS+=(-screen "${w}x${h}")
    WIN_X+=("$x"); WIN_Y+=("$y"); WIN_FULL+=("$full")
    note=""; [[ $full -eq 1 ]] && note=", fullscreen"
    DESC+=("$((k + 1)): ${w}x${h} on $mout$note")
  done
  XARGS+=(+xinerama)
  echo "==> Starting Xephyr on :$DNUM with $WINDOWS windows  -- press Ctrl+Shift to grab/release keyboard"
  printf '    window %s\n' "${DESC[@]}"
  echo "    Alt+o: focus the next window   Alt+Shift+o: move a window there   Alt+Ctrl+o: move the workspace"
fi

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

# make_fullscreen <host window id>: WSLg ignores a "go fullscreen" request
# sent to a window that is already open; it only honours the fullscreen flag
# when a window appears. So hide the window, set the flag, and show it again
# (it stays on the monitor it was moved to). The request is sent as well, for
# window managers that do honour it.
make_fullscreen() {
  local id="$1"
  command -v xprop >/dev/null 2>&1 || return 1
  timeout 3 xdotool windowunmap --sync "$id" 2>/dev/null || return 1
  xprop -id "$id" -f _NET_WM_STATE 32a -set _NET_WM_STATE _NET_WM_STATE_FULLSCREEN 2>/dev/null
  timeout 3 xdotool windowmap --sync "$id" 2>/dev/null || xdotool windowmap "$id" 2>/dev/null || return 1
  xdotool windowstate --add FULLSCREEN "$id" 2>/dev/null || true
}

# Move each window into place (and make it fullscreen there). Xephyr creates
# its windows in screen order, so sorting the window ids gives window 1, 2, ...
if [[ ${#WIN_X[@]} -gt 0 ]]; then
  if command -v xdotool >/dev/null 2>&1; then
    WIDS=()
    for _ in $(seq 1 50); do
      mapfile -t WIDS < <(xdotool search --name '^i3 \(WSL\)$' 2>/dev/null | sort -n)
      (( ${#WIDS[@]} >= ${#WIN_X[@]} )) && break
      sleep 0.1
    done
    if (( ${#WIDS[@]} >= ${#WIN_X[@]} )); then
      for ((k = 0; k < ${#WIN_X[@]}; k++)); do
        xdotool windowmove "${WIDS[$k]}" "${WIN_X[$k]}" "${WIN_Y[$k]}" 2>/dev/null || true
      done
      sleep 0.3
      for ((k = 0; k < ${#WIN_X[@]}; k++)); do
        if [[ ${WIN_FULL[$k]} -eq 1 ]]; then
          make_fullscreen "${WIDS[$k]}" ||
            echo "    (Couldn't make window $((k + 1)) fullscreen; maximize it instead.)"
        fi
      done
    else
      echo "    (Couldn't find the windows to move them; drag them where you want them.)"
    fi
  else
    echo "    (xdotool missing, so the windows can't be moved automatically: sudo apt install xdotool)"
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

# Make the empty i3 window look finished before i3 draws anything: a normal
# arrow cursor instead of X's big cross, the theme's background colour
# instead of black, and smooth (anti-aliased) fonts.
CURSOR_THEME="${I3_CURSOR_THEME:-Adwaita}"
CURSOR_SIZE="${I3_CURSOR_SIZE:-24}"
[[ -d "/usr/share/icons/$CURSOR_THEME/cursors" || -d "$HOME/.icons/$CURSOR_THEME/cursors" ]] || CURSOR_THEME=""
style_display() {
  local bg
  bg="$(sed -n 's/^exec_always --no-startup-id xsetroot -solid "\(#[0-9A-Fa-f]\{6\}\)".*/\1/p' \
        "$HOME/.config/i3/generated/theme.conf" 2>/dev/null | head -1)"
  if command -v xrdb >/dev/null 2>&1; then
    {
      echo "Xft.antialias: 1"
      echo "Xft.hinting: 1"
      echo "Xft.hintstyle: hintslight"
      echo "Xft.rgba: rgb"
      echo "Xft.lcdfilter: lcddefault"
      [[ -n "$DPI" ]] && echo "Xft.dpi: $DPI"
      if [[ -n "$CURSOR_THEME" ]]; then
        echo "Xcursor.theme: $CURSOR_THEME"
        echo "Xcursor.size: $CURSOR_SIZE"
      fi
    } | DISPLAY=":$DNUM" xrdb -nocpp -merge - 2>/dev/null || true
  fi
  if command -v xsetroot >/dev/null 2>&1; then
    DISPLAY=":$DNUM" xsetroot -cursor_name left_ptr ${bg:+-solid "$bg"} 2>/dev/null || true
  fi
}
style_display

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

# Apps started from i3 (Chrome, VS Code, ...) use the same cursor
CURSOR_ENV=()
[[ -n "$CURSOR_THEME" ]] && CURSOR_ENV=(XCURSOR_THEME="$CURSOR_THEME" XCURSOR_SIZE="$CURSOR_SIZE")
echo "==> Launching i3 (modifier is Alt; Alt+Enter = terminal, Alt+Shift+e = exit)"
I3_ARGS=()
# With several windows RandR reports only one monitor, so i3 must read the
# window layout from Xinerama instead.
if [[ $WINDOWS -gt 1 ]]; then
  I3_ARGS=(--force-xinerama)
  # i3 warns about Xinerama on every start; here it's expected, so hide that line
  { DISPLAY=":$DNUM" WAYLAND_DISPLAY= env "${CURSOR_ENV[@]}" dbus-launch --exit-with-session i3 "${I3_ARGS[@]}" 2>&1; } |
    { grep -v --line-buffered 'Using Xinerama instead of RandR' || true; }
else
  DISPLAY=":$DNUM" WAYLAND_DISPLAY= env "${CURSOR_ENV[@]}" dbus-launch --exit-with-session i3
fi
