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
POLYBAR_PKGS=(polybar picom autotiling)
ZSH_PKGS=(zsh zsh-autosuggestions zsh-syntax-highlighting alacritty fonts-jetbrains-mono gnome-themes-extra)

to_remove=()

# 00. Apps: Google Chrome, VS Code, openfortivpn (install-*.sh)
if [[ -n "$(installed google-chrome-stable)" ]] && ask "Remove Google Chrome?"; then
  to_remove+=(google-chrome-stable)
  sudo rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.sources
fi
if [[ -n "$(installed code)" ]] && ask "Remove VS Code (Linux version)?"; then
  to_remove+=(code)
  sudo rm -f /etc/apt/sources.list.d/vscode.sources /etc/apt/sources.list.d/vscode.list
  # Microsoft's key, unless another apt source still uses it
  grep -rqs 'microsoft.gpg' /etc/apt/sources.list.d/ || sudo rm -f /usr/share/keyrings/microsoft.gpg
fi
if [[ -n "$(installed openfortivpn)" ]] && ask "Remove openfortivpn (your settings in ~/.config/openfortivpn are kept)?"; then
  to_remove+=(openfortivpn)
fi

# 0. autotiling, i3lock, feh, dunst (install-i3-tools.sh)
if { [[ -e "$HOME/.local/bin/i3-tools" ]] || [[ -d "$HOME/.local/share/wsl-i3-tools" ]]; } &&
   ask "Undo install-i3-tools.sh (autotiling, i3lock, feh, dunst)?"; then
  if [[ $YES -eq 1 ]]; then
    "$(dirname "$0")/uninstall-i3-tools.sh" --yes
  else
    "$(dirname "$0")/uninstall-i3-tools.sh"
  fi
fi

