#!/usr/bin/env bash
# Connect Throne and send all of Ubuntu's internet traffic through it,
# without Throne's TUN mode, with a kill switch.
#
#   ./throne-proxy.sh on                 start Throne, connect, route everything
#   ./throne-proxy.sh on --no-kill-switch   ... but allow direct traffic when
#                                        the proxy is down
#   ./throne-proxy.sh on --env-only      only programs that use proxy settings
#   ./throne-proxy.sh off [--quit]       direct connection again (--quit also
#                                        closes Throne)
#   ./throne-proxy.sh status             what's on, and whether it works
#   --port N                             Throne's proxy port (default 2080,
#                                        Settings > Inbound)
#
# Connecting: "on" starts Throne (in the tray) if it isn't running and waits
# until it has connected. Throne connects by itself when "Remember last
# proxy" is on in its menu: connect your profile once in Throne with that on.
#
# Routing:
#  - Proxy settings (http_proxy, https_proxy, all_proxy) for new terminals and
#    the apps started from them (i3, Chrome, VS Code). The proxy looks names
#    up, so blocked sites get their real address.
#  - All other TCP traffic, of every program and user, is redirected to
#    Throne (iptables + redsocks), and DNS goes to Throne's DNS server.
#  - Kill switch: nothing else may leave this machine except Throne's own
#    connections, so when Throne or your server is down, there's no internet
#    (rather than a direct, unprotected one). Your LAN and Windows stay
#    reachable. Sites that Throne's own routing sends "direct" still work.
#
# Throne's core is told apart by a group (throne-proxy) set on
# /opt/Throne/ThroneCore; "on" sets it up (again after a Throne update).
# After restarting WSL, run "on" again.
set -euo pipefail

PORT=2080
REDIR_PORT=12346          # redsocks listens here
GROUP=throne-proxy        # the group Throne's core runs with
CORE=/opt/Throne/ThroneCore
THRONE=/opt/Throne/Throne
ENV_FILE="$HOME/.config/throne-proxy.env"
APT_CONF=/etc/apt/apt.conf.d/95throne-proxy
RS_DIR=/etc/throne-proxy
RS_CONF="$RS_DIR/redsocks.conf"
RS_PID=/run/throne-proxy-redsocks.pid
NAT=THRONE_PROXY          # nat chain: redirect
KS=THRONE_KILLSWITCH      # filter chain: kill switch (and QUIC block)
# Never through the proxy: this machine, LAN, WSL, Windows, multicast
LOCAL_NETS=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
            172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4)
LOCAL_NETS6=(::1/128 fe80::/10 fc00::/7 ff00::/8)
NO_PROXY_LIST="localhost,127.0.0.1,::1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

usage() { sed -n "2,$(( $(grep -n '^set -euo' "$0" | cut -d: -f1) - 1 ))p" "$0" | sed 's/^# \{0,1\}//'; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

cmd="${1:-}"; shift || true
ENV_ONLY=0; FORCE=0; KILL=1; QUIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)           PORT="${2:?--port needs a number}"; shift ;;
    --env-only)       ENV_ONLY=1; KILL=0 ;;
    --no-kill-switch) KILL=0 ;;
    --force)          FORCE=1 ;;
    --quit)           QUIT=1 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "Bad port: $PORT" >&2; exit 1; }

IPT="sudo iptables -w"
IPT6="sudo ip6tables -w"
have_ip6() { command -v ip6tables >/dev/null || [[ -x /usr/sbin/ip6tables ]]; }
listening() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

proxy_works() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
          -x "socks5h://127.0.0.1:$PORT" https://www.gstatic.com/generate_204 2>/dev/null || true)"
  [[ "$code" == 204 ]]
}

