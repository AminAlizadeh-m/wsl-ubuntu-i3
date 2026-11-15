#!/usr/bin/env bash
# Undo adi1090x/polybar-themes (https://github.com/adi1090x/polybar-themes).
# Its setup.sh moved your old ~/.config/polybar to ~/.config/polybar.old,
# copied its themes into ~/.config/polybar and its fonts into
# ~/.local/share/fonts. This script reverses that:
#   - stops the running theme bars
#   - removes the "launch.sh --<theme>" line from your i3 config
#   - removes the themes and puts your old ~/.config/polybar back (if any)
#   - removes the fonts it copied (needs the cloned repo to know which)
#   - optionally deletes the cloned repo
# polybar itself stays installed.
#
# Usage: ./uninstall-polybar-themes.sh [path to the cloned repo]   (default ~/polybar-themes)
#        add --yes to answer yes to every question
set -euo pipefail

YES=0; CLONE="$HOME/polybar-themes"
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    *) CLONE="$arg" ;;
  esac
done

ask() {  # ask "question" -> 0 for yes
  [[ $YES -eq 1 ]] && return 0
  local reply
  read -rp "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]]
}

PB="$HOME/.config/polybar"
OLD="$HOME/.config/polybar.old"

# The themes' launch.sh says "Usage : launch.sh --theme"
is_themes_dir() { [[ -f "$1/launch.sh" ]] && grep -q 'launch.sh --theme' "$1/launch.sh"; }

if ! is_themes_dir "$PB"; then
  echo "~/.config/polybar doesn't contain polybar-themes, so there's nothing to undo there."
  THEMES_INSTALLED=0
else
  THEMES_INSTALLED=1
fi

# ---------------------------------------------------------------- stop the bars
if [[ $THEMES_INSTALLED -eq 1 ]]; then
  echo "==> Stopping the running polybar bars"
  pkill -u "$UID" -x polybar 2>/dev/null || true
fi

# ---------------------------------------------------------------- i3 config
# Remove lines like: exec_always --no-startup-id bash ~/.config/polybar/launch.sh --hack
for f in "$HOME/.config/i3/config.d/custom.conf" "$HOME/.config/i3/config"; do
  [[ -f "$f" ]] || continue
  if grep -qE '^[[:space:]]*exec(_always)?[[:space:]].*polybar/launch\.sh[[:space:]]+--[a-z]+' "$f"; then
    cp -a "$f" "$f.before-polybar-themes-uninstall"
    sed -i -E '/^[[:space:]]*exec(_always)?[[:space:]].*polybar\/launch\.sh[[:space:]]+--[a-z]+/d' "$f"
    echo "==> Removed the polybar-themes line from $f (backup: $f.before-polybar-themes-uninstall)"
  fi
done

# ---------------------------------------------------------------- themes folder
if [[ $THEMES_INSTALLED -eq 1 ]]; then
  rm -rf "$PB"
  echo "==> Removed the themes from ~/.config/polybar"
  if [[ -d "$OLD" ]]; then
    mv "$OLD" "$PB"
    echo "==> Restored your previous ~/.config/polybar (from polybar.old)"
    if [[ -d "$PB/polybar" ]]; then
      echo "    Note: ~/.config/polybar/polybar exists; an older backup may be nested in there."
    fi
  fi
fi

# ---------------------------------------------------------------- fonts
FONTS="$HOME/.local/share/fonts"
if [[ -d "$CLONE/fonts" ]]; then
  removed=0
  while IFS= read -r -d '' src; do
    rel="${src#"$CLONE/fonts/"}"
    if [[ -e "$FONTS/$rel" ]]; then
      rm -rf "${FONTS:?}/$rel"
      removed=$((removed + 1))
    fi
  done < <(find "$CLONE/fonts" -mindepth 1 -maxdepth 1 -print0)
  if [[ $removed -gt 0 ]]; then
    command -v fc-cache >/dev/null && fc-cache -f >/dev/null 2>&1 || true
    echo "==> Removed $removed font(s) it had copied into ~/.local/share/fonts"
  fi
else
  echo "    (Cloned repo not found at $CLONE, so its fonts in ~/.local/share/fonts were left alone."
  echo "     Pass the repo's path to remove them: $0 /path/to/polybar-themes)"
fi

# ---------------------------------------------------------------- the clone
if [[ -d "$CLONE/.git" ]] && ask "Delete the cloned repo $CLONE?"; then
  rm -rf "$CLONE"
  echo "==> Deleted $CLONE"
fi

echo
echo "Done. Restart i3 (Alt+Shift+r) to bring back your normal bar."
echo "polybar itself is still installed; remove it with: sudo apt remove polybar"
