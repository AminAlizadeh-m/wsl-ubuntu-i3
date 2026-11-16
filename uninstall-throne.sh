#!/usr/bin/env bash
# Remove Throne completely: the program, its system files and services, its
# launchers and link handler, and (after asking) your settings.
#
#   ./uninstall-throne.sh                 asks before deleting your settings
#   ./uninstall-throne.sh --keep-config   keep ~/.config/Throne
#   ./uninstall-throne.sh --yes           no questions; settings are deleted,
#                                         but a backup is saved first
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0; KEEP=0
for a in "$@"; do
  case "$a" in
    --yes|-y)      YES=1 ;;
    --keep-config) KEEP=1 ;;
    -h|--help)     sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (see --help)" >&2; exit 1 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

ask() {  # ask "question" [default y|n]
  [[ $YES -eq 1 ]] && return 0
  local reply def="${2:-n}"
  read -rp "$1 $([[ $def == y ]] && echo '[Y/n]' || echo '[y/N]'): " reply
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

CFG="$HOME/.config/Throne"
installed=0
dpkg-query -W -f='${Status}' throne 2>/dev/null | grep -q "install ok installed" && installed=1
leftovers=()
for p in /opt/Throne /etc/throne /var/lib/throne "$CFG" \
         "$HOME/.local/share/applications/throne-url-handler.desktop" \
         "$HOME/.config/autostart/Throne.desktop"; do
  [[ -e "$p" ]] && leftovers+=("$p")
done
if [[ $installed -eq 0 && ${#leftovers[@]} -eq 0 ]]; then
  echo "Throne isn't installed; nothing to do."
  exit 0
fi

# 1. Stop it
if pgrep -x Throne >/dev/null || pgrep -x ThroneCore >/dev/null; then
  echo "==> Closing Throne"
  pkill -x Throne 2>/dev/null || true
  sleep 2
  pkill -x ThroneCore 2>/dev/null || sudo pkill -x ThroneCore 2>/dev/null || true
fi
if [[ -d /run/systemd/system ]]; then
  sudo systemctl disable --now throne.service throne-web.service >/dev/null 2>&1 || true
fi

# 2. Your settings
if [[ -d "$CFG" ]]; then
  if [[ $KEEP -eq 1 ]]; then
    echo "==> Keeping your settings in $CFG"
  elif ask "Delete your Throne settings (profiles, subscriptions) in $CFG?"; then
    if ask "Save a backup of them first?" y; then
      "$DIR/throne-config.sh" export
    fi
    rm -rf "$CFG"
    echo "==> Deleted $CFG"
  else
    echo "==> Keeping your settings in $CFG"
  fi
fi
# Backups made by throne-config.sh import
shopt -s nullglob
old=("$CFG".bak.*)
shopt -u nullglob
if [[ ${#old[@]} -gt 0 && $KEEP -eq 0 ]] &&
   ask "Delete ${#old[@]} older settings backup(s) ($(basename "${old[0]}")...)?"; then
  rm -rf "${old[@]}"
fi

# 3. The program (purge also removes /etc/throne and the menu entry)
if [[ $installed -eq 1 ]]; then
  echo "==> Removing the Throne package"
  sudo apt-get purge -y throne
fi
# Files left behind by a failed install, the headless service's data, or a
# hand-unpacked copy in /opt
sudo rm -rf /opt/Throne /etc/throne /var/lib/throne
sudo rm -f /usr/share/applications/Throne.desktop

# 4. Your launchers, autostart entry and throne:// link handler
rm -f "$HOME/.local/share/applications/throne-url-handler.desktop" \
      "$HOME/.config/autostart/Throne.desktop"
for m in "$HOME/.config/mimeapps.list" "$HOME/.local/share/applications/mimeapps.list"; do
  [[ -f "$m" ]] && sed -i '/x-scheme-handler\/throne=/d' "$m"
done
command -v update-desktop-database >/dev/null &&
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
rm -rf "$HOME/.cache/Throne"

echo "==> Throne is removed"
if [[ -n "${http_proxy:-}${https_proxy:-}" ]]; then
  echo "    Your shell still sets http_proxy/https_proxy; remove them if they pointed at Throne."
fi
