#!/usr/bin/env bash
# Switch the colour theme of i3, its bar, i3status, Alacritty, xterm and rofi.
# Usage: ./set-theme.sh               list themes and show the current one
#        ./set-theme.sh <theme>       apply a theme
# Themes: catppuccin, gruvbox, nord, tokyonight, dracula
#
# Safe to run as often as you like. Files are backed up once, before the first
# change, as <file>.pre-zsh-dark (uninstall-i3.sh restores them).
set -euo pipefail

THEMES=(catppuccin gruvbox nord tokyonight dracula)
I3_CFG="$HOME/.config/i3/config"

current_theme() {
  sed -n 's/^# theme: //p' "$I3_CFG" 2>/dev/null | head -1
}

if [[ $# -eq 0 ]]; then
  echo "Available themes: ${THEMES[*]}"
  echo "Current theme:    $(current_theme || true)"
  echo "Usage: $0 <theme>"
  exit 0
fi

THEME="$1"

# --------------------------------------------------------------- palettes
# BG/BG_ALT: backgrounds, FG: text, MUTED: dim text, ACCENT: focused window and
# workspace, URGENT: urgent window, CURSOR, SEL: selection background,
# C0..C15: the 16 terminal colours (normal 0-7, bright 8-15).
case "$THEME" in
  catppuccin)  # Catppuccin Mocha
    BG="#1e1e2e"; BG_ALT="#313244"; FG="#cdd6f4"; MUTED="#6c7086"
    ACCENT="#cba6f7"; URGENT="#f38ba8"; CURSOR="#f5e0dc"; SEL="#45475a"
    C=("#45475a" "#f38ba8" "#a6e3a1" "#f9e2af" "#89b4fa" "#f5c2e7" "#94e2d5" "#bac2de"
       "#585b70" "#f38ba8" "#a6e3a1" "#f9e2af" "#89b4fa" "#f5c2e7" "#94e2d5" "#a6adc8") ;;
  gruvbox)     # Gruvbox dark
    BG="#282828"; BG_ALT="#3c3836"; FG="#ebdbb2"; MUTED="#928374"
    ACCENT="#fabd2f"; URGENT="#fb4934"; CURSOR="#ebdbb2"; SEL="#504945"
    C=("#282828" "#cc241d" "#98971a" "#d79921" "#458588" "#b16286" "#689d6a" "#a89984"
       "#928374" "#fb4934" "#b8bb26" "#fabd2f" "#83a598" "#d3869b" "#8ec07c" "#ebdbb2") ;;
  nord)
    BG="#2e3440"; BG_ALT="#3b4252"; FG="#d8dee9"; MUTED="#4c566a"
    ACCENT="#88c0d0"; URGENT="#bf616a"; CURSOR="#d8dee9"; SEL="#434c5e"
    C=("#3b4252" "#bf616a" "#a3be8c" "#ebcb8b" "#81a1c1" "#b48ead" "#88c0d0" "#e5e9f0"
       "#4c566a" "#bf616a" "#a3be8c" "#ebcb8b" "#81a1c1" "#b48ead" "#8fbcbb" "#eceff4") ;;
  tokyonight)  # Tokyo Night
    BG="#1a1b26"; BG_ALT="#292e42"; FG="#c0caf5"; MUTED="#565f89"
    ACCENT="#7aa2f7"; URGENT="#f7768e"; CURSOR="#c0caf5"; SEL="#33467c"
    C=("#15161e" "#f7768e" "#9ece6a" "#e0af68" "#7aa2f7" "#bb9af7" "#7dcfff" "#a9b1d6"
       "#414868" "#f7768e" "#9ece6a" "#e0af68" "#7aa2f7" "#bb9af7" "#7dcfff" "#c0caf5") ;;
  dracula)
    BG="#282a36"; BG_ALT="#44475a"; FG="#f8f8f2"; MUTED="#6272a4"
    ACCENT="#bd93f9"; URGENT="#ff5555"; CURSOR="#f8f8f2"; SEL="#44475a"
    C=("#21222c" "#ff5555" "#50fa7b" "#f1fa8c" "#bd93f9" "#ff79c6" "#8be9fd" "#f8f8f2"
       "#6272a4" "#ff6e6e" "#69ff94" "#ffffa5" "#d6acff" "#ff92df" "#a4ffff" "#ffffff") ;;
  *)
    echo "Unknown theme '$THEME'. Available: ${THEMES[*]}" >&2
    exit 1 ;;
