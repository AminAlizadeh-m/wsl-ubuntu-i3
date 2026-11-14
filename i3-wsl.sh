#!/usr/bin/env bash
# One entry point for running i3 on WSL: pick a method from a menu,
# or pass it directly:
#   ./i3-wsl.sh                      interactive menu
#   ./i3-wsl.sh install              install i3 only
#   ./i3-wsl.sh wslg [auto|full|WxH] i3 in a window via WSLg
#   ./i3-wsl.sh xserver [DISP]       full screen via VcXsrv/X410
#   ./i3-wsl.sh xrdp [PORT]          full desktop via Remote Desktop
#   ./i3-wsl.sh zsh                  zsh + dark theme for i3
#   ./i3-wsl.sh theme [NAME]         switch colour theme
#   ./i3-wsl.sh polybar [--no-picom] polybar, autotiling, picom
#   ./i3-wsl.sh glazewm [--config]   i3-style tiling for Windows itself
#   ./i3-wsl.sh uninstall [--yes]    remove everything again
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_installed() {
  if ! command -v i3 >/dev/null || ! command -v Xephyr >/dev/null; then
    echo "==> i3 is not installed yet, running the installer first"
    "$DIR/install-i3.sh"
  fi
}

run_method() {
  local method="$1"; shift
  case "$method" in
    install) "$DIR/install-i3.sh" ;;
    wslg)    ensure_installed; exec "$DIR/start-i3-wslg.sh" "$@" ;;
    xserver) ensure_installed; exec "$DIR/start-i3-windows-xserver.sh" "$@" ;;
    xrdp)    ensure_installed; exec "$DIR/setup-xrdp.sh" "$@" ;;
    zsh)     ensure_installed; exec "$DIR/setup-zsh-dark.sh" "$@" ;;
    theme)   exec "$DIR/set-theme.sh" "$@" ;;
    polybar) ensure_installed; exec "$DIR/setup-polybar.sh" "$@" ;;
    glazewm) exec "$DIR/setup-glazewm.sh" "$@" ;;
    uninstall) exec "$DIR/uninstall-i3.sh" "$@" ;;
    -h|--help|help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "Unknown method: $method (use install, wslg, xserver, xrdp, zsh, theme, polybar, glazewm or uninstall)" >&2; exit 1 ;;
  esac
}

if [[ $# -gt 0 ]]; then
  run_method "$@"
  exit
fi

cat <<'MENU'
i3 on WSL: how do you want to run it?

  1) In a window via WSLg       (nothing to install on Windows, easiest)
  2) Full screen via VcXsrv/X410 (start the X server on Windows first)
  3) Full desktop via Remote Desktop (sets up xrdp, connect with mstsc)
  4) Just install i3
  5) Zsh + dark theme
  6) Change colour theme
  7) Polybar + autotiling + picom (nicer i3)
  8) GlazeWM: i3-style tiling for Windows
  9) Uninstall
  q) Quit
MENU

read -rp "Choice [1]: " choice
case "${choice:-1}" in
  1)
    read -rp "Window size: auto (90% of monitor), full, or WIDTHxHEIGHT [auto]: " size
    run_method wslg "${size:-auto}"
    ;;
  2)
    read -rp "X server display number [0]: " disp
    run_method xserver "${disp:-0}"
    ;;
  3)
    read -rp "RDP port [3390]: " port
    run_method xrdp "${port:-3390}"
    ;;
  4) run_method install ;;
  5) run_method zsh ;;
  6)
    echo "Themes: catppuccin, gruvbox, nord, tokyonight, dracula"
    read -rp "Theme [catppuccin]: " theme
    run_method theme "${theme:-catppuccin}"
    ;;
  7) run_method polybar ;;
  8) run_method glazewm ;;
  9) run_method uninstall ;;
  q|Q) exit 0 ;;
  *) echo "Invalid choice: $choice" >&2; exit 1 ;;
esac
