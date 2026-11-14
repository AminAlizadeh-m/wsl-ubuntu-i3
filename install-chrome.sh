#!/usr/bin/env bash
# Install Google Chrome (the Linux version) in WSL, to use inside i3.
# Uses Google's official .deb, which also adds Google's apt repository, so
# Chrome updates with the rest of the system (sudo apt upgrade).
# Usage: ./install-chrome.sh
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "Google Chrome for Linux is only available for 64-bit Intel/AMD (amd64)." >&2
  echo "On this machine, install Chromium instead:  sudo apt install chromium" >&2
  exit 1
fi

if command -v google-chrome-stable >/dev/null 2>&1; then
  echo "==> Google Chrome is already installed; updating it"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade google-chrome-stable
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "==> Downloading Google Chrome"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wget ca-certificates
  wget -q --show-progress -O "$TMP/google-chrome-stable_current_amd64.deb" \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  echo "==> Installing Google Chrome"
  # apt installs Chrome's dependencies too; _apt needs to be able to read the file
  chmod 755 "$TMP"; chmod 644 "$TMP"/*.deb
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$TMP/google-chrome-stable_current_amd64.deb"
fi

echo
echo "Done. In i3, press Alt+d and type 'chrome', or run: google-chrome"
echo "If Chrome shows a black or blank window, start it with: google-chrome --disable-gpu"