esac

if [[ ! -f "$I3_CFG" ]]; then
  echo "No i3 config at $I3_CFG. Run ./install-i3.sh first." >&2
  exit 1
fi

if fc-list 2>/dev/null | grep -qi "JetBrains Mono"; then
  FONT="JetBrains Mono"
else
  FONT="DejaVu Sans Mono"
fi

# Back up a file once, before we first change it. Files we generated
# ourselves (they contain the marker) are not originals, so skip those.
backup_once() {
  [[ -e "$1" && ! -e "$1.pre-zsh-dark" ]] || return 0
  grep -q 'setup-zsh-dark.sh\|wsl-dark-theme' "$1" 2>/dev/null && return 0
  cp -a "$1" "$1.pre-zsh-dark"
}

echo "==> Applying theme: $THEME"

# --------------------------------------------------------------- i3
backup_once "$I3_CFG"
TMP_CFG="$(mktemp)"
# Drop our previous block, and comment out the stock bar so there's only one bar.
awk '
  /^# >>> wsl-dark-theme >>>/ { skip = 1; next }
  /^# <<< wsl-dark-theme <<</ { skip = 0; next }
  skip { next }
  /^bar[ \t]*\{/ { inbar = 1 }
  inbar { print "#" $0; if ($0 ~ /^\}/) inbar = 0; next }
  { print }
' "$I3_CFG" > "$TMP_CFG"

cat >> "$TMP_CFG" <<EOF
# >>> wsl-dark-theme >>>
# Added by set-theme.sh. Re-running it replaces this block.
# theme: $THEME
font pango:$FONT 10
exec_always --no-startup-id xrdb -merge ~/.Xresources
exec_always --no-startup-id xsetroot -solid "$BG"

# class                 border    backgr.   text      indicator child_border
client.focused          $ACCENT   $ACCENT   $BG       $ACCENT   $ACCENT
client.focused_inactive $BG_ALT   $BG_ALT   $FG       $BG_ALT   $BG_ALT
client.unfocused        $BG       $BG       $MUTED    $BG       $BG
client.urgent           $URGENT   $URGENT   $BG       $URGENT   $URGENT
client.background       $BG

default_border pixel 2
gaps inner 6
EOF

# i3bar, unless setup-polybar.sh has switched to polybar
POLYBAR_FLAG="$HOME/.config/polybar/.wsl-polybar"
if [[ ! -f "$POLYBAR_FLAG" ]]; then
  cat >> "$TMP_CFG" <<EOF

bar {
    status_command i3status
    position top
    font pango:$FONT 10
    colors {
        background $BG
        statusline $FG
        separator  $MUTED
        #                  border    backgr.   text
        focused_workspace  $ACCENT   $ACCENT   $BG
        active_workspace   $BG_ALT   $BG_ALT   $FG
        inactive_workspace $BG       $BG       $MUTED
        urgent_workspace   $URGENT   $URGENT   $BG
    }
}
EOF
fi
echo "# <<< wsl-dark-theme <<<" >> "$TMP_CFG"

if command -v i3 >/dev/null && ! i3 -C -c "$TMP_CFG" >/dev/null 2>&1; then
  echo "The new i3 config has errors, keeping your old one. Details:" >&2
  i3 -C -c "$TMP_CFG" >&2 || true
  rm -f "$TMP_CFG"
  exit 1
