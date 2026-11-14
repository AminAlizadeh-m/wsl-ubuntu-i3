#!/usr/bin/env bash
# Remove what the i3-on-WSL scripts installed.
# Usage: ./uninstall-i3.sh [--yes]   (--yes answers "yes" to every question)
#
# Never removed: iproute2 and fonts-dejavu-core (other software relies on them).
set -euo pipefail

YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

ask() {  # ask "question" -> returns 0 for yes
  [[ $YES -eq 1 ]] && return 0
  local reply
  read -rp "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]]
}

installed() {  # print only the given packages that are installed
  local p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" && echo "$p"
  done
  return 0
}

CORE_PKGS=(i3 i3-wm i3status i3lock dmenu rofi xserver-xephyr)
XRDP_PKGS=(xrdp xorgxrdp)
EXTRA_PKGS=(xinit x11-xserver-utils x11-utils x11-apps xterm feh dbus-x11 fonts-noto-color-emoji)

to_remove=()

# 1. xrdp (option 3)
mapfile -t xrdp_found < <(installed "${XRDP_PKGS[@]}")
if [[ ${#xrdp_found[@]} -gt 0 ]] && ask "Remove xrdp (Remote Desktop server)?"; then
  if [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
    sudo systemctl disable --now xrdp 2>/dev/null || true
  fi
  to_remove+=("${xrdp_found[@]}")
fi

# 2. i3 itself
mapfile -t core_found < <(installed "${CORE_PKGS[@]}")
if [[ ${#core_found[@]} -gt 0 ]] && ask "Remove i3, i3status, i3lock, dmenu, rofi and Xephyr?"; then
  to_remove+=("${core_found[@]}")
fi

# 3. General X tools (other GUI apps may use these, so ask separately)
mapfile -t extra_found < <(installed "${EXTRA_PKGS[@]}")
if [[ ${#extra_found[@]} -gt 0 ]]; then
  echo "Also installed: ${extra_found[*]}"
  echo "(Other Linux GUI apps may use these.)"
  if ask "Remove them too?"; then
    to_remove+=("${extra_found[@]}")
  fi
fi

if [[ ${#to_remove[@]} -gt 0 ]]; then
  echo "==> Removing: ${to_remove[*]}"
  sudo apt-get purge -y "${to_remove[@]}"
  echo "==> Removing packages that are no longer needed"
  if [[ $YES -eq 1 ]]; then
    sudo apt-get autoremove -y
  else
    sudo apt-get autoremove   # apt shows the list and asks before removing
  fi
else
  echo "==> No packages to remove"
fi

# 4. ~/.xsession written by setup-xrdp.sh (only if it's unchanged)
XS="$HOME/.xsession"
if [[ -f "$XS" ]]; then
  if grep -qx 'exec dbus-launch --exit-with-session i3' "$XS" && [[ $(wc -l <"$XS") -le 4 ]]; then
    rm -f "$XS"
    echo "==> Removed $XS"
  else
    echo "==> Left $XS alone (it has been edited; remove it yourself if you don't need it)"
  fi
fi

# 5. i3 config: back it up rather than delete
CFG_DIR="$HOME/.config/i3"
if [[ -d "$CFG_DIR" ]] && ask "Remove your i3 config ($CFG_DIR)? A backup is kept."; then
  backup="$CFG_DIR.bak.$(date +%Y%m%d-%H%M%S)"
  mv "$CFG_DIR" "$backup"
  echo "==> Moved config to $backup"
fi

echo
echo "Uninstall finished."
