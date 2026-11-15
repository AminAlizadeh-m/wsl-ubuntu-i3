#!/usr/bin/env bash
# Copy CA certificates from Windows into Ubuntu, for networks whose proxy or
# firewall re-signs HTTPS with its own CA (apt, curl, git, pip etc. fail with
# "certificate verify failed" until Ubuntu trusts that CA).
#
#   ./import-windows-certs.sh "CA NAME" [MORE NAMES]   clean, then import
#   ./import-windows-certs.sh --no-clean "CA NAME"     import, keep other certs
#   ./import-windows-certs.sh --clean                  only clean
#   ./import-windows-certs.sh --list [TEXT]            list Windows CAs
#   add --yes to skip the questions
#
# NAME is part of the certificate's name as Windows shows it (certmgr.msc,
# "Issued To"); case doesn't matter. Its issuers (the rest of its chain) are
# imported too.
#
# Clean: removes every certificate added by hand to Ubuntu (the files in
# /usr/local/share/ca-certificates; a backup is kept), turns back on any
# built-in certificate that was turned off, and rebuilds Ubuntu's list. The
# built-in certificates themselves are never removed.
#
# Chrome and VS Code don't use Ubuntu's list but their own (~/.pki/nssdb), so
# the certificates go there too.
set -euo pipefail

LOCAL_CA=/usr/local/share/ca-certificates
DEST="$LOCAL_CA/windows"
NSSDB="$HOME/.pki/nssdb"
NICK="windows:"           # NSS nickname prefix of the certificates we add
BACKUP="$HOME/.local/share/wsl-certs-backup"

CLEAN=1; IMPORT=1; LIST=0; YES=0; NAMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)    IMPORT=0 ;;
    --no-clean) CLEAN=0 ;;
    --list)     LIST=1 ;;
    --yes|-y)   YES=1 ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    *)          NAMES+=("$1") ;;
  esac
  shift
done

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user (it uses sudo where needed)." >&2
  exit 1
fi

ask() {
  [[ $YES -eq 1 ]] && return 0
  local reply; read -rp "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]]
}

PS=""
find_powershell() {
  local p
  for p in powershell.exe /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
    if command -v "$p" >/dev/null 2>&1; then PS="$p"; return 0; fi
  done
  echo "Can't find Windows PowerShell (powershell.exe). Is this WSL, with /mnt/c mounted?" >&2
  exit 1
}

# Run a PowerShell script. Text is passed in environment variables (WSLENV
# hands them to Windows), so names with quotes or spaces are safe.
ps_run() {
  "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$1" | tr -d '\r'
}

# Windows certificate stores to search: trusted roots and intermediates,
# for the computer and for the user.
PS_STORES='$stores = "Cert:\LocalMachine\Root","Cert:\LocalMachine\CA","Cert:\CurrentUser\Root","Cert:\CurrentUser\CA"'

if [[ $LIST -eq 1 ]]; then
  find_powershell
  echo "CAs on Windows${NAMES[0]:+ matching \"${NAMES[0]}\"} (name | expires):"
  CERT_FILTER="${NAMES[0]:-}" WSLENV="CERT_FILTER${WSLENV:+:$WSLENV}" ps_run "$PS_STORES"'
    Get-ChildItem $stores | Where-Object { $_.Subject -like ("*" + $env:CERT_FILTER + "*") } |
      Sort-Object Thumbprint -Unique | Sort-Object Subject |
      ForEach-Object { "  " + $_.GetNameInfo("SimpleName", $false) + " | " + $_.NotAfter.ToString("yyyy-MM-dd") }'
  exit 0
fi

