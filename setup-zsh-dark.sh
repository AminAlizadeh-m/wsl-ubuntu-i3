#!/usr/bin/env bash
# Set up zsh as your shell and give i3 a dark theme:
#   - git, and zsh with Oh My Zsh (robbyrussell theme, git, autosuggestions
#     and syntax-highlighting plugins), using config/zshrc as ~/.zshrc
#   - Alacritty terminal on Alt+Enter, with xterm as fallback
#   - dark GTK apps
#   - colours for i3, its bar, the terminals and rofi via set-theme.sh
#     (Tokyo Night by default; switch any time with ./set-theme.sh <theme>)
#
# Safe to run more than once. Existing files are backed up the first time
# as <file>.pre-zsh-dark, and uninstall-i3.sh restores them.
# Usage: ./setup-zsh-dark.sh
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

I3_CFG="$HOME/.config/i3/config"
if [[ ! -f "$I3_CFG" ]]; then
  echo "No i3 config at $I3_CFG. Run ./install-i3.sh first." >&2
  exit 1
fi

# Back up a file once, before we first change it. Files this script wrote
# itself (they contain the marker) are not "originals", so skip those.
backup_once() {
  [[ -e "$1" && ! -e "$1.pre-zsh-dark" ]] || return 0
  grep -q 'setup-zsh-dark.sh\|wsl-dark-theme' "$1" 2>/dev/null && return 0
  cp -a "$1" "$1.pre-zsh-dark"
}

# ---------------------------------------------------------------- packages
echo "==> Installing git, zsh and terminals"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git zsh alacritty xterm x11-xserver-utils

# Nice to have; skip any that this Ubuntu release doesn't have.
for pkg in fonts-jetbrains-mono gnome-themes-extra; do
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  else
    echo "    (skipping $pkg: not available)"
  fi
done

# ---------------------------------------------------------------- Oh My Zsh
# Same setup as config/zshrc expects: Oh My Zsh plus two plugins from GitHub.
OMZ="$HOME/.oh-my-zsh"
if [[ -d "$OMZ" ]]; then
  echo "==> Oh My Zsh is already installed"
else
  echo "==> Downloading Oh My Zsh"
  if ! git clone -q --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ"; then
    echo "Could not download Oh My Zsh (check your internet connection) and try again." >&2
    exit 1
  fi
  touch "$OMZ/.installed-by-wsl-i3"   # lets uninstall-i3.sh know it may remove it
fi
get_plugin() {  # get_plugin <name> <git url>
  local dir="$OMZ/custom/plugins/$1"
  if [[ -d "$dir/.git" ]]; then
    echo "==> Updating zsh plugin $1"
    git -C "$dir" pull -q --ff-only || echo "    (could not update $1, keeping current version)"
  else
    echo "==> Downloading zsh plugin $1"
    git clone -q --depth 1 "$2" "$dir" || echo "    (could not download $1; zsh works without it, re-run later)"
  fi
}
get_plugin zsh-autosuggestions     https://github.com/zsh-users/zsh-autosuggestions.git
get_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git

# Plugins from an earlier version of this script, no longer used
rm -rf "$HOME/.local/share/zsh/plugins/zsh-autocomplete" "$HOME/.local/share/zsh/plugins/zsh-completions"
rmdir "$HOME/.local/share/zsh/plugins" 2>/dev/null || true

# ---------------------------------------------------------------- zsh
ZSHRC="$HOME/.zshrc"
backup_once "$ZSHRC"
echo "==> Installing $ZSHRC from config/zshrc"
cp "$(dirname "${BASH_SOURCE[0]}")/config/zshrc" "$ZSHRC"

# ---------------------------------------------------------------- terminal wrapper
# Xephyr and xrdp have no GPU, so run Alacritty with software rendering, and
# open xterm instead if Alacritty fails to start.
TERM_WRAPPER="$HOME/.local/bin/i3-term"
mkdir -p "$(dirname "$TERM_WRAPPER")"
echo "==> Writing $TERM_WRAPPER"
cat > "$TERM_WRAPPER" <<'EOF'
#!/bin/sh
# Terminal launcher for i3 (from setup-zsh-dark.sh)
export LIBGL_ALWAYS_SOFTWARE=1
if command -v alacritty >/dev/null 2>&1; then
  start=$(date +%s)
  alacritty "$@" && exit 0
  # Only fall back if Alacritty died right away (failed to start)
  [ $(( $(date +%s) - start )) -ge 3 ] && exit 0
fi
exec xterm "$@"
EOF
chmod +x "$TERM_WRAPPER"

# ---------------------------------------------------------------- i3: Alt+Enter
# Point Alt+Enter at the wrapper. Replace the existing line, never add a
# second one (i3 rejects duplicate keybindings).
I3_KEY="bindsym \$mod+Return exec --no-startup-id $TERM_WRAPPER"
backup_once "$I3_CFG"
sed -i -E "s|^bindsym \\\$mod\+Return exec .*|$I3_KEY|" "$I3_CFG"
grep -q "^bindsym \$mod+Return exec" "$I3_CFG" || echo "$I3_KEY" >> "$I3_CFG"

# ---------------------------------------------------------------- GTK apps
for v in 3.0 4.0; do
  GTK_CFG="$HOME/.config/gtk-$v/settings.ini"
  if [[ ! -f "$GTK_CFG" ]]; then
    mkdir -p "$(dirname "$GTK_CFG")"
    printf '[Settings]\ngtk-application-prefer-dark-theme=1\n' > "$GTK_CFG"
    [[ $v == 3.0 ]] && echo 'gtk-theme-name=Adwaita-dark' >> "$GTK_CFG"
    echo "==> Wrote $GTK_CFG"
  elif ! grep -q 'gtk-application-prefer-dark-theme' "$GTK_CFG"; then
    echo "    $GTK_CFG exists; add 'gtk-application-prefer-dark-theme=1' under [Settings] for dark GTK apps"
  fi
done

# ---------------------------------------------------------------- colours
# Keep the current theme if one is set, otherwise start with Tokyo Night.
THEME="$(sed -n 's/^# theme: //p' "$I3_CFG" | head -1)"
"$(dirname "${BASH_SOURCE[0]}")/set-theme.sh" "${THEME:-tokyonight}"

# ---------------------------------------------------------------- login shell
ZSH_PATH="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
if [[ "$CURRENT_SHELL" != "$ZSH_PATH" ]]; then
  echo "==> Making zsh your login shell (enter your Linux password if asked)"
  echo "    This also changes the shell that Windows Terminal's Ubuntu tab and 'wsl' open."
  if ! chsh -s "$ZSH_PATH"; then
    echo "    chsh failed. Run 'chsh -s $ZSH_PATH' yourself later." >&2
  fi
fi

echo
echo "Done."
echo "  - Change colours any time: ./set-theme.sh catppuccin|gruvbox|nord|tokyonight|dracula"
echo "  - Alt+Enter opens Alacritty with zsh (new terminals only)."
echo "  - Close and reopen Ubuntu / Windows Terminal to use zsh there too."
echo "  - Backups of replaced files end in .pre-zsh-dark"
