#!/usr/bin/env bash
# Move your Throne settings (profiles, subscriptions, routing rules, all
# options) from one system to another.
#
#   ./throne-config.sh export [FILE]   save ~/.config/Throne to FILE
#                                      (default ~/throne-config-DATE.tar.gz)
#   ./throne-config.sh import SOURCE   load settings from SOURCE: a file made
#                                      by export, or a Throne folder (e.g. a
#                                      Windows one: /mnt/c/.../Throne)
#   --root (before export/import)      root's settings instead of yours: the
#                                      Throne you start as root (Alt+Shift+d)
#                                      keeps separate settings in /root
#
# Export works while Throne is running. Import closes Throne first and keeps
# your current settings as ~/.config/Throne.bak.DATE.
#
# The backup holds your proxy servers and passwords: it's readable only by
# you. Don't put it in git or share it.
set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

# --root: run this script as root, with root's home. The backup file still
# goes to your home and belongs to you.
if [[ "${1:-}" == --root ]]; then
  shift
  if [[ $EUID -ne 0 ]]; then
    exec sudo env HOME=/root THRONE_OWNER="$USER" THRONE_OWNER_HOME="$HOME" \
      PATH="$PATH" bash "$0" "$@"
  fi
  export HOME=/root
fi
OWNER="${THRONE_OWNER:-${SUDO_USER:-}}"
OWNER_HOME="${THRONE_OWNER_HOME:-}"
if [[ -z "$OWNER_HOME" && -n "$OWNER" ]]; then
  OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
fi
OWNER_HOME="${OWNER_HOME:-$HOME}"
WHO=""; [[ $EUID -eq 0 ]] && WHO="root-"

CFG="$HOME/.config/Throne"
umask 077

# copy_snapshot SRC_CONFIG_DIR DEST_DIR: copy a Throne "config" folder.
# The SQLite databases are copied with SQLite's backup, so a running Throne
# (which keeps recent changes in -wal files) gives a complete, consistent
# copy. cache.db is sing-box's cache (rebuilt on start), so it's left out.
copy_snapshot() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  (cd "$src" && find . -type d) | while IFS= read -r d; do mkdir -p "$dst/$d"; done
  (cd "$src" && find . -type f ! -name '*.db-wal' ! -name '*.db-shm' ! -name '*.lock' ! -path ./cache.db) |
  while IFS= read -r f; do
    if [[ "$(head -c 15 "$src/$f")" == "SQLite format 3" ]]; then
      python3 -I - "$src/$f" "$dst/$f" <<'PY'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY
    else
      cp -p "$src/$f" "$dst/$f"
    fi
  done
}

# find_config_dir PATH: the Throne "config" folder inside PATH
find_config_dir() {
  local p="$1"
  for c in "$p" "$p/config" "$p/Throne/config"; do
    if [[ -f "$c/throne.db" || -f "$c/groups/pm.json" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  export)
    out="${1:-$OWNER_HOME/throne-config-$WHO$(date +%Y%m%d-%H%M%S).tar.gz}"
    [[ -n "${1:-}" || ! -e "$out" ]] || out="${out%.tar.gz}-$$.tar.gz"
    src="$(find_config_dir "$CFG")" || { echo "No Throne settings found in $CFG" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "python3 is needed: sudo apt install python3" >&2; exit 1; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    echo "==> Copying settings from $src"
    copy_snapshot "$src" "$tmp/Throne/config"
    # Anything else Throne keeps next to config/ (small files only)
    for f in "$CFG"/*; do
      [[ "$(basename "$f")" == config ]] && continue
      [[ -e "$f" ]] && cp -a "$f" "$tmp/Throne/"
    done
    tar -czf "$out" -C "$tmp" Throne
    chmod 600 "$out"
    [[ $EUID -eq 0 && -n "$OWNER" ]] && chown "$OWNER:" "$out"
    echo "==> Saved $out ($(du -h "$out" | cut -f1))"
    echo "    It contains your proxy servers and passwords: keep it private."
    echo "    Copy it to the other system, then run there:"
    echo "      ./throne-config.sh ${WHO:+--root }import $(basename "$out")"
    ;;

  import)
    source="${1:-}"
    [[ -n "$source" ]] || { usage >&2; exit 1; }
    [[ -e "$source" ]] || { echo "Not found: $source" >&2; exit 1; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    if [[ -f "$source" ]]; then
      # Only accept archives whose files all stay inside Throne/
      if tar -tzf "$source" | grep -qvE '^(\./)?Throne(/|$)' ||
         tar -tzf "$source" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
        echo "$source isn't a backup made by '$0 export'." >&2; exit 1
      fi
      tar -xzf "$source" -C "$tmp" --no-same-owner
      src="$(find_config_dir "$tmp/Throne")" || { echo "No Throne settings in $source" >&2; exit 1; }
      new="$tmp/Throne"
    else
      src="$(find_config_dir "$source")" ||
        { echo "No Throne settings (config/throne.db) in $source" >&2; exit 1; }
      command -v python3 >/dev/null || { echo "python3 is needed: sudo apt install python3" >&2; exit 1; }
      echo "==> Copying settings from $src"
      copy_snapshot "$src" "$tmp/new/config"
      new="$tmp/new"
    fi

    # Only the Throne using these settings (yours, or root's with --root)
    me="$(id -u)"
    if pgrep -x -u "$me" Throne >/dev/null; then
      echo "==> Closing Throne (it would overwrite the imported settings)"
      pkill -x -u "$me" Throne || true
      for _ in 1 2 3 4 5; do pgrep -x -u "$me" Throne >/dev/null || break; sleep 1; done
      pkill -x -u "$me" ThroneCore 2>/dev/null || true
    fi
    if [[ -d "$CFG" ]]; then
      bak="$CFG.bak.$(date +%Y%m%d-%H%M%S)"
      [[ -e "$bak" ]] && bak="$bak-$$"
      mv -T "$CFG" "$bak"
      echo "==> Your previous settings: $bak"
    fi
    mkdir -p "$(dirname "$CFG")"
    cp -a "$new" "$CFG"
    chmod -R go-rwx "$CFG"
    if [[ $EUID -eq 0 ]]; then
      echo "==> Imported into root's settings. Start Throne as root (Alt+Shift+d, \"Throne\")."
    else
      echo "==> Imported. Start Throne (Alt+d, \"Throne\") to use them."
    fi
    ;;

  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $cmd (use export or import)" >&2; exit 1 ;;
esac
