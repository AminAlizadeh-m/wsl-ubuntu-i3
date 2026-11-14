#!/usr/bin/env bash
# Remove GlazeWM (and its Zebar bar, if installed) from Windows, from WSL.
# Earlier versions of this project could install GlazeWM; its Alt shortcuts
# clash with i3. This quits it, uninstalls it with winget, and removes the
# config file this project wrote (restoring your own config if it was backed up).
#
# Usage: ./uninstall-glazewm.sh [--yes]
set -euo pipefail

YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

if ! command -v cmd.exe >/dev/null 2>&1; then
  echo "Can't run Windows programs from WSL (cmd.exe not found)." >&2
  echo "Uninstall GlazeWM in PowerShell instead:  winget uninstall GlazeWM" >&2
  exit 1
fi

if [[ $YES -eq 0 ]]; then
  read -rp "Quit and uninstall GlazeWM from Windows? [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]] || { echo "Nothing changed."; exit 0; }
fi

# Run Windows programs from a Windows folder, otherwise cmd.exe warns about UNC paths.
win() { (cd /mnt/c 2>/dev/null; "$@"); }

echo "==> Quitting GlazeWM and Zebar"
for exe in glazewm.exe glazewm-watcher.exe zebar.exe; do
  win taskkill.exe /IM "$exe" /F >/dev/null 2>&1 || true
done

# uninstall_pkg <id> <name>: uninstall with winget if it's installed
uninstall_pkg() {
  if win winget.exe list --exact --id "$1" >/dev/null 2>&1 ||
     win winget.exe list --name "$2" >/dev/null 2>&1; then
    echo "==> Uninstalling $2"
    win winget.exe uninstall --exact --id "$1" --silent ||
      win winget.exe uninstall --name "$2" --silent ||
      echo "    winget couldn't uninstall $2. In PowerShell run:  winget uninstall $2"
  else
    echo "==> $2 is not installed"
  fi
}
if command -v winget.exe >/dev/null 2>&1; then
  uninstall_pkg glzr-io.glazewm GlazeWM
  uninstall_pkg glzr-io.zebar Zebar
else
  echo "    winget not found. Uninstall GlazeWM from Windows Settings > Apps."
fi

# Config file written by setup-glazewm.sh
WIN_PROFILE="$(win cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
if [[ -n "$WIN_PROFILE" && "$WIN_PROFILE" != "%USERPROFILE%" ]]; then
  CFG="$(wslpath "$WIN_PROFILE")/.glzr/glazewm/config.yaml"
  if [[ -f "$CFG.pre-wsl-i3" ]]; then
    mv -f "$CFG.pre-wsl-i3" "$CFG"
    echo "==> Restored your previous GlazeWM config"
  elif [[ -f "$CFG" ]] && grep -q 'setup-glazewm.sh' "$CFG"; then
    rm -f "$CFG"
    echo "==> Removed the GlazeWM config this project wrote"
  fi
  # Remove the folders if nothing else is left in them
  rmdir "$(dirname "$CFG")" "$(dirname "$(dirname "$CFG")")" 2>/dev/null || true
fi

echo
echo "Done. Alt shortcuts now go only to i3."
