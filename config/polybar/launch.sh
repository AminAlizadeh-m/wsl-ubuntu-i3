#!/usr/bin/env bash
# Start polybar on every monitor. i3 runs this on start and restart:
#   exec_always --no-startup-id ~/.config/polybar/launch.sh

# Stop your running bars, and wait until they're gone
pkill -u "$UID" -x polybar
while pgrep -u "$UID" -x polybar >/dev/null; do sleep 0.2; done

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/polybar"
mkdir -p "$LOG_DIR"

# One bar per monitor (polybar --list-monitors), or one bar if that fails
monitors=$(polybar --list-monitors 2>/dev/null | cut -d: -f1)
if [[ -z "$monitors" ]]; then
  polybar --reload main >"$LOG_DIR/main.log" 2>&1 &
else
  for m in $monitors; do
    MONITOR="$m" polybar --reload main >"$LOG_DIR/$m.log" 2>&1 &
  done
fi
disown -a
