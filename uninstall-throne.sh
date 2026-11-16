#!/usr/bin/env bash
# Remove Throne completely: the program, its system files and services, its
# launchers and link handler, and (after asking) the settings: yours and
# root's (the Throne you start as root with Alt+Shift+d keeps its own
# settings in /root).
#
#   ./uninstall-throne.sh                 asks before deleting settings
#   ./uninstall-throne.sh --keep-config   keep the settings (yours and root's)
#   ./uninstall-throne.sh --yes           no questions; settings are deleted,
#                                         but backups are saved first
# Running it with sudo works too.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0; KEEP=0
for a in "$@"; do
  case "$a" in
    --yes|-y)      YES=1 ;;
    --keep-config) KEEP=1 ;;
    -h|--help)     sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (see --help)" >&2; exit 1 ;;
  esac
done

ask() {  # ask "question" [default y|n]
  [[ $YES -eq 1 ]] && return 0
  local reply def="${2:-n}"
  read -rp "$1 $([[ $def == y ]] && echo '[Y/n]' || echo '[y/N]'): " reply
  reply="${reply:-$def}"
  [[ "$reply" =~ ^[Yy] ]]
}

# Your user and home, also when run with sudo
if [[ $EUID -eq 0 ]]; then
  USR="${SUDO_USER:-}"
  [[ "$USR" == root ]] && USR=""
else
  USR="$USER"
fi
UHOME=""
[[ -n "$USR" ]] && UHOME="$(getent passwd "$USR" | cut -d: -f6)"

# as_root CMD / as_user CMD: run a command as root or as you
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
as_user() { if [[ $EUID -eq 0 ]]; then sudo -u "$USR" "$@"; else "$@"; fi; }
# in_home HOME CMD: run CMD as the owner of HOME
in_home() { local h="$1"; shift; if [[ "$h" == /root ]]; then as_root "$@"; else as_user "$@"; fi; }

echo "==> sudo is needed (enter your Linux password if asked)"
as_root true

# The homes with Throne files: yours and root's
homes=()
for h in "$UHOME" /root; do
  [[ -n "$h" ]] || continue
  if in_home "$h" sh -c 'for p in "$1"/.config/Throne "$1"/.config/Throne.bak.* "$1"/.cache/Throne \
       "$1"/.local/share/applications/throne-url-handler.desktop "$1"/.config/autostart/Throne.desktop; do
       [ -e "$p" ] && exit 0; done; exit 1' _ "$h" 2>/dev/null; then
    homes+=("$h")
  fi
done
installed=0
dpkg-query -W -f='${Status}' throne 2>/dev/null | grep -q "install ok installed" && installed=1
if [[ $installed -eq 0 && ${#homes[@]} -eq 0 && ! -e /opt/Throne && ! -e /etc/throne ]] &&
   ! as_root test -e /var/lib/throne; then
  echo "Throne isn't installed; nothing to do."
  exit 0
fi

# 0. Undo throne-proxy.sh (it would send traffic to a Throne that's gone)
if [[ -n "$UHOME" ]] && { [[ -f "$UHOME/.config/throne-proxy.env" ]] ||
     [[ -f /etc/apt/apt.conf.d/95throne-proxy ]] || [[ -d /etc/throne-proxy ]]; }; then
  echo "==> Turning off throne-proxy.sh"
  as_user env HOME="$UHOME" "$DIR/throne-proxy.sh" off >/dev/null || true
fi

# 1. Stop it (yours and root's)
if pgrep -x 'Throne|ThroneCore' >/dev/null; then
  echo "==> Closing Throne"
  as_root pkill -x Throne 2>/dev/null || true
  sleep 2
  as_root pkill -x ThroneCore 2>/dev/null || true
fi
if [[ -d /run/systemd/system ]]; then
  as_root systemctl disable --now throne.service throne-web.service >/dev/null 2>&1 || true
fi

# 2. Settings, per home
for h in "${homes[@]}"; do
  if [[ "$h" == /root ]]; then who="root's"; rootopt=(--root); else who="your"; rootopt=(); fi
  cfg="$h/.config/Throne"
  if in_home "$h" test -d "$cfg"; then
    if [[ $KEEP -eq 1 ]]; then
      echo "==> Keeping $who settings in $cfg"
    elif ask "Delete $who Throne settings (profiles, subscriptions) in $cfg?"; then
      if ask "Save a backup of them first?" y; then
        # The backup goes to your home either way
        if [[ $EUID -eq 0 && -n "$USR" && "$h" != /root ]]; then
          sudo -u "$USR" "$DIR/throne-config.sh" export
        else
          "$DIR/throne-config.sh" "${rootopt[@]}" export
        fi
      fi
      in_home "$h" rm -rf "$cfg"
      echo "==> Deleted $cfg"
    else
      echo "==> Keeping $who settings in $cfg"
    fi
  fi
  # Backups made by throne-config.sh import
  mapfile -t old < <(in_home "$h" find "$h/.config" -maxdepth 1 -name 'Throne.bak.*' 2>/dev/null)
  if [[ ${#old[@]} -gt 0 && $KEEP -eq 0 ]] &&
     ask "Delete ${#old[@]} older backup(s) of $who settings ($(basename "${old[0]}")...)?"; then
    in_home "$h" rm -rf "${old[@]}"
  fi
  # Launchers, autostart entry, throne:// link handler, cache
  in_home "$h" rm -rf "$h/.local/share/applications/throne-url-handler.desktop" \
    "$h/.config/autostart/Throne.desktop" "$h/.cache/Throne"
  for m in "$h/.config/mimeapps.list" "$h/.local/share/applications/mimeapps.list"; do
    in_home "$h" sed -i '/x-scheme-handler\/throne=/d' "$m" 2>/dev/null || true
  done
done
if [[ -n "$UHOME" ]] && command -v update-desktop-database >/dev/null; then
  as_user update-desktop-database "$UHOME/.local/share/applications" 2>/dev/null || true
fi

# 3. The program (purge also removes /etc/throne and the menu entry)
if [[ $installed -eq 1 ]]; then
  echo "==> Removing the Throne package"
  as_root apt-get purge -y throne
fi
# Files left behind by a failed install, the headless service's data, or a
# hand-unpacked copy in /opt
as_root rm -rf /opt/Throne /etc/throne /var/lib/throne
as_root rm -f /usr/share/applications/Throne.desktop
# The group throne-proxy.sh gives Throne's core
getent group throne-proxy >/dev/null && { as_root groupdel throne-proxy 2>/dev/null || true; }

echo "==> Throne is removed"
if [[ -n "${http_proxy:-}${https_proxy:-}" ]]; then
  echo "    Your shell still sets http_proxy/https_proxy; remove them if they pointed at Throne."
fi
