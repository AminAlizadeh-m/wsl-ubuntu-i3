#!/usr/bin/env bash
# Connect to a VLESS server in TUN mode with sing-box (no Throne needed):
# all of Ubuntu's traffic, DNS included, goes through the server.
#
#   ./vless-tun.sh install [--version 1.14.4]   install sing-box (latest by default)
#   ./vless-tun.sh up 'vless://...'             connect (the link is saved)
#   ./vless-tun.sh up                           connect with the saved link
#   ./vless-tun.sh up FILE                      the link from a file
#   ./vless-tun.sh up ... --kill-switch         no internet while disconnected
#   ./vless-tun.sh down                         disconnect
#   ./vless-tun.sh status                       connected? which IP?
#   ./vless-tun.sh log                          follow sing-box's log
#   ./vless-tun.sh config ['vless://...']       print the generated sing-box config
#
# Put the link in quotes: it contains & and #.
# Supported: security none / tls / reality, transports tcp, ws, grpc, http
# (h2) and httpupgrade, flow xtls-rprx-vision. (xhttp isn't supported by
# sing-box.)
#
# Kill switch: until "down", nothing may leave this machine except through the
# tunnel (your LAN and Windows stay reachable). If sing-box stops, there's no
# internet instead of an unprotected connection.
#
# After restarting WSL, run "up" again. Undo everything: ./vless-tun.sh down,
# then sudo apt purge sing-box.
set -euo pipefail

STATE="$HOME/.config/vless-tun"
LINK_FILE="$STATE/link"
ETC=/etc/vless-tun
CONF="$ETC/config.json"
RESOLV_BAK="$ETC/resolv.conf.before"
PIDF=/run/vless-tun.pid
LOG=/var/log/vless-tun.log
IFACE=vless-tun
TUN_ADDR=198.18.0.1/30     # benchmark range: doesn't clash with WSL or a LAN
TUN_DNS=198.18.0.2         # DNS sent here is answered through the tunnel
GROUP=vless-tun            # sing-box runs with this group (kill switch)
KS=VLESS_KILLSWITCH
LOCAL_NETS=(10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
            192.168.0.0/16 224.0.0.0/4 255.255.255.255/32)
LOCAL_NETS6=(::1/128 fe80::/10 fc00::/7 ff00::/8)

usage() { sed -n "2,$(( $(grep -n '^set -euo' "$0" | cut -d: -f1) - 1 ))p" "$0" | sed 's/^# \{0,1\}//'; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

cmd="${1:-}"; shift || true
LINK=""; VERSION=""; KILL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kill-switch) KILL=1 ;;
    --version)     VERSION="${2:?--version needs a version, e.g. 1.14.4}"; VERSION="${VERSION#v}"; shift ;;
    -*)            echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    *)             LINK="$1" ;;
  esac
  shift
done

IPT="sudo iptables -w"; IPT6="sudo ip6tables -w"
have() { command -v "$1" >/dev/null 2>&1 || [[ -x "/usr/sbin/$1" ]]; }
running() { sudo test -f "$PIDF" && sudo kill -0 "$(sudo cat "$PIDF")" 2>/dev/null; }

