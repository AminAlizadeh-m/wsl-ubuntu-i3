#!/usr/bin/env bash
# Install Visual Studio Code (the Linux version) in WSL, to use inside i3.
# Adds Microsoft's apt repository, so VS Code updates with the rest of the
# system (sudo apt upgrade).
#
# Note: if you also have VS Code on Windows, typing "code" in WSL opens this
# Linux version from now on. To open the Windows one (with the WSL
# extension), run its full path or uninstall this one.
#
# Usage: ./install-vscode.sh
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

KEYRING=/usr/share/keyrings/microsoft.gpg
SOURCES=/etc/apt/sources.list.d/vscode.sources

echo "==> Adding Microsoft's VS Code repository"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wget gpg ca-certificates
if [[ ! -f "$KEYRING" ]]; then
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor |
    sudo install -D -o root -g root -m 644 /dev/stdin "$KEYRING"
fi
sudo tee "$SOURCES" >/dev/null <<SRC
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: $KEYRING
SRC
# The package would otherwise offer to add the same repository a second time
echo "code code/add-microsoft-repo boolean false" | sudo debconf-set-selections

echo "==> Installing VS Code"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y code

# The i3 window and RDP have no GPU; turning off hardware acceleration avoids
# black or flickering VS Code windows there.
ARGV="$HOME/.vscode/argv.json"
mkdir -p "$(dirname "$ARGV")"
if [[ ! -f "$ARGV" ]]; then
  printf '{\n  // Added by install-vscode.sh: no GPU in the i3 window or RDP\n  "disable-hardware-acceleration": true\n}\n' > "$ARGV"
elif ! grep -q 'disable-hardware-acceleration' "$ARGV"; then
  echo "    Tip: add \"disable-hardware-acceleration\": true to $ARGV if VS Code looks black or flickers."
fi

echo
echo "Done. In i3, press Alt+d and type 'code', or run: code"
