#!/usr/bin/env bash
# Install openfortivpn, a client for Fortinet (FortiGate) SSL VPNs, in WSL,
# and create a settings file to fill in.
# Usage: ./install-openfortivpn.sh
#
# Connect afterwards with:
#   sudo openfortivpn -c ~/.config/openfortivpn/config
# The VPN only covers WSL (and the apps in i3), not Windows itself.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

echo "==> Installing openfortivpn"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openfortivpn ppp

CFG="$HOME/.config/openfortivpn/config"
if [[ ! -f "$CFG" ]]; then
  mkdir -p "$(dirname "$CFG")"
  cat > "$CFG" <<'CONF'
# openfortivpn settings, created by install-openfortivpn.sh.
# Fill in your VPN details, then connect with:
#   sudo openfortivpn -c ~/.config/openfortivpn/config
# All options: man openfortivpn

host = vpn.example.com
port = 443
username = your.name

# Leave the password out to be asked each time (safer than storing it here).
# password = ...

# On the first connection openfortivpn may refuse the server certificate and
# print its sha256 fingerprint. If your IT team confirms it, add it here:
# trusted-cert = 0123456789abcdef...

# Let the VPN set DNS servers (needed to reach internal names)
set-dns = 1
pppd-use-peerdns = 1

# Some VPNs need a realm or a second factor:
# realm = ...
# otp = ...
CONF
  chmod 600 "$CFG"   # it may hold your username/password
  echo "==> Created $CFG (only readable by you); fill in host and username"
else
  echo "==> Keeping your existing $CFG"
fi

if [[ ! -e /dev/ppp ]]; then
  echo "    Note: /dev/ppp is missing, which openfortivpn needs. Run 'wsl --update' in"
  echo "    PowerShell, then 'wsl --shutdown', and reopen Ubuntu."
fi

echo
echo "Done. Connect with:  sudo openfortivpn -c $CFG"
echo "Disconnect with Ctrl+C in that terminal."
