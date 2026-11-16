#!/usr/bin/env bash
# Install Throne, a GUI proxy client (sing-box), from its GitHub releases.
#
#   ./install-throne.sh                      latest release
#   ./install-throne.sh --deb FILE.deb       a .deb you downloaded yourself
#                                            (when GitHub can't be reached)
#   ./install-throne.sh --config BACKUP      also bring in your Throne settings
#                                            (made with ./throne-config.sh export,
#                                            or a Throne folder, e.g. from Windows)
#   ./install-throne.sh --tun                let TUN mode work without root
#
# Open it in i3 with Alt+d, "Throne". Undo with ./uninstall-throne.sh.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_API="https://api.github.com/repos/throneproj/Throne/releases/latest"
DEB=""; CONFIG=""; TUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deb)    DEB="${2:?--deb needs a file}"; shift ;;
    --config) CONFIG="${2:?--config needs a backup file or folder}"; shift ;;
    --tun)    TUN=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi
[[ -z "$CONFIG" || -e "$CONFIG" ]] || { echo "Not found: $CONFIG" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -z "$DEB" ]]; then
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ;;
    *) echo "Throne has no Linux build for $arch." >&2; exit 1 ;;
  esac
  echo "==> Looking up the latest Throne release"
  if ! curl -fsSL --max-time 20 "$REPO_API" -o "$TMP/release.json"; then
    echo "    Can't reach GitHub. If it's a certificate error, see ./import-windows-certs.sh." >&2
    echo "    Or download Throne-<version>-debian-$arch.deb from" >&2
    echo "    https://github.com/throneproj/Throne/releases and run: $0 --deb FILE" >&2
    exit 1
  fi
  # The .deb with Qt included ("-system-qt" ones need Qt from Ubuntu)
  read -r version url digest < <(python3 -I - "$TMP/release.json" "$arch" <<'PY'
import json, sys
rel = json.load(open(sys.argv[1]))
want = f"-debian-{sys.argv[2]}.deb"
for a in rel.get("assets", []):
    if a["name"].endswith(want):
        print(rel["tag_name"], a["browser_download_url"], a.get("digest") or "-")
        break
PY
  ) || true
  if [[ -z "${url:-}" ]]; then
    echo "    No Debian package for $arch in the latest release." >&2; exit 1
  fi
  current="$(dpkg-query -W -f='${Version}' throne 2>/dev/null || true)"
  if [[ "$current" == "$version" ]]; then
    echo "==> Throne $version is already installed"
  else
    echo "==> Downloading Throne $version${current:+ (installed: $current)}"
    DEB="$TMP/$(basename "$url")"
    curl -fL --progress-bar --max-time 600 "$url" -o "$DEB"
    if [[ "$digest" == sha256:* ]]; then
      echo "${digest#sha256:}  $DEB" | sha256sum -c --quiet - ||
        { echo "    The download is damaged (checksum mismatch). Try again." >&2; exit 1; }
      echo "    Checksum OK"
    fi
  fi
fi

if [[ -n "$DEB" ]]; then
  [[ -f "$DEB" ]] || { echo "Not found: $DEB" >&2; exit 1; }
  case "$(dpkg-deb -f "$DEB" Package 2>/dev/null)" in
    throne) ;;
    *) echo "$DEB isn't a Throne package." >&2; exit 1 ;;
  esac
  # A running Throne keeps the old files busy
  if pgrep -x Throne >/dev/null; then
    echo "==> Closing Throne for the update"
    pkill -x Throne || true; sleep 2; pkill -x ThroneCore 2>/dev/null || true
  fi
  echo "==> Installing $(basename "$DEB")"
  # apt needs a path with a slash to treat it as a file
  [[ "$DEB" == */* ]] || DEB="./$DEB"
  sudo apt-get update -qq || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$(readlink -f "$DEB")"
fi

# TUN mode routes all traffic through Throne; its core needs the right to
# create network interfaces. (An update replaces the file: run --tun again.)
if [[ $TUN -eq 1 ]]; then
  echo "==> Allowing TUN mode"
  command -v setcap >/dev/null || sudo apt-get install -y libcap2-bin
  sudo setcap cap_net_admin,cap_net_raw,cap_net_bind_service+ep /opt/Throne/ThroneCore
  [[ -e /dev/net/tun ]] || echo "    /dev/net/tun is missing, so TUN mode won't work in this WSL."
fi

if [[ -n "$CONFIG" ]]; then
  "$DIR/throne-config.sh" import "$CONFIG"
fi

cat <<'EOF'

Throne is installed. In i3 press Alt+d and type "Throne" (or run
/opt/Throne/Throne -appdata in a terminal).

Throne's "system proxy" switch doesn't reach WSL programs. Either turn on
TUN mode (install with --tun), or point programs at Throne's port
(Settings > Inbound, 2080 by default), e.g.:
  export http_proxy=http://127.0.0.1:2080 https_proxy=http://127.0.0.1:2080
EOF
