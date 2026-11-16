#!/usr/bin/env bash
# Send all of Ubuntu's internet traffic through Throne's proxy, without
# Throne's TUN mode. Start Throne and connect a profile first.
#
#   ./throne-proxy.sh on [--port 2080]   turn it on
#   ./throne-proxy.sh on --env-only      only programs that use proxy settings
#   ./throne-proxy.sh off                back to a direct connection
#   ./throne-proxy.sh status             what's on, and whether it works
#
# "on" does two things:
#  1. Proxy settings (http_proxy, https_proxy, all_proxy) for your shells and
#     the apps you start from them, including i3, Chrome and VS Code. Names
#     are looked up by the proxy, so blocked sites get their real address.
#  2. Everything else: all TCP connections of every program and user (apt,
#     programs that ignore proxy settings) are redirected to Throne with
#     iptables and redsocks, and DNS goes to Throne's DNS server. Not
#     covered: programs running as the same user as Throne's core (root,
#     after install-throne.sh --tun), e.g. "sudo curl".
#     UDP to port 443 (QUIC) is blocked so browsers use TCP; other UDP and
#     IPv6 aren't covered.
#
# After restarting WSL, run "on" again (the redirect doesn't survive it; the
# proxy settings only apply while Throne is listening).
set -euo pipefail

PORT=2080                 # Throne: Settings > Inbound (mixed port)
REDIR_PORT=12346          # redsocks listens here
ENV_FILE="$HOME/.config/throne-proxy.env"
APT_CONF=/etc/apt/apt.conf.d/95throne-proxy
RS_DIR=/etc/throne-proxy
RS_CONF="$RS_DIR/redsocks.conf"
RS_PID=/run/throne-proxy-redsocks.pid
CHAIN=THRONE_PROXY
# Addresses that never go through the proxy (this machine, LAN, WSL, Windows)
LOCAL_NETS=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
            172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4)
NO_PROXY_LIST="localhost,127.0.0.1,::1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

cmd="${1:-}"; shift || true
ENV_ONLY=0; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)     PORT="${2:?--port needs a number}"; shift ;;
    --env-only) ENV_ONLY=1 ;;
    --force)    FORCE=1 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Bad port: $PORT" >&2; exit 1; }

listening() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

proxy_works() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
          -x "socks5h://127.0.0.1:$PORT" https://www.gstatic.com/generate_204 2>/dev/null || true)"
  [[ "$code" == 204 ]]
}

# ---------------------------------------------------------------- pieces
env_on() {
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
# Written by throne-proxy.sh. Proxy settings, used only while Throne's proxy
# (port $PORT) is running, so nothing breaks when Throne is closed.
if command -v ss >/dev/null 2>&1 && ss -Hltn 'sport = :$PORT' 2>/dev/null | grep -q .; then
  export http_proxy=http://127.0.0.1:$PORT https_proxy=http://127.0.0.1:$PORT
  export all_proxy=socks5h://127.0.0.1:$PORT no_proxy="$NO_PROXY_LIST"
  export HTTP_PROXY=\$http_proxy HTTPS_PROXY=\$https_proxy ALL_PROXY=\$all_proxy NO_PROXY=\$no_proxy
fi
EOF
  local rc
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc" ]] || continue
    grep -q '^# >>> throne-proxy >>>' "$rc" && continue
    printf '\n# >>> throne-proxy >>>\n[ -f "%s" ] && . "%s"\n# <<< throne-proxy <<<\n' \
      "$ENV_FILE" "$ENV_FILE" >> "$rc"
  done
  echo "==> Proxy settings added for new terminals (and apps started from them)"
}

env_off() {
  rm -f "$ENV_FILE"
  local rc
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [[ -f "$rc" ]] && sed -i '/^# >>> throne-proxy >>>/,/^# <<< throne-proxy <<</d' "$rc"
  done
}