# ------------------------------------------------------------ Throne itself
# Give the core the throne-proxy group (setgid), so its traffic can be told
# apart from everything else. Prints "changed" if it had to change it.
core_group() {
  [[ -f "$CORE" ]] || { echo "Throne isn't installed: ./install-throne.sh" >&2; exit 1; }
  getent group "$GROUP" >/dev/null || sudo groupadd --system "$GROUP"
  if [[ "$(stat -c %G "$CORE")" != "$GROUP" || ! -g "$CORE" ]]; then
    local suid=0
    [[ -u "$CORE" ]] && suid=1          # keep TUN permission (install-throne.sh --tun)
    sudo chgrp "$GROUP" "$CORE"         # (this clears the setuid/setgid bits)
    sudo chmod g+s "$CORE"
    [[ $suid -eq 1 ]] && sudo chmod u+s "$CORE"
    echo changed
  fi
}

core_running_ok() {  # ThroneCore runs, with the group
  local gid egid
  gid="$(getent group "$GROUP" | cut -d: -f3)"
  egid="$(ps -o egid= -C ThroneCore 2>/dev/null | head -1 | tr -d ' ')"
  [[ -n "$egid" && "$egid" == "$gid" ]]
}

quit_throne() {
  pkill -x -u "$(id -u)" Throne 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -x -u "$(id -u)" Throne >/dev/null || break; sleep 1; done
  sudo pkill -x ThroneCore 2>/dev/null || true
}

start_throne() {
  if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    echo "    Throne needs a screen: run this from a terminal in i3 (or WSL with WSLg)." >&2
    exit 1
  fi
  echo "==> Starting Throne (in the tray)"
  (cd "$HOME" && PATH="/opt/Throne:$PATH" setsid "$THRONE" -appdata -tray \
     >/dev/null 2>&1 </dev/null &)
}

connect() {
  if pgrep -x -u 0 Throne >/dev/null; then
    echo "    Throne is also running as root (Alt+Shift+d). Close that one: it uses" >&2
    echo "    the same port. This script uses your own Throne (Alt+d)." >&2
    exit 1
  fi
  local changed
  changed="$(core_group)"
  if pgrep -x -u "$(id -u)" Throne >/dev/null; then
    if [[ -n "$changed" ]] || { pgrep -x ThroneCore >/dev/null && ! core_running_ok; }; then
      echo "==> Restarting Throne (its core needs the $GROUP group)"
      quit_throne
      start_throne
    fi
  else
    start_throne
  fi
  echo "==> Waiting for Throne to connect"
  for _ in $(seq 1 20); do
    listening "$PORT" && core_running_ok && return 0
    sleep 1
  done
  if ! listening "$PORT"; then
    # Not connected by itself: show Throne's window (starting it again only
    # brings the running one to the front) and let you connect there.
    echo "    Throne didn't connect by itself. In the Throne window that opens now:"
    echo "      1. turn on \"Remember last proxy\" (in its menu)"
    echo "      2. start your profile"
    echo "    Waiting up to 3 minutes..."
    (cd "$HOME" && PATH="/opt/Throne:$PATH" setsid "$THRONE" -appdata >/dev/null 2>&1 </dev/null &)
    for _ in $(seq 1 180); do
      listening "$PORT" && core_running_ok && {
        echo "    Connected. Next time: quit Throne with its own Exit (not by closing"
        echo "    the window), so it remembers the profile and connects by itself."
        return 0; }
      sleep 1
    done
    echo "    Still not connected (nothing on port $PORT). If Throne's proxy port" >&2
    echo "    isn't 2080 (Settings > Inbound), pass it with --port." >&2
  else
    echo "    Throne's core doesn't run with the $GROUP group; quit Throne fully and try again." >&2
  fi
  exit 1
}

# ------------------------------------------------------------ proxy settings
env_on() {
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
# Written by throne-proxy.sh. Proxy settings, used only while Throne's proxy
# (port $PORT) is running.
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
    printf '# >>> throne-proxy >>>\n[ -f "%s" ] && . "%s"\n# <<< throne-proxy <<<\n' \
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
  return 0
}

apt_on() {
  printf 'Acquire::http::Proxy "http://127.0.0.1:%s";\nAcquire::https::Proxy "http://127.0.0.1:%s";\n' \
    "$PORT" "$PORT" | sudo tee "$APT_CONF" >/dev/null
  echo "==> apt uses the proxy (while it's set, apt needs Throne running)"
}
apt_off() { sudo rm -f "$APT_CONF"; }

