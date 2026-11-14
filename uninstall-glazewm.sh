#!/usr/bin/env bash
# Undo what the old setup-glazewm.sh did on Windows, and nothing more:
#   - it wrote %USERPROFILE%\.glzr\glazewm\config.yaml (backing up yours)
#   - it tried to install GlazeWM with winget
# Each step is skipped if it never happened, so this is safe to run even if
# GlazeWM was never installed.
#
# Usage: ./uninstall-glazewm.sh
set -euo pipefail

if ! command -v cmd.exe >/dev/null 2>&1; then
  echo "Can't run Windows programs from WSL (cmd.exe not found), so there's nothing this script can check." >&2
  exit 1
fi

# Run Windows programs from a Windows folder, otherwise cmd.exe warns about UNC paths.
win() { (cd /mnt/c 2>/dev/null; "$@"); }

did_something=0

# ---------------------------------------------------------------- config file
WIN_PROFILE="$(win cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
if [[ -n "$WIN_PROFILE" && "$WIN_PROFILE" != "%USERPROFILE%" ]]; then
  CFG="$(wslpath "$WIN_PROFILE")/.glzr/glazewm/config.yaml"
  if [[ -f "$CFG.pre-wsl-i3" ]]; then
    mv -f "$CFG.pre-wsl-i3" "$CFG"
    echo "==> Restored your previous GlazeWM config"
    did_something=1
  elif [[ -f "$CFG" ]] && grep -q 'setup-glazewm.sh' "$CFG"; then
    rm -f "$CFG"
    echo "==> Removed the GlazeWM config written by setup-glazewm.sh"
    did_something=1
  fi
  # Remove the folders only if nothing else is left in them
  rmdir "$(dirname "$CFG")" "$(dirname "$(dirname "$CFG")")" 2>/dev/null || true
fi

# ---------------------------------------------------------------- running?
if win tasklist.exe /FI "IMAGENAME eq glazewm.exe" 2>/dev/null | grep -qi 'glazewm.exe'; then
  echo "==> Quitting GlazeWM"
  win taskkill.exe /IM glazewm.exe /F >/dev/null 2>&1 || true
  did_something=1
fi

# ---------------------------------------------------------------- installed?
# setup-glazewm.sh installed it with winget. Without winget it couldn't have.
if command -v winget.exe >/dev/null 2>&1 &&
   win winget.exe list --exact --id glzr-io.glazewm 2>/dev/null | grep -qi 'glazewm'; then
  echo "==> Uninstalling GlazeWM (winget)"
  win winget.exe uninstall --exact --id glzr-io.glazewm --silent ||
    echo "    winget couldn't uninstall it. In PowerShell run:  winget uninstall GlazeWM"
  did_something=1
fi

echo
if [[ $did_something -eq 1 ]]; then
  echo "Done. GlazeWM changes from this project are undone."
else
  echo "Nothing to do: GlazeWM isn't installed or running, and there's no config from this project."
fi