fi
cat "$TMP_CFG" > "$I3_CFG"   # keep the file's permissions
rm -f "$TMP_CFG"

# --------------------------------------------------------------- i3status
# Status text colours (good / degraded / bad)
I3S_CFG="$HOME/.config/i3status/config"
mkdir -p "$(dirname "$I3S_CFG")"
backup_once "$I3S_CFG"
if [[ ! -f "$I3S_CFG" ]]; then
  if [[ -f /etc/i3status.conf ]]; then
    cp /etc/i3status.conf "$I3S_CFG"
  else
    printf 'general {\n        colors = true\n        interval = 5\n}\n\norder += "tztime local"\ntztime local {\n        format = "%%Y-%%m-%%d %%H:%%M"\n}\n' > "$I3S_CFG"
  fi
fi
sed -i '/# wsl-dark-theme$/d' "$I3S_CFG"
sed -i -E "0,/^general[ \t]*\{/s//general {\n        color_good = \"${C[10]}\"  # wsl-dark-theme\n        color_degraded = \"${C[11]}\"  # wsl-dark-theme\n        color_bad = \"${C[9]}\"  # wsl-dark-theme/" "$I3S_CFG"

# --------------------------------------------------------------- Alacritty
AL_CFG="$HOME/.config/alacritty/alacritty.toml"
mkdir -p "$(dirname "$AL_CFG")"
backup_once "$AL_CFG"
cat > "$AL_CFG" <<EOF
# Generated by set-theme.sh (wsl-dark-theme), theme: $THEME
[window]
padding = { x = 8, y = 6 }

[font]
size = 11.0
normal = { family = "$FONT" }

[colors.primary]
background = "$BG"
foreground = "$FG"

[colors.cursor]
text = "$BG"
cursor = "$CURSOR"

[colors.selection]
text = "$FG"
background = "$SEL"

[colors.normal]
black = "${C[0]}"
red = "${C[1]}"
green = "${C[2]}"
yellow = "${C[3]}"
blue = "${C[4]}"
magenta = "${C[5]}"
cyan = "${C[6]}"
white = "${C[7]}"

[colors.bright]
black = "${C[8]}"
red = "${C[9]}"
green = "${C[10]}"
yellow = "${C[11]}"
blue = "${C[12]}"
magenta = "${C[13]}"
cyan = "${C[14]}"
white = "${C[15]}"
EOF

# --------------------------------------------------------------- xterm
XRES="$HOME/.Xresources"
backup_once "$XRES"
[[ -f "$XRES" ]] && sed -i '/^! >>> wsl-dark-theme >>>/,/^! <<< wsl-dark-theme <<</d' "$XRES"
{
  echo "! >>> wsl-dark-theme >>>"
  echo "XTerm*faceName: $FONT"
  echo "XTerm*faceSize: 11"
  echo "XTerm*termName: xterm-256color"
  echo "XTerm*metaSendsEscape: true"
  echo "XTerm*background: $BG"
  echo "XTerm*foreground: $FG"
  echo "XTerm*cursorColor: $CURSOR"
  for i in "${!C[@]}"; do echo "XTerm*color$i: ${C[$i]}"; done
  echo "! <<< wsl-dark-theme <<<"
} >> "$XRES"

# --------------------------------------------------------------- rofi
ROFI_CFG="$HOME/.config/rofi/config.rasi"
mkdir -p "$(dirname "$ROFI_CFG")"
backup_once "$ROFI_CFG"
cat > "$ROFI_CFG" <<EOF
/* Generated by set-theme.sh (wsl-dark-theme), theme: $THEME */
configuration {
  show-icons: false;
  font: "$FONT 11";
}
* {
  background-color: $BG;
  text-color: $FG;
  border-color: $ACCENT;
}
window { width: 40%; border: 2px; padding: 12px; }
inputbar { padding: 6px; children: [prompt, entry]; }
prompt { text-color: $ACCENT; padding: 0 8px 0 0; }
listview { lines: 10; padding: 8px 0 0 0; }
element { padding: 4px 8px; }
element selected { background-color: $BG_ALT; text-color: $ACCENT; }
element-text { background-color: inherit; text-color: inherit; }
EOF