# 0a. polybar, picom, autotiling (setup-polybar.sh)
mapfile -t pb_found < <(installed "${POLYBAR_PKGS[@]}")
if { [[ ${#pb_found[@]} -gt 0 ]] || [[ -e "$HOME/.config/polybar/.wsl-polybar" ]]; } &&
   ask "Remove polybar, picom and autotiling (bring back the i3 bar)?"; then
  rm -f "$HOME/.config/polybar/.wsl-polybar" "$HOME/.config/picom/.wsl-picom" "$HOME/.local/bin/i3-extras"
  I3C="$HOME/.config/i3/config"
  if [[ -f "$I3C" ]]; then
    sed -i '/^# >>> wsl-polybar >>>/,/^# <<< wsl-polybar <<</d' "$I3C"
    # Re-apply the theme without polybar, so the i3 bar comes back
    theme="$(sed -n 's/^# theme: //p' "$HOME/.config/i3/generated/theme.conf" 2>/dev/null | head -1)"
    if [[ -n "$theme" && -x "$(dirname "$0")/set-theme.sh" ]]; then
      "$(dirname "$0")/set-theme.sh" "$theme" >/dev/null
    elif [[ -d "$HOME/.config/i3/generated" ]]; then
      cp "$(dirname "$0")/config/i3/bar.conf" "$HOME/.config/i3/generated/bar.conf"
    fi
  fi
  for f in "$HOME/.config/polybar/config.ini" "$HOME/.config/picom/picom.conf"; do
    if [[ -e "$f.pre-zsh-dark" ]]; then
      mv -f "$f.pre-zsh-dark" "$f"
    elif [[ -f "$f" ]] && grep -q 'set-theme.sh\|setup-polybar.sh' "$f"; then
      rm -f "$f"
    fi
  done
  rmdir "$HOME/.config/polybar" "$HOME/.config/picom" 2>/dev/null || true
  # Stop the polybar/autotiling processes the launcher started (it lists them per display)
  for pf in "${XDG_RUNTIME_DIR:-/tmp}"/wsl-i3-extras*.pids; do
    [[ -f "$pf" ]] || continue
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$pf"
    rm -f "$pf"
  done
  pkill -x picom 2>/dev/null || true
  to_remove+=("${pb_found[@]}")
  echo "==> polybar setup removed"
fi

# 0b. zsh + dark theme (setup-zsh-dark.sh)
MARK='setup-zsh-dark.sh\|wsl-dark-theme'
login_shell="$(getent passwd "$USER" | cut -d: -f7)"
mapfile -t zsh_found < <(installed "${ZSH_PKGS[@]}")
if { [[ ${#zsh_found[@]} -gt 0 ]] || [[ -e "$HOME/.oh-my-zsh/.installed-by-wsl-i3" ]]; } &&
   ask "Undo the zsh + dark theme setup (and remove zsh, Alacritty)?"; then
  remove_zsh=1
  # The login shell must not point at zsh once zsh is gone, or WSL can't open a shell.
  if [[ "$login_shell" == */zsh ]]; then
    echo "==> Switching your login shell back to bash (enter your Linux password if asked)"
    if ! chsh -s /bin/bash; then
      echo "    chsh failed, so zsh will NOT be removed. Run 'chsh -s /bin/bash' and try again." >&2
      remove_zsh=0
    fi
  fi

  # Put back the files we replaced, or remove the ones we created.
  for f in "$HOME/.zshrc" "$HOME/.config/alacritty/alacritty.toml" \
           "$HOME/.config/rofi/config.rasi" "$HOME/.Xresources" \
           "$HOME/.config/i3status/config"; do
    if [[ -e "$f.pre-zsh-dark" ]]; then
      mv -f "$f.pre-zsh-dark" "$f"
      echo "==> Restored $f"
    elif [[ -f "$f" ]] && grep -q "$MARK" "$f"; then
      case "$f" in
        */.Xresources) sed -i '/^! >>> wsl-dark-theme >>>/,/^! <<< wsl-dark-theme <<</d' "$f" ;;
        *)             rm -f "$f" ;;
      esac
      echo "==> Removed dark-theme settings from $f"
    fi
  done
  # i3 back to its default colours and plain bar (the i3 config itself stays)
  I3G="$HOME/.config/i3/generated"
  if [[ -d "$I3G" ]]; then
    printf '# No theme set yet. Run ./set-theme.sh <theme> to pick one.\n' > "$I3G/theme.conf"
    [[ -f "$HOME/.config/polybar/.wsl-polybar" ]] || cp "$(dirname "$0")/config/i3/bar.conf" "$I3G/bar.conf"
    echo "==> i3 is back to its default colours"
  fi
  # Oh My Zsh, only if this project installed it
  if [[ -f "$HOME/.oh-my-zsh/.installed-by-wsl-i3" ]]; then
    rm -rf "$HOME/.oh-my-zsh"
    echo "==> Removed Oh My Zsh"
  fi
  # zsh plugins cloned by an earlier version
  rm -rf "$HOME/.local/share/zsh/plugins/zsh-autocomplete" "$HOME/.local/share/zsh/plugins/zsh-completions"
  rmdir "$HOME/.local/share/zsh/plugins" 2>/dev/null || true
  for v in 3.0 4.0; do
    g="$HOME/.config/gtk-$v/settings.ini"
    if [[ -f "$g" ]] && [[ $(grep -cv 'Settings\]\|prefer-dark-theme\|Adwaita-dark' "$g") -eq 0 ]]; then
      rm -f "$g"
    fi
  done

  [[ $remove_zsh -eq 1 ]] && to_remove+=("${zsh_found[@]}")
fi

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
  rm -f "$HOME/.local/bin/i3-term" "$HOME/.local/bin/i3-fit" \
        "$HOME/.local/bin/i3-root-run" "$HOME/.local/bin/i3-askpass"
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
  if grep -qx 'exec dbus-launch --exit-with-session i3' "$XS" && [[ $(wc -l <"$XS") -le 8 ]]; then
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
