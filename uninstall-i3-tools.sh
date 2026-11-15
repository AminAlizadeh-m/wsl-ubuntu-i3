#!/usr/bin/env bash
# Undo install-i3-tools.sh:
#   - stops dunst and autotiling started by its launcher
#   - removes its lines from your i3 config, the launcher and its dunstrc
#     (your old dunstrc and wallpaper come back if there were any)
#   - removes the packages it installed; packages you already had before
#     (e.g. i3lock and feh from install-i3.sh) stay
#
# Usage: ./uninstall-i3-tools.sh [--yes]   (--yes answers yes to every question)
set -euo pipefail

YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

ask() {  # ask "question" -> 0 for yes
  [[ $YES -eq 1 ]] && return 0
  local reply
  read -rp "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]]
}

STATE="$HOME/.local/share/wsl-i3-tools"
LAUNCHER="$HOME/.local/bin/i3-tools"
I3_DIR="$HOME/.config/i3"
DUNSTRC="$HOME/.config/dunst/dunstrc"
did=0

# ---------------------------------------------------------------- processes
for pf in "${XDG_RUNTIME_DIR:-/tmp}"/wsl-i3-tools*.pids; do
  [[ -f "$pf" ]] || continue
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$pf"
  rm -f "$pf"
  did=1
done
[[ $did -eq 1 ]] && echo "==> Stopped dunst and autotiling"

# ---------------------------------------------------------------- i3 config
for f in "$I3_DIR/config.d/custom.conf" "$I3_DIR/config"; do
  [[ -f "$f" ]] || continue
  if grep -q '^# >>> wsl-i3-tools >>>$' "$f"; then
    sed -i '/^# >>> wsl-i3-tools >>>$/,/^# <<< wsl-i3-tools <<<$/d' "$f"
    echo "==> Removed the tools' lines from $f"
    did=1
  fi
done

# ---------------------------------------------------------------- files
if [[ -f "$LAUNCHER" ]]; then
  rm -f "$LAUNCHER"
  echo "==> Removed $LAUNCHER"
  did=1
fi

if [[ -e "$DUNSTRC.pre-i3-tools" ]]; then
  mv -f "$DUNSTRC.pre-i3-tools" "$DUNSTRC"
  echo "==> Restored your previous dunstrc"
  did=1
elif [[ -f "$DUNSTRC" ]] && grep -q 'install-i3-tools.sh' "$DUNSTRC"; then
  rm -f "$DUNSTRC"
  rmdir "$(dirname "$DUNSTRC")" 2>/dev/null || true
  echo "==> Removed $DUNSTRC"
  did=1
fi

if [[ -e "$HOME/.wallpaper.pre-i3-tools" ]]; then
  mv -f "$HOME/.wallpaper.pre-i3-tools" "$HOME/.wallpaper"
  echo "==> Restored your previous ~/.wallpaper"
  did=1
fi

# ---------------------------------------------------------------- packages
pkgs=()
if [[ -f "$STATE/packages" ]]; then
  while read -r p; do
    [[ -n "$p" ]] || continue
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" && pkgs+=("$p")
  done < "$STATE/packages"
fi
if [[ ${#pkgs[@]} -gt 0 ]]; then
  echo "Installed by install-i3-tools.sh: ${pkgs[*]}"
  if ask "Remove these packages?"; then
    sudo apt-get purge -y "${pkgs[@]}"
    if [[ $YES -eq 1 ]]; then
      sudo apt-get autoremove -y
    else
      sudo apt-get autoremove   # apt shows the list and asks first
    fi
    rm -rf "$STATE"
  else
    echo "    Kept them. Run this script again later to remove them."
  fi
  did=1
else
  rm -rf "$STATE"
fi

if [[ $did -eq 0 ]]; then
  echo "Nothing to do: install-i3-tools.sh doesn't seem to have been run."
  exit 0
fi

# Restart running i3s so the removed keys and launcher are gone
for sock in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/i3/ipc-socket.*; do
  [[ -S "$sock" ]] && i3-msg -s "$sock" restart >/dev/null 2>&1 || true
done

echo
echo "Done. If i3 is running, press Alt+Shift+r if anything is left over."
