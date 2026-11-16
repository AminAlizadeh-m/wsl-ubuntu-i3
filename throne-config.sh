#!/usr/bin/env bash
# Move your Throne settings (profiles, subscriptions, routing rules, all
# options) from one system to another.
#
#   ./throne-config.sh export [FILE]   save ~/.config/Throne to FILE
#                                      (default ~/throne-config-DATE.tar.gz)
#   ./throne-config.sh import SOURCE   load settings from SOURCE: a file made
#                                      by export, or a Throne folder (e.g. a
#                                      Windows one: /mnt/c/.../Throne)
#
# Export works while Throne is running. Import closes Throne first and keeps
# your current settings as ~/.config/Throne.bak.DATE.
#
# The backup holds your proxy servers and passwords: it's readable only by
# you. Don't put it in git or share it.
set -euo pipefail

CFG="$HOME/.config/Throne"
umask 077

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

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
    out="${1:-$HOME/throne-config-$(date +%Y%m%d-%H%M%S).tar.gz}"
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
    echo "==> Saved $out ($(du -h "$out" | cut -f1))"
    echo "    It contains your proxy servers and passwords: keep it private."
    echo "    Copy it to the other system, then run there:"
    echo "      ./throne-config.sh import $(basename "$out")"
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

    if pgrep -x Throne >/dev/null; then
      echo "==> Closing Throne (it would overwrite the imported settings)"
      pkill -x Throne || true
      for _ in 1 2 3 4 5; do pgrep -x Throne >/dev/null || break; sleep 1; done
      pkill -x ThroneCore 2>/dev/null || true
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
    echo "==> Imported. Start Throne (Alt+d, \"Throne\") to use them."
    ;;

  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $cmd (use export or import)" >&2; exit 1 ;;
esac