if [[ $IMPORT -eq 1 && ${#NAMES[@]} -eq 0 ]]; then
  echo "Give the name of the Windows certificate to import, for example:" >&2
  echo "  $0 \"My Company CA\"" >&2
  echo "List the names with: $0 --list" >&2
  exit 1
fi

command -v update-ca-certificates >/dev/null || {
  echo "update-ca-certificates is missing: sudo apt-get install ca-certificates" >&2; exit 1; }
command -v openssl >/dev/null || {
  echo "openssl is missing: sudo apt-get install openssl" >&2; exit 1; }

# 1. Get the certificates from Windows first, so a typo doesn't leave
#    Ubuntu cleaned but without the certificate.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [[ $IMPORT -eq 1 ]]; then
  find_powershell
  echo "==> Looking for the certificate(s) on Windows"
  # Names joined with a newline; each match is exported with its chain,
  # as "#CERT <thumbprint> <name>" followed by the PEM.
  CERT_NAMES="$(printf '%s\n' "${NAMES[@]}")" \
  WSLENV="CERT_NAMES${WSLENV:+:$WSLENV}" ps_run "$PS_STORES"'
    $all = Get-ChildItem $stores
    $seen = @{}
    foreach ($n in ($env:CERT_NAMES -split "`n" | Where-Object { $_ -ne "" })) {
      $hits = $all | Where-Object { $_.Subject -like ("*" + $n + "*") }
      if (-not $hits) { "#MISSING " + $n; continue }
      foreach ($c in $hits) {
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = "NoCheck"
        [void]$chain.Build($c)
        $certs = @($c) + @($chain.ChainElements | ForEach-Object { $_.Certificate })
        foreach ($x in $certs) {
          if ($seen.ContainsKey($x.Thumbprint)) { continue }
          $seen[$x.Thumbprint] = 1
          "#CERT " + $x.Thumbprint + " " + $x.GetNameInfo("SimpleName", $false)
          "-----BEGIN CERTIFICATE-----"
          [Convert]::ToBase64String($x.RawData, "InsertLineBreaks")
          "-----END CERTIFICATE-----"
        }
      }
    }' > "$TMP/export.txt"

  if grep -q '^#MISSING ' "$TMP/export.txt"; then
    sed -n 's/^#MISSING /    Not found on Windows: /p' "$TMP/export.txt" >&2
    echo "    List the names with: $0 --list" >&2
    exit 1
  fi

  # One file per certificate: <name>-<first 8 of thumbprint>.crt
  mkdir -p "$TMP/certs"
  awk -v dir="$TMP/certs" '
    /^#CERT / { name = substr($0, length($1 " " $2 " ") + 1)
                gsub(/[^A-Za-z0-9._-]+/, "_", name)
                file = dir "/" name "-" substr($2, 1, 8) ".crt"; next }
    file != "" { print > file }
  ' "$TMP/export.txt"

  shopt -s nullglob
  CERTS=("$TMP"/certs/*.crt)
  shopt -u nullglob
  if [[ ${#CERTS[@]} -eq 0 ]]; then
    echo "    PowerShell returned no certificates." >&2
    exit 1
  fi
  for f in "${CERTS[@]}"; do
    if ! openssl x509 -in "$f" -noout 2>/dev/null; then
      echo "    Got a broken certificate from Windows: $(basename "$f")" >&2
      exit 1
    fi
    echo "    $(openssl x509 -in "$f" -noout -subject -nameopt oneline | sed 's/^subject= *//')"
    echo "      expires $(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)"
  done
fi

echo "==> sudo is used to change Ubuntu's certificates (enter your Linux password if asked)"
sudo -v

# 2. Clean
if [[ $CLEAN -eq 1 ]]; then
  mapfile -t old < <(sudo find "$LOCAL_CA" -type f 2>/dev/null | sort)
  disabled="$(grep -c '^!' /etc/ca-certificates.conf 2>/dev/null || true)"
  if [[ ${#old[@]} -gt 0 ]]; then
    echo "==> Certificates added to Ubuntu by hand:"
    printf '    %s\n' "${old[@]#"$LOCAL_CA"/}"
  fi
  [[ "${disabled:-0}" -gt 0 ]] && echo "==> $disabled built-in certificate(s) are turned off"
  if [[ ${#old[@]} -eq 0 && "${disabled:-0}" -eq 0 ]]; then
    echo "==> Nothing to clean: Ubuntu has only its built-in certificates"
  elif ask "Remove these and use only Ubuntu's built-in certificates$( [[ $IMPORT -eq 1 ]] && echo " plus the new ones")?"; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP/$stamp"
    if [[ ${#old[@]} -gt 0 ]]; then
      sudo cp -a "$LOCAL_CA/." "$BACKUP/$stamp/"
      sudo chown -R "$USER:" "$BACKUP/$stamp"
      sudo find "$LOCAL_CA" -mindepth 1 -delete
    fi
    if [[ "${disabled:-0}" -gt 0 ]]; then
      cp /etc/ca-certificates.conf "$BACKUP/$stamp/ca-certificates.conf"
      sudo sed -i 's/^!//' /etc/ca-certificates.conf
    fi
    echo "    Backup: $BACKUP/$stamp"
  else
    echo "    Kept them"
  fi
fi

# 3. Install the Windows certificates
if [[ $IMPORT -eq 1 ]]; then
  echo "==> Adding the certificate(s) to Ubuntu"
  sudo mkdir -p "$DEST"
  sudo install -m 644 "${CERTS[@]}" "$DEST/"
fi

echo "==> Rebuilding Ubuntu's certificate list"
sudo update-ca-certificates --fresh >/dev/null
echo "    $(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt) certificates trusted"

# 4. Chrome / VS Code (NSS database)
if [[ $IMPORT -eq 1 ]] && ! command -v certutil >/dev/null; then
  echo "==> Installing certutil (for Chrome and VS Code)"
  sudo apt-get install -y libnss3-tools >/dev/null 2>&1 ||
    echo "    Couldn't install libnss3-tools; Chrome won't trust the certificate yet. Run this again later."
fi
if command -v certutil >/dev/null && { [[ $IMPORT -eq 1 ]] || [[ -d "$NSSDB" ]]; }; then
  if [[ ! -f "$NSSDB/cert9.db" ]]; then
    mkdir -p "$NSSDB"
    certutil -d "sql:$NSSDB" -N --empty-password
  fi
  if [[ $CLEAN -eq 1 ]]; then
    # Lines look like "[NSS Certificate DB:]windows: NAME   C,,"
    certutil -d "sql:$NSSDB" -L 2>/dev/null |
      sed -n "s/^\(\(NSS Certificate DB:\)\{0,1\}$NICK.*[^ ]\) \{2,\}[^ ]*,[^ ]*,[^ ]* *$/\1/p" |
      while IFS= read -r n; do certutil -d "sql:$NSSDB" -D -n "$n"; done
  fi
  if [[ $IMPORT -eq 1 ]]; then
    for f in "${CERTS[@]}"; do
      n="$NICK $(basename "$f" .crt)"
      certutil -d "sql:$NSSDB" -A -t "C,," -n "$n" -i "$f"
    done
    echo "==> Added to Chrome and VS Code too (restart them if they're open)"
  fi
fi

# 5. Check
if [[ $IMPORT -eq 1 ]] && command -v curl >/dev/null; then
  echo "==> Testing HTTPS"
  if curl -sS --max-time 10 -o /dev/null https://github.com 2>"$TMP/curl.err"; then
    echo "    OK: https://github.com works"
  else
    echo "    https://github.com still fails: $(cat "$TMP/curl.err")"
    echo "    (if it's a certificate error, the proxy may use another CA: see $0 --list)"
  fi
fi

cat <<'EOF'

Done. Tools with their own certificate list need to be pointed at Ubuntu's,
e.g. in ~/.zshrc:
  export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt   # node, npm
  export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt    # python requests, pip
EOF