# --------------------------------------------------------------- polybar
if [[ -f "$POLYBAR_FLAG" ]]; then
  PB_CFG="$HOME/.config/polybar/config.ini"
  # Quoted heredoc (polybar uses ${...} itself); fill in colours afterwards.
  cat > "$PB_CFG" <<'EOF'
; Generated by set-theme.sh (wsl-dark-theme), theme: @THEME@
[colors]
background = @BG@
background-alt = @BG_ALT@
foreground = @FG@
muted = @MUTED@
accent = @ACCENT@
urgent = @URGENT@

[bar/main]
monitor = ${env:MONITOR:}
width = 100%
height = 24pt
background = ${colors.background}
foreground = ${colors.foreground}
padding-right = 1
module-margin = 1
separator = |
separator-foreground = ${colors.muted}
font-0 = "@FONT@:size=10;2"
modules-left = i3 xwindow
modules-right = cpu memory filesystem date
wm-restack = i3
enable-ipc = true

[module/i3]
type = internal/i3
pin-workspaces = true
format = <label-state> <label-mode>
label-mode = %mode%
label-mode-padding = 1
label-mode-background = ${colors.urgent}
label-mode-foreground = ${colors.background}
label-focused = %name%
label-focused-padding = 1
label-focused-background = ${colors.accent}
label-focused-foreground = ${colors.background}
label-unfocused = %name%
label-unfocused-padding = 1
label-unfocused-foreground = ${colors.muted}
label-visible = %name%
label-visible-padding = 1
label-visible-background = ${colors.background-alt}
label-urgent = %name%
label-urgent-padding = 1
label-urgent-background = ${colors.urgent}
label-urgent-foreground = ${colors.background}

[module/xwindow]
type = internal/xwindow
label = %title:0:60:...%

[module/cpu]
type = internal/cpu
interval = 2
format-prefix = "CPU "
format-prefix-foreground = ${colors.accent}
label = %percentage:2%%

[module/memory]
type = internal/memory
interval = 2
format-prefix = "RAM "
format-prefix-foreground = ${colors.accent}
label = %percentage_used:2%%

[module/filesystem]
type = internal/fs
mount-0 = /
interval = 30
format-mounted-prefix = "DISK "
format-mounted-prefix-foreground = ${colors.accent}
label-mounted = %percentage_used%%

[module/date]
type = internal/date
interval = 1
date = %a %d %b
time = %H:%M
label = %date%  %time%

[settings]
screenchange-reload = true
EOF
  sed -i -e "s/@THEME@/$THEME/" -e "s/@BG@/$BG/" -e "s/@BG_ALT@/$BG_ALT/" \
         -e "s/@FG@/$FG/" -e "s/@MUTED@/$MUTED/" -e "s/@ACCENT@/$ACCENT/" \
         -e "s/@URGENT@/$URGENT/" -e "s/@FONT@/$FONT/" "$PB_CFG"
fi

# --------------------------------------------------------------- reload
# Restart every running i3 (keeps your windows). Alacritty reloads by itself.
restarted=0
for sock in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/i3/ipc-socket.*; do
  [[ -S "$sock" ]] || continue
  i3-msg -s "$sock" restart >/dev/null 2>&1 && restarted=1
done

echo
echo "Theme '$THEME' applied."
if [[ $restarted -eq 1 ]]; then
  echo "  - i3 restarted with the new colours."
else
  echo "  - Press Alt+Shift+r in i3 to load it."
fi
echo "  - Open terminals and rofi pick it up automatically; xterm windows need reopening."
