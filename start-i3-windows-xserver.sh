#!/usr/bin/env bash
# Run i3 against an X server running on Windows (VcXsrv, X410, GWSL...).
#
# On Windows first start the X server in a single big window / fullscreen mode:
#   VcXsrv (XLaunch): "One large window" or "Fullscreen", display number 0,
#                     tick "Disable access control".
#   X410:             "Floating Desktop" mode, enable "Allow Public Access".
# Allow the X server through Windows Firewall when prompted.
#
# Usage: ./start-i3-windows-xserver.sh [display-number]
set -euo pipefail

DNUM="${1:-0}"

# With WSL mirrored networking, Windows is reachable on localhost;
# otherwise use the default gateway (the Windows host's address on the WSL NAT).
if [[ "$(wslinfo --networking-mode 2>/dev/null || true)" == "mirrored" ]]; then
  HOST="127.0.0.1"
else
  HOST="$(ip route show default | awk '{print $3; exit}')"
fi

export DISPLAY="$HOST:$DNUM"
unset WAYLAND_DISPLAY   # keep apps from drawing through WSLg instead
export LIBGL_ALWAYS_INDIRECT=1

echo "==> Using DISPLAY=$DISPLAY"
if ! timeout 3 xset q >/dev/null 2>&1; then
  echo "Cannot reach an X server at $DISPLAY." >&2
  echo "Check that VcXsrv/X410 is running, access control is disabled," >&2
  echo "and Windows Firewall allows it on Public networks." >&2
  exit 1
fi

# Links opened from apps in i3 (e.g. VS Code's "Sign in with GitHub") go to a
# Linux browser in i3 instead of Windows' browser (see tools/i3-browser-env).
BROWSER_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools/i3-browser-env"
if [[ -x "$BROWSER_ENV" ]]; then
  while IFS= read -r kv; do export "${kv?}"; done < <("$BROWSER_ENV")
fi

echo "==> Launching i3 (modifier is Alt; Alt+Enter = terminal, Alt+Shift+e = exit)"
exec dbus-launch --exit-with-session i3