# ------------------------------------------------------------ redirect + kill switch
rules_off() {
  if command -v iptables >/dev/null || [[ -x /usr/sbin/iptables ]]; then
    while $IPT -t nat -D OUTPUT -j "$NAT" 2>/dev/null; do :; done
    $IPT -t nat -F "$NAT" 2>/dev/null || true
    $IPT -t nat -X "$NAT" 2>/dev/null || true
    while $IPT -D OUTPUT -j "$KS" 2>/dev/null; do :; done
    $IPT -F "$KS" 2>/dev/null || true
    $IPT -X "$KS" 2>/dev/null || true
  fi
  if have_ip6; then
    while $IPT6 -D OUTPUT -j "$KS" 2>/dev/null; do :; done
    $IPT6 -F "$KS" 2>/dev/null || true
    $IPT6 -X "$KS" 2>/dev/null || true
  fi
  if sudo test -f "$RS_PID"; then
    sudo kill "$(sudo cat "$RS_PID")" 2>/dev/null || true
    sudo rm -f "$RS_PID"
  fi
  return 0
}

rules_on() {
  local need=() p n dns_port=""
  for p in iptables redsocks; do
    command -v "$p" >/dev/null || [[ -x "/usr/sbin/$p" ]] || need+=("$p")
  done
  if [[ ${#need[@]} -gt 0 ]]; then
    echo "==> Installing ${need[*]}"
    sudo apt-get install -y "${need[@]}" >/dev/null
  fi
  # The package starts its own redsocks with a sample config; we run our own
  [[ -d /run/systemd/system ]] && { sudo systemctl disable --now redsocks >/dev/null 2>&1 || true; }

  # Throne's DNS server (Settings > DNS), if it's on
  dns_port="$(sudo ss -Hlunp 2>/dev/null |
    awk '/ThroneCore/ && $4 ~ /^127\.0\.0\.1:/ {sub(/.*:/, "", $4); print $4; exit}')"

  rules_off
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
  sudo /usr/sbin/redsocks -c "$RS_CONF" -p "$RS_PID"
  for _ in 1 2 3 4 5; do listening "$REDIR_PORT" && break; sleep 0.5; done
  listening "$REDIR_PORT" || { echo "    redsocks didn't start (see: journalctl -t redsocks)" >&2; return 1; }

  # Redirect (nat): everything except Throne's core and redsocks
  $IPT -t nat -N "$NAT"
  $IPT -t nat -A "$NAT" -m owner --gid-owner "$GROUP" -j RETURN
  $IPT -t nat -A "$NAT" -m owner --uid-owner redsocks -j RETURN
  if [[ -n "$dns_port" ]]; then
    $IPT -t nat -A "$NAT" -p udp --dport 53 -j REDIRECT --to-ports "$dns_port"
    $IPT -t nat -A "$NAT" -p tcp --dport 53 -j REDIRECT --to-ports "$dns_port"
  fi
  for n in "${LOCAL_NETS[@]}"; do $IPT -t nat -A "$NAT" -d "$n" -j RETURN; done
  $IPT -t nat -A "$NAT" -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
  $IPT -t nat -A OUTPUT -j "$NAT"

  # Filter: kill switch, or at least block QUIC (it would go around the proxy)
  $IPT -N "$KS"
  $IPT -A "$KS" -o lo -j RETURN
  $IPT -A "$KS" -m owner --gid-owner "$GROUP" -j RETURN
  if [[ $KILL -eq 1 ]]; then
    for n in "${LOCAL_NETS[@]}"; do $IPT -A "$KS" -d "$n" -j RETURN; done
    $IPT -A "$KS" -p tcp -j REJECT --reject-with tcp-reset
    $IPT -A "$KS" -j REJECT
  else
    $IPT -A "$KS" -p udp --dport 443 -j REJECT
  fi
  $IPT -A OUTPUT -j "$KS"
  # IPv6 isn't redirected, so the kill switch blocks it (except local)
  if [[ $KILL -eq 1 ]] && have_ip6; then
    $IPT6 -N "$KS"
    $IPT6 -A "$KS" -o lo -j RETURN
    $IPT6 -A "$KS" -m owner --gid-owner "$GROUP" -j RETURN
    for n in "${LOCAL_NETS6[@]}"; do $IPT6 -A "$KS" -d "$n" -j RETURN; done
    $IPT6 -A "$KS" -j REJECT
    $IPT6 -A OUTPUT -j "$KS"
  fi

  echo "==> All TCP traffic now goes through Throne"
  if [[ -n "$dns_port" ]]; then
    echo "    DNS goes to Throne's DNS server (port $dns_port)"
  else
    echo "    Throne's DNS server is off, so DNS goes direct (blocked sites may get fake"
    echo "    addresses). Turn it on in Throne (Settings > DNS), then run on again."
  fi
  if [[ $KILL -eq 1 ]]; then
    echo "==> Kill switch on: without Throne there's no internet (LAN and Windows still work)"
  fi
}

# ------------------------------------------------------------ commands
case "$cmd" in
  on)
    command -v curl >/dev/null || { echo "curl is needed: sudo apt install curl" >&2; exit 1; }
    [[ -x "$THRONE" && -f "$CORE" ]] || { echo "Throne isn't installed: ./install-throne.sh" >&2; exit 1; }
    echo "==> sudo is needed (enter your Linux password if asked)"
    sudo true
    # Turn off an earlier kill switch first, or Throne couldn't connect
    # before its core has the group
    rules_off
    connect
    echo "==> Testing the connection"
    ok=0
    for _ in 1 2 3; do proxy_works && { ok=1; break; }; sleep 2; done
    if [[ $ok -eq 1 ]]; then
      echo "    OK"
    elif [[ $FORCE -eq 1 ]]; then
      echo "    It doesn't work yet; turning it on anyway (--force)"
    else
      echo "    Throne is connected but can't reach the internet. Check Throne's log:" >&2
      echo "    'dial tcp ...: i/o timeout' means it can't reach your server." >&2
      echo "    Nothing was changed (turn it on anyway with --force)." >&2
      exit 1
    fi
    env_on
    if [[ $ENV_ONLY -eq 1 ]]; then
      apt_on
    else
      apt_off   # the redirect covers apt
      rules_on || { echo "==> Only the proxy settings are on (see above)"; apt_on; }
    fi
    echo
    echo "Open a new terminal (or run: . $ENV_FILE). Apps that are already open,"
    echo "and i3 itself, keep their old settings until restarted."
    echo "Check with: curl https://ifconfig.me   (shows your server's address)"
    ;;

  off)
    echo "==> sudo is needed (enter your Linux password if asked)"
    sudo true
    rules_off
    sudo rm -rf "$RS_DIR"
    apt_off
    env_off
    if [[ $QUIT -eq 1 ]]; then
      quit_throne
      echo "==> Closed Throne"
    fi
    echo "==> Direct connection again. Open a new terminal (or run: unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY)."
    ;;

  status)
    echo "Throne:          $(pgrep -x Throne >/dev/null && echo running || echo 'not running')$(listening "$PORT" && echo ", connected (port $PORT)")"
    echo "Proxy settings:  $([[ -f "$ENV_FILE" ]] && echo on || echo off)$([[ -n "${http_proxy:-}" ]] && echo " (active in this terminal)")"
    echo "apt via proxy:   $([[ -f "$APT_CONF" ]] && echo on || echo off)"
    if sudo -n true 2>/dev/null; then
      echo "Redirect:        $($IPT -t nat -S "$NAT" >/dev/null 2>&1 && echo 'on (all TCP)' || echo off)"
      echo "Kill switch:     $($IPT -S "$KS" 2>/dev/null | grep -q 'tcp-reset' && echo on || echo off)"
    else
      echo "Redirect/kill switch: run 'sudo true' first to see these"
    fi
    if listening "$PORT"; then
      printf 'Proxy works:     '; proxy_works && echo yes || echo "no (see Throne's log)"
    fi
    ;;

  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $cmd (use on, off or status)" >&2; exit 1 ;;
esac