# The link: from the argument (a link or a file holding one), else the saved one
get_link() {
  local l="$LINK"
  if [[ -n "$l" && "$l" != vless://* && -f "$l" ]]; then
    l="$(grep -m1 -o 'vless://[^[:space:]]*' "$l" || true)"
  fi
  if [[ -z "$l" && -f "$LINK_FILE" ]]; then l="$(cat "$LINK_FILE")"; fi
  if [[ "$l" != vless://* ]]; then
    echo "Give a vless:// link (in quotes): $0 up 'vless://...'" >&2; exit 1
  fi
  printf '%s' "$l"
}

# make_config LINK SERVER_IP: print the sing-box config for LINK
make_config() {
  python3 -I - "$1" "$2" "$IFACE" "$TUN_ADDR" <<'PY'
import json, sys
from urllib.parse import urlsplit, parse_qs, unquote

link, server_ip, iface, tun_addr = sys.argv[1:5]

def fail(msg):
    sys.exit("Can't use this link: " + msg)

u = urlsplit(link)
if u.scheme != "vless": fail("it isn't a vless:// link")
q = {k: v[-1] for k, v in parse_qs(u.query, keep_blank_values=True).items()}
uuid = unquote(u.username or "")
host = u.hostname or ""
try:
    port = u.port
except ValueError:
    fail("bad port")
if not uuid or not host or not port: fail("it needs uuid@server:port")

enc = q.get("encryption", "none") or "none"
if enc != "none": fail(f"encryption={enc} isn't supported by sing-box")

out = {"type": "vless", "tag": "proxy", "server": server_ip or host,
       "server_port": port, "uuid": uuid, "packet_encoding": "xudp"}
if q.get("flow"): out["flow"] = q["flow"]

net = (q.get("type") or "tcp").lower()
path = q.get("path", "")
thost = q.get("host", "")
if net in ("tcp", "raw"):
    if q.get("headerType", "none") not in ("", "none"):
        fail("tcp with headerType=" + q["headerType"] + " isn't supported")
elif net == "ws":
    t = {"type": "ws", "path": path or "/"}
    if "?ed=" in t["path"]:                      # early data: /path?ed=2048
        p, ed = t["path"].split("?ed=", 1)
        t["path"] = p or "/"
        if ed.isdigit():
            t["max_early_data"] = int(ed)
            t["early_data_header_name"] = "Sec-WebSocket-Protocol"
    if thost: t["headers"] = {"Host": thost}
    out["transport"] = t
elif net == "grpc":
    out["transport"] = {"type": "grpc", "service_name": q.get("serviceName", "")}
elif net in ("http", "h2"):
    t = {"type": "http", "path": path or "/"}
    if thost: t["host"] = thost.split(",")
    out["transport"] = t
elif net == "httpupgrade":
    t = {"type": "httpupgrade", "path": path or "/"}
    if thost: t["host"] = thost
    out["transport"] = t
else:
    fail(f"transport type={net} isn't supported by sing-box")

sec = (q.get("security") or "none").lower()
is_ip = host.replace(".", "").isdigit() or ":" in host
if sec in ("tls", "reality"):
    tls = {"enabled": True}
    sni = q.get("sni") or q.get("serverName") or (thost if thost and net != "grpc" else "") or ("" if is_ip else host)
    if sni: tls["server_name"] = sni
    if q.get("allowInsecure", q.get("insecure", "0")) in ("1", "true"): tls["insecure"] = True
    if q.get("alpn"): tls["alpn"] = [a for a in q["alpn"].split(",") if a]
    fp = q.get("fp", "")
    if sec == "reality":
        if not q.get("pbk"): fail("reality needs pbk (public key)")
        tls["reality"] = {"enabled": True, "public_key": q["pbk"], "short_id": q.get("sid", "")}
        fp = fp or "chrome"                      # reality needs uTLS
    if fp: tls["utls"] = {"enabled": True, "fingerprint": fp}
    out["tls"] = tls
elif sec != "none":
    fail(f"security={sec} isn't supported")

config = {
    "log": {"level": "info", "timestamp": True},
    "dns": {
        "servers": [
            {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"},
        ],
        "final": "remote",
        "strategy": "ipv4_only",
    },
    "inbounds": [{
        "type": "tun", "tag": "tun-in", "interface_name": iface,
        "address": [tun_addr], "mtu": 1400,
        "auto_route": True, "strict_route": False, "stack": "mixed",
    }],
    "outbounds": [out, {"type": "direct", "tag": "direct"}],
    "route": {
        "rules": [
            {"action": "sniff"},
            {"protocol": "dns", "action": "hijack-dns"},
            {"ip_is_private": True, "outbound": "direct"},
        ],
        "final": "proxy",
        "auto_detect_interface": True,
    },
}
print(json.dumps(config, indent=2))
PY
}

# The server's address, looked up now (before DNS goes through the tunnel)
server_ip() {
  local host
  host="$(python3 -I -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).hostname or "")' "$1")"
  if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]]; then echo "$host"; return; fi
  getent ahostsv4 "$host" | awk 'NR==1 {print $1}'
}

ks_off() {
  if have iptables; then
    while $IPT -D OUTPUT -j "$KS" 2>/dev/null; do :; done
    $IPT -F "$KS" 2>/dev/null || true; $IPT -X "$KS" 2>/dev/null || true
  fi
  if have ip6tables; then
    while $IPT6 -D OUTPUT -j "$KS" 2>/dev/null; do :; done
    $IPT6 -F "$KS" 2>/dev/null || true; $IPT6 -X "$KS" 2>/dev/null || true
  fi
  return 0
}

ks_on() {
  have iptables || sudo apt-get install -y iptables >/dev/null
  ks_off
  local n
  $IPT -N "$KS"
  $IPT -A "$KS" -o lo -j RETURN
  $IPT -A "$KS" -o "$IFACE" -j RETURN
  $IPT -A "$KS" -m owner --gid-owner "$GROUP" -j RETURN
  for n in "${LOCAL_NETS[@]}"; do $IPT -A "$KS" -d "$n" -j RETURN; done
  $IPT -A "$KS" -p tcp -j REJECT --reject-with tcp-reset
  $IPT -A "$KS" -j REJECT
  $IPT -A OUTPUT -j "$KS"
  if have ip6tables; then
    $IPT6 -N "$KS"
    $IPT6 -A "$KS" -o lo -j RETURN
    $IPT6 -A "$KS" -o "$IFACE" -j RETURN
    $IPT6 -A "$KS" -m owner --gid-owner "$GROUP" -j RETURN
    for n in "${LOCAL_NETS6[@]}"; do $IPT6 -A "$KS" -d "$n" -j RETURN; done
    $IPT6 -A "$KS" -j REJECT
    $IPT6 -A OUTPUT -j "$KS"
  fi
}

dns_on() {   # send the system's DNS into the tunnel
  if ! sudo test -e "$RESOLV_BAK"; then
    sudo mv /etc/resolv.conf "$RESOLV_BAK"   # (keeps a symlink a symlink)
  else
    sudo rm -f /etc/resolv.conf
  fi
  printf '# Written by vless-tun.sh (DNS goes through the tunnel). "down" restores the old file.\nnameserver %s\n' \
    "$TUN_DNS" | sudo tee /etc/resolv.conf >/dev/null
}

dns_off() {
  if sudo test -e "$RESOLV_BAK" || sudo test -L "$RESOLV_BAK"; then
    sudo rm -f /etc/resolv.conf
    sudo mv "$RESOLV_BAK" /etc/resolv.conf
  fi
}

stop_singbox() {
  if sudo test -f "$PIDF"; then
    local pid; pid="$(sudo cat "$PIDF")"
    sudo kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do sudo kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    sudo kill -9 "$pid" 2>/dev/null || true
    sudo rm -f "$PIDF"
  fi
}

install_singbox() {
  local arch api url digest version
  arch="$(dpkg --print-architecture)"
  case "$arch" in amd64|arm64|armhf|i386) ;; *) echo "No sing-box build for $arch" >&2; exit 1 ;; esac
  if [[ -n "$VERSION" ]]; then api="https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$VERSION"
  else api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"; fi
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  echo "==> Looking up sing-box ${VERSION:-(latest)}"
  if ! curl -fsSL --max-time 90 "$api" -o "$tmp/rel.json"; then
    echo "    Can't reach GitHub (or no such version). Download sing-box_<version>_linux_$arch.deb" >&2
    echo "    from https://github.com/SagerNet/sing-box/releases and run: sudo apt install ./FILE.deb" >&2
    exit 1
  fi
  read -r version url digest < <(python3 -I - "$tmp/rel.json" "$arch" <<'PY'
import json, sys
rel = json.load(open(sys.argv[1])); want = f"_linux_{sys.argv[2]}.deb"
for a in rel.get("assets", []):
    if a["name"].startswith("sing-box_") and a["name"].endswith(want):
        print(rel["tag_name"].lstrip("v"), a["browser_download_url"], a.get("digest") or "-"); break
PY
  ) || true
  [[ -n "${url:-}" ]] || { echo "    No .deb for $arch in that release." >&2; exit 1; }
  if [[ "$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)" == "$version" ]]; then
    echo "==> sing-box $version is already installed"; return
  fi
  echo "==> Downloading sing-box $version"
  curl -fL --progress-bar --max-time 600 "$url" -o "$tmp/sing-box.deb"
  if [[ "$digest" == sha256:* ]]; then
    echo "${digest#sha256:}  $tmp/sing-box.deb" | sha256sum -c --quiet - ||
      { echo "    The download is damaged (checksum mismatch)." >&2; exit 1; }
  fi
  sudo apt-get install -y --allow-downgrades "$tmp/sing-box.deb"
  # The package's own service would start a second sing-box with its sample config
  [[ -d /run/systemd/system ]] && { sudo systemctl disable --now sing-box >/dev/null 2>&1 || true; }
  echo "==> sing-box $version installed"
}

case "$cmd" in
  install)
    install_singbox
    ;;

  config)
    l="$(get_link)"
    make_config "$l" "$(server_ip "$l")"
    ;;

  up)
    command -v python3 >/dev/null || { echo "python3 is needed: sudo apt install python3" >&2; exit 1; }
    l="$(get_link)"
    echo "==> sudo is needed (enter your Linux password if asked)"
    sudo true
    command -v sing-box >/dev/null || install_singbox
    # Start clean (a previous connection, its DNS change and kill switch)
    stop_singbox; dns_off; ks_off
    ip="$(server_ip "$l")"
    [[ -n "$ip" ]] || { echo "Can't look up the server's address. Is the internet working?" >&2; exit 1; }
    mkdir -p "$STATE"; chmod 700 "$STATE"
    (umask 077; printf '%s\n' "$l" > "$LINK_FILE")
    name="$(python3 -I -c 'import sys; from urllib.parse import urlsplit, unquote; print(unquote(urlsplit(sys.argv[1]).fragment) or "server")' "$l")"
    echo "==> Connecting to $name ($ip)"
    sudo mkdir -p "$ETC"; sudo chmod 700 "$ETC"
    make_config "$l" "$ip" | sudo tee "$CONF" >/dev/null
    sudo chmod 600 "$CONF"
    if ! sudo sing-box check -c "$CONF"; then
      echo "    sing-box rejected the config (see above)." >&2; exit 1
    fi
    getent group "$GROUP" >/dev/null || sudo groupadd --system "$GROUP"
    # Run as root (it creates the tunnel) with the vless-tun group
    gid="$(getent group "$GROUP" | cut -d: -f3)"
    sudo bash -c "setsid setpriv --regid=$gid --clear-groups sing-box run -c '$CONF' >>'$LOG' 2>&1 </dev/null & echo \$! > '$PIDF'"
    for _ in $(seq 1 20); do ip link show "$IFACE" >/dev/null 2>&1 && break; running || break; sleep 0.5; done
    if ! running || ! ip link show "$IFACE" >/dev/null 2>&1; then
      echo "    sing-box didn't start. Last lines of its log:" >&2
      sudo tail -n 15 "$LOG" >&2
      stop_singbox; exit 1
    fi
    dns_on
    [[ $KILL -eq 1 ]] && ks_on
    echo "==> Tunnel is up; testing"
    if curl -s -o /dev/null --max-time 15 -w '' https://www.gstatic.com/generate_204; then
      echo "    OK. Your IP now: $(curl -s --max-time 10 https://ifconfig.me || echo '?')"
    else
      echo "    The tunnel is up but the internet doesn't work through it. Last log lines:"
      sudo tail -n 10 "$LOG" | sed 's/^/      /'
      echo "    ('dial tcp ...: i/o timeout' = the server can't be reached; check the link.)"
      echo "    Disconnect with: $0 down"
    fi
    [[ $KILL -eq 1 ]] && echo "==> Kill switch on: no internet outside the tunnel until '$0 down'"
    ;;

  down)
    echo "==> sudo is needed (enter your Linux password if asked)"
    sudo true
    stop_singbox
    dns_off
    ks_off
    echo "==> Disconnected (direct connection again)"
    ;;

  status)
    if running; then
      echo "Tunnel:      up (sing-box pid $(sudo cat "$PIDF"))"
    else
      echo "Tunnel:      down"
    fi
    echo "DNS:         $(sudo test -e "$RESOLV_BAK" && echo 'through the tunnel' || echo normal)"
    echo "Kill switch: $($IPT -S "$KS" >/dev/null 2>&1 && echo on || echo off)"
    if running; then echo "Your IP:     $(curl -s --max-time 10 https://ifconfig.me || echo '(no answer)')"; fi
    ;;

  log)
    sudo tail -n 50 -f "$LOG"
    ;;

  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $cmd (use install, up, down, status, log or config)" >&2; exit 1 ;;
esac