# The redirect: iptables sends TCP to redsocks, which hands it to Throne.
# Throne's own core must be left out, or its connection to your server would
# loop back into Throne. So it only works when the core runs as another user
# than you (root, after ./install-throne.sh --tun).
redirect_on() {
  local core_uid me dns_port="" need=() p n
  me="$(id -u)"
  core_uid="$(ps -o euid= -C ThroneCore 2>/dev/null | head -1 | tr -d ' ')"
  if [[ -z "$core_uid" ]]; then
    echo "    ThroneCore isn't running; start Throne and connect a profile." >&2; return 1
  fi
  if [[ "$core_uid" == "$me" ]]; then
    echo "    ThroneCore runs as you, so its own traffic can't be told apart from yours." >&2
    echo "    Run ./install-throne.sh --tun once (the core then runs as root), restart" >&2
    echo "    Throne, and try again. Or use: $0 on --env-only" >&2
    return 1
  fi

  for p in iptables redsocks; do
    command -v "$p" >/dev/null || command -v "/usr/sbin/$p" >/dev/null || need+=("$p")
  done
  if [[ ${#need[@]} -gt 0 ]]; then
    echo "==> Installing ${need[*]}"
    sudo apt-get install -y "${need[@]}" >/dev/null
  fi
  # The package starts its own redsocks with a sample config; we run our own
  if [[ -d /run/systemd/system ]]; then
    sudo systemctl disable --now redsocks >/dev/null 2>&1 || true
  fi

  # Throne's DNS server (Settings > DNS, "hijack DNS"), if it's on
  dns_port="$(sudo ss -Hlunp 2>/dev/null | awk '/ThroneCore/ && $4 ~ /^127\.0\.0\.1:/ {sub(/.*:/, "", $4); print $4; exit}')"

  sudo mkdir -p "$RS_DIR"
  sudo tee "$RS_CONF" >/dev/null <<EOF
// Written by throne-proxy.sh
base {
  log_debug = off;
  log_info = off;
  log = "syslog:daemon";
  daemon = on;
  user = redsocks;
  group = redsocks;
  redirector = iptables;
}
redsocks {
  local_ip = 127.0.0.1;
  local_port = $REDIR_PORT;
  ip = 127.0.0.1;
  port = $PORT;
  type = socks5;
}
EOF
  redirect_off quiet
  sudo /usr/sbin/redsocks -c "$RS_CONF" -p "$RS_PID"
  sleep 0.5
  listening "$REDIR_PORT" || { echo "    redsocks didn't start (see: journalctl -t redsocks)" >&2; return 1; }

  local ipt="sudo iptables -w"
  $ipt -t nat -N "$CHAIN"
  $ipt -t nat -A "$CHAIN" -m owner --uid-owner "$core_uid" -j RETURN
  $ipt -t nat -A "$CHAIN" -m owner --uid-owner redsocks -j RETURN
  if [[ -n "$dns_port" ]]; then
    $ipt -t nat -A "$CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$dns_port"
    $ipt -t nat -A "$CHAIN" -p tcp --dport 53 -j REDIRECT --to-ports "$dns_port"
  fi
  for n in "${LOCAL_NETS[@]}"; do $ipt -t nat -A "$CHAIN" -d "$n" -j RETURN; done
  $ipt -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
  $ipt -t nat -A OUTPUT -j "$CHAIN"
  # QUIC would go around the proxy; blocking it makes browsers use TCP
  $ipt -N "$CHAIN"
  $ipt -A "$CHAIN" -m owner --uid-owner "$core_uid" -j RETURN
  $ipt -A "$CHAIN" -p udp --dport 443 -j REJECT
  $ipt -A OUTPUT -j "$CHAIN"

  echo "==> All TCP traffic now goes through Throne"
  if [[ -n "$dns_port" ]]; then
    echo "    DNS goes to Throne's DNS server (port $dns_port)"
  else
    echo "    Throne's DNS server is off, so DNS still goes direct: blocked sites may"
    echo "    get fake addresses. Turn on Throne's DNS server (hijack DNS), then run on again."
  fi
}

redirect_off() {
  local ipt="sudo iptables -w"
  if command -v iptables >/dev/null || [[ -x /usr/sbin/iptables ]]; then
    while $ipt -t nat -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
    $ipt -t nat -F "$CHAIN" 2>/dev/null || true
    $ipt -t nat -X "$CHAIN" 2>/dev/null || true
    while $ipt -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
    $ipt -F "$CHAIN" 2>/dev/null || true
    $ipt -X "$CHAIN" 2>/dev/null || true
  fi
  if sudo test -f "$RS_PID"; then
    sudo kill "$(sudo cat "$RS_PID")" 2>/dev/null || true
    sudo rm -f "$RS_PID"
  fi
  [[ "${1:-}" == quiet ]] || sudo rm -rf "$RS_DIR"
}

apt_on() {
  printf 'Acquire::http::Proxy "http://127.0.0.1:%s";\nAcquire::https::Proxy "http://127.0.0.1:%s";\n' \
    "$PORT" "$PORT" | sudo tee "$APT_CONF" >/dev/null
  echo "==> apt uses the proxy (while it's set, apt needs Throne running)"
}
apt_off() { sudo rm -f "$APT_CONF"; }

# ---------------------------------------------------------------- commands
case "$cmd" in
  on)
    command -v curl >/dev/null || { echo "curl is needed: sudo apt install curl" >&2; exit 1; }
    if ! listening "$PORT"; then
      echo "Nothing is listening on port $PORT. Start Throne and connect a profile" >&2
      echo "(the port is in Throne's Settings > Inbound; pass it with --port)." >&2
      exit 1
    fi
    echo "==> Testing Throne's proxy on port $PORT"
    if proxy_works; then
      echo "    OK"
    elif [[ $FORCE -eq 1 ]]; then
      echo "    It doesn't work yet; turning it on anyway (--force)"
    else
      echo "    The proxy doesn't reach the internet. Check Throne's log: if it says" >&2
      echo "    'dial tcp ...: i/o timeout', Throne can't reach your server." >&2
      echo "    Fix that first (or turn it on anyway with --force)." >&2
      exit 1
    fi
    echo "==> sudo is needed (enter your Linux password if asked)"
    sudo true
    env_on
    if [[ $ENV_ONLY -eq 1 ]]; then
      apt_on
    else
      apt_off   # the redirect covers apt
      redirect_on || { echo "==> Only the proxy settings are on (see above)"; apt_on; }
    fi
    echo
    echo "Open a new terminal (or run: . $ENV_FILE). Apps that are already open,"
    echo "and i3 itself, keep their old settings until restarted."
    echo "Check with: curl https://ifconfig.me   (shows your server's address)"
    ;;

  off)
    echo "==> sudo is needed (enter your Linux password if asked)"
    sudo true
    redirect_off
    apt_off
    env_off
    echo "==> Direct connection again. Open a new terminal (or run: unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY)."
    ;;

  status)
    echo "Throne proxy on port $PORT: $(listening "$PORT" && echo listening || echo 'not running')"
    echo "Proxy settings:  $([[ -f "$ENV_FILE" ]] && echo on || echo off)$([[ -n "${http_proxy:-}" ]] && echo " (active in this terminal)")"
    echo "apt via proxy:   $([[ -f "$APT_CONF" ]] && echo on || echo off)"
    if sudo -n iptables -w -t nat -S "$CHAIN" >/dev/null 2>&1; then
      echo "Redirect:        on (all TCP)"
    elif sudo -n true 2>/dev/null; then
      echo "Redirect:        off"
    else
      echo "Redirect:        (run 'sudo true' first to check)"
    fi
    if listening "$PORT"; then
      printf 'Proxy works:     '; proxy_works && echo yes || echo "no (see Throne's log)"
    fi
    ;;

  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $cmd (use on, off or status)" >&2; exit 1 ;;
esac
