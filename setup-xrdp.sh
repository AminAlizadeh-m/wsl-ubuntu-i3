#!/usr/bin/env bash
# Set up xrdp so you can log into a full i3 desktop with Windows Remote Desktop.
# Requires systemd in WSL (Ubuntu enables it by default; see /etc/wsl.conf).
# Usage: ./setup-xrdp.sh [port]   (default 3390, so it doesn't clash with Windows' own RDP on 3389)
set -euo pipefail

PORT="${1:-3390}"

if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
  echo "systemd is not running. Add this to /etc/wsl.conf, then run 'wsl --shutdown' in PowerShell:" >&2
  printf '\n[boot]\nsystemd=true\n\n' >&2
  exit 1
fi

echo "==> Installing xrdp"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y xrdp xorgxrdp

echo "==> Setting xrdp port to $PORT"
sudo sed -i -E "s/^port=.*/port=$PORT/" /etc/xrdp/xrdp.ini

# Let xrdp read the TLS key
sudo adduser xrdp ssl-cert >/dev/null 2>&1 || true

echo "==> Making i3 the session for RDP logins"
cat > "$HOME/.xsession" <<'XS'
#!/bin/sh
unset WAYLAND_DISPLAY
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session i3
XS
chmod +x "$HOME/.xsession"

sudo systemctl enable --now xrdp
sudo systemctl restart xrdp

echo
echo "Done. On Windows run:  mstsc /v:localhost:$PORT"
echo "Log in with your Linux username and password (Session: Xorg)."
echo "If localhost doesn't connect, use this WSL IP instead: $(hostname -I | awk '{print $1}')"
