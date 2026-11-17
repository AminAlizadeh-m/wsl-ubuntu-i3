<#
Connect to a VLESS server on Windows with sing-box, WITHOUT admin rights.

  vless-proxy.cmd install [-Version 1.14.4]   download sing-box (into your user folder)
  vless-proxy.cmd up "vless://..."            connect (the link is saved)
  vless-proxy.cmd up                          connect with the saved link
  vless-proxy.cmd up C:\path\link.txt         the link from a file
  vless-proxy.cmd down                        disconnect, restore your proxy settings
  vless-proxy.cmd status                      connected? which IP?
  vless-proxy.cmd log                         follow sing-box's log
  vless-proxy.cmd config ["vless://..."]      print the generated sing-box config
  -Port 2080                                  the local proxy port

Without admin rights Windows doesn't allow TUN mode (it needs a network
driver) or a kill switch (it needs firewall rules). So this runs sing-box
as a local proxy (127.0.0.1:2080) and sets it as your Windows proxy (your
own settings, no admin needed). Browsers, most apps and WSL's new sessions
(autoProxy) use it. Programs that ignore the Windows proxy go direct.

Everything lives in %LOCALAPPDATA%\vless-proxy. Uninstall: "down", then
delete that folder.
#>
param(
  [Parameter(Position = 0)] [string] $Command = "help",
  [Parameter(Position = 1)] [string] $Link = "",
  [string] $Version = "",
  [int] $Port = 2080
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Dir     = Join-Path $env:LOCALAPPDATA "vless-proxy"
$BinDir  = Join-Path $Dir "bin"
$Exe     = Join-Path $BinDir "sing-box.exe"
$Conf    = Join-Path $Dir "config.json"
$LinkF   = Join-Path $Dir "link.txt"
$LogF    = Join-Path $Dir "sing-box.log"
$StateF  = Join-Path $Dir "state.json"
$InetKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$Bypass  = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>"

function Say($msg) { Write-Host $msg }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

function Write-Utf8($path, $text) {   # UTF-8 without BOM (sing-box can't read a BOM)
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ link -> config
function Get-TheLink {
  $l = $Link
  if ($l -and -not $l.StartsWith("vless://") -and (Test-Path -LiteralPath $l)) {
    $m = Select-String -LiteralPath $l -Pattern 'vless://\S+' | Select-Object -First 1
    $l = if ($m) { $m.Matches[0].Value } else { "" }
  }
  if (-not $l -and (Test-Path -LiteralPath $LinkF)) { $l = (Get-Content -LiteralPath $LinkF -Raw).Trim() }
  if (-not $l.StartsWith("vless://")) { Fail 'Give a vless:// link in quotes: vless-proxy.cmd up "vless://..."' }
  return $l
}

function Split-Link($l) {
  # vless://UUID@HOST:PORT?QUERY#NAME
  $rest = $l.Substring(8)
  $name = ""
  $i = $rest.IndexOf("#"); if ($i -ge 0) { $name = [uri]::UnescapeDataString($rest.Substring($i + 1)); $rest = $rest.Substring(0, $i) }
  $query = ""
  $i = $rest.IndexOf("?"); if ($i -ge 0) { $query = $rest.Substring($i + 1); $rest = $rest.Substring(0, $i) }
  $rest = $rest.TrimEnd("/")
  $i = $rest.LastIndexOf("@"); if ($i -lt 0) { Fail "Can't use this link: it needs uuid@server:port" }
  $uuid = [uri]::UnescapeDataString($rest.Substring(0, $i))
  $hp = $rest.Substring($i + 1)
  if ($hp -match '^\[(.+)\]:(\d+)$' -or $hp -match '^([^:]+):(\d+)$') { $h = $Matches[1]; $p = [int]$Matches[2] }
  else { Fail "Can't use this link: bad server:port ($hp)" }
  $q = @{}
  foreach ($kv in $query.Split("&")) {
    if (-not $kv) { continue }
    $j = $kv.IndexOf("=")
    if ($j -lt 0) { $q[$kv] = "" } else { $q[$kv.Substring(0, $j)] = [uri]::UnescapeDataString($kv.Substring($j + 1).Replace("+", " ")) }
  }
  return @{ uuid = $uuid; host = $h; port = $p; q = $q; name = $name }
}

function QV($q, $key, $default = "") { if ($q.ContainsKey($key) -and $q[$key] -ne "") { return $q[$key] } else { return $default } }

function New-Config($l, $serverIp) {
  $P = Split-Link $l
  $q = $P.q
  if (-not $P.uuid) { Fail "Can't use this link: no uuid" }
  $enc = QV $q "encryption" "none"
  if ($enc -ne "none") { Fail "Can't use this link: encryption=$enc isn't supported by sing-box" }

  $out = [ordered]@{ type = "vless"; tag = "proxy"; server = $(if ($serverIp) { $serverIp } else { $P.host })
                     server_port = $P.port; uuid = $P.uuid; packet_encoding = "xudp" }
  $flow = QV $q "flow"; if ($flow) { $out.flow = $flow }

  $net = (QV $q "type" "tcp").ToLower()
  $path = QV $q "path"; $thost = QV $q "host"
  switch ($net) {
    { $_ -in "tcp", "raw" } {
      $ht = QV $q "headerType" "none"
      if ($ht -ne "none") { Fail "Can't use this link: tcp with headerType=$ht isn't supported" }
    }
    "ws" {
      $t = [ordered]@{ type = "ws"; path = $(if ($path) { $path } else { "/" }) }
      if ($t.path -match '^(.*)\?ed=(\d+)$') {
        $t.path = $(if ($Matches[1]) { $Matches[1] } else { "/" })
        $t.max_early_data = [int]$Matches[2]
        $t.early_data_header_name = "Sec-WebSocket-Protocol"
      }
      if ($thost) { $t.headers = @{ Host = $thost } }
      $out.transport = $t
    }
    "grpc" { $out.transport = [ordered]@{ type = "grpc"; service_name = (QV $q "serviceName") } }
    { $_ -in "http", "h2" } {
      $t = [ordered]@{ type = "http"; path = $(if ($path) { $path } else { "/" }) }
      if ($thost) { $t.host = @($thost.Split(",")) }
      $out.transport = $t
    }
    "httpupgrade" {
      $t = [ordered]@{ type = "httpupgrade"; path = $(if ($path) { $path } else { "/" }) }
      if ($thost) { $t.host = $thost }
      $out.transport = $t
    }
    default { Fail "Can't use this link: transport type=$net isn't supported by sing-box" }
  }

  $sec = (QV $q "security" "none").ToLower()
  $isIp = ($P.host -match '^[\d.]+$') -or ($P.host -like "*:*")
  if ($sec -in "tls", "reality") {
    $tls = [ordered]@{ enabled = $true }
    $sni = QV $q "sni" (QV $q "serverName")
    if (-not $sni -and $thost -and $net -ne "grpc") { $sni = $thost }
    if (-not $sni -and -not $isIp) { $sni = $P.host }
    if ($sni) { $tls.server_name = $sni }
    if ((QV $q "allowInsecure" (QV $q "insecure" "0")) -in "1", "true") { $tls.insecure = $true }
    $alpn = QV $q "alpn"; if ($alpn) { $tls.alpn = @($alpn.Split(",") | Where-Object { $_ }) }
    $fp = QV $q "fp"
    if ($sec -eq "reality") {
      $pbk = QV $q "pbk"; if (-not $pbk) { Fail "Can't use this link: reality needs pbk (public key)" }
      $tls.reality = [ordered]@{ enabled = $true; public_key = $pbk; short_id = (QV $q "sid") }
      if (-not $fp) { $fp = "chrome" }
    }
    if ($fp) { $tls.utls = [ordered]@{ enabled = $true; fingerprint = $fp } }
    $out.tls = $tls
  } elseif ($sec -ne "none") { Fail "Can't use this link: security=$sec isn't supported" }

  $config = [ordered]@{
    log = [ordered]@{ level = "info"; timestamp = $true }
    dns = [ordered]@{
      servers = @([ordered]@{ type = "https"; tag = "remote"; server = "1.1.1.1"; detour = "proxy" })
      final = "remote"; strategy = "ipv4_only"
    }
    inbounds = @([ordered]@{ type = "mixed"; tag = "mixed-in"; listen = "127.0.0.1"; listen_port = $Port })
    outbounds = @($out, [ordered]@{ type = "direct"; tag = "direct" })
    route = [ordered]@{
      rules = @(
        [ordered]@{ action = "sniff" },
        [ordered]@{ protocol = "dns"; action = "hijack-dns" },
        [ordered]@{ ip_is_private = $true; outbound = "direct" }
      )
      final = "proxy"
    }
  }
  return ($config | ConvertTo-Json -Depth 10)
}

function Get-ServerIp($l) {
  $h = (Split-Link $l).host
  if ($h -match '^[\d.]+$' -or $h -like "*:*") { return $h }
  try {
    $a = [Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1
    if ($a) { return $a.IPAddressToString }
  } catch {}
  return ""
}

# ------------------------------------------------------------------ Windows proxy
function Update-ProxyNow {   # tell running apps the proxy changed
  try {
    if (-not ("VlessProxy.WinInet" -as [type])) {
      Add-Type -Namespace VlessProxy -Name WinInet -MemberDefinition '[DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
    }
    [void][VlessProxy.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][VlessProxy.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
  } catch { }   # without it, apps notice when restarted
}

function Get-ProxySettings {
  $p = Get-ItemProperty -Path $InetKey
  return [ordered]@{
    ProxyEnable   = $(if ($null -ne $p.ProxyEnable) { [int]$p.ProxyEnable } else { 0 })
    ProxyServer   = $p.ProxyServer
    ProxyOverride = $p.ProxyOverride
    AutoConfigURL = $p.AutoConfigURL
  }
}

function Set-OrClear($name, $value, $type) {
  if ($null -eq $value -or $value -eq "") { Remove-ItemProperty -Path $InetKey -Name $name -ErrorAction SilentlyContinue }
  else { Set-ItemProperty -Path $InetKey -Name $name -Value $value -Type $type }
}

function Set-Proxy {
  Set-ItemProperty -Path $InetKey -Name ProxyEnable -Value 1 -Type DWord
  Set-ItemProperty -Path $InetKey -Name ProxyServer -Value "127.0.0.1:$Port" -Type String
  Set-ItemProperty -Path $InetKey -Name ProxyOverride -Value $Bypass -Type String
  Remove-ItemProperty -Path $InetKey -Name AutoConfigURL -ErrorAction SilentlyContinue
  Update-ProxyNow
}

function Restore-Proxy($old) {
  Set-ItemProperty -Path $InetKey -Name ProxyEnable -Value ([int]$old.ProxyEnable) -Type DWord
  Set-OrClear ProxyServer $old.ProxyServer String
  Set-OrClear ProxyOverride $old.ProxyOverride String
  Set-OrClear AutoConfigURL $old.AutoConfigURL String
  Update-ProxyNow
}

# ------------------------------------------------------------------ state
function Read-State { if (Test-Path $StateF) { return (Get-Content $StateF -Raw | ConvertFrom-Json) } else { return $null } }

function Get-Running($state) {
  if (-not $state -or -not $state.pid) { return $null }
  $p = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -eq "sing-box") { return $p } else { return $null }
}

function Stop-Tunnel {
  $state = Read-State
  if (-not $state) { return $false }
  $p = Get-Running $state
  if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  if ($state.oldProxy) { Restore-Proxy $state.oldProxy }
  Remove-Item $StateF -Force -ErrorAction SilentlyContinue
  return $true
}

function Test-Proxy {
  try {
    $r = Invoke-WebRequest -Uri "https://www.gstatic.com/generate_204" -Proxy "http://127.0.0.1:$Port" -UseBasicParsing -TimeoutSec 15
    return ($r.StatusCode -eq 204)
  } catch { return $false }
}

function Get-MyIp {
  try { return (Invoke-WebRequest -Uri "https://ifconfig.me/ip" -Proxy "http://127.0.0.1:$Port" -UseBasicParsing -TimeoutSec 10).Content.Trim() }
  catch { return "?" }
}

# ------------------------------------------------------------------ install
function Install-SingBox {
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } elseif ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
  $api = if ($Version) { "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$($Version.TrimStart('v'))" }
         else { "https://api.github.com/repos/SagerNet/sing-box/releases/latest" }
  Say "==> Looking up sing-box $(if ($Version) { $Version } else { '(latest)' })"
  try { $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 60 }
  catch { Fail "Can't reach GitHub (or no such version). Download sing-box-<version>-windows-$arch.zip from https://github.com/SagerNet/sing-box/releases and put sing-box.exe in $BinDir" }
  $ver = $rel.tag_name.TrimStart("v")
  $asset = $rel.assets | Where-Object { $_.name -eq "sing-box-$ver-windows-$arch.zip" } | Select-Object -First 1
  if (-not $asset) { Fail "No sing-box-$ver-windows-$arch.zip in that release." }
  if (Test-Path $Exe) {
    $cur = (& $Exe version 2>$null | Select-Object -First 1)
    if ($cur -match [regex]::Escape($ver)) { Say "==> sing-box $ver is already installed"; return }
  }
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  # Downloads go next to sing-box, not to %TEMP%: with a dot in the user
  # name (a.b), %TEMP% is a short 8.3 path that Remove-Item can't handle.
  $dl = Join-Path $Dir "download"
  New-Item -ItemType Directory -Force -Path $dl | Out-Null
  $zip = Join-Path $dl $asset.name
  Say "==> Downloading sing-box $ver"
  $old = $ProgressPreference; $ProgressPreference = "SilentlyContinue"   # much faster
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
  $ProgressPreference = $old
  if ($asset.digest -and $asset.digest.StartsWith("sha256:")) {
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower()
    if ($got -ne $asset.digest.Substring(7).ToLower()) { Remove-Item -LiteralPath $zip -Force; Fail "The download is damaged (checksum mismatch)." }
    Say "    Checksum OK"
  }
  $tmp = Join-Path $dl "extract"
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  $found = Get-ChildItem -Path $tmp -Recurse -Filter "sing-box.exe" | Select-Object -First 1
  if (-not $found) { Fail "sing-box.exe isn't in the download." }
  if (Get-Running (Read-State)) { Fail "Disconnect first (vless-proxy.cmd down), then install." }
  Copy-Item $found.FullName $Exe -Force
  Get-ChildItem -Path $found.DirectoryName -Filter "*.dll" | Copy-Item -Destination $BinDir -Force
  Remove-Item -LiteralPath $dl -Recurse -Force -ErrorAction SilentlyContinue
  Say "==> sing-box $ver installed in $BinDir"
}

# ------------------------------------------------------------------ commands
switch ($Command.ToLower()) {
  "install" { Install-SingBox }

  "config" {
    $l = Get-TheLink
    New-Config $l (Get-ServerIp $l)
  }

  "up" {
    $l = Get-TheLink
    if (-not (Test-Path $Exe)) { Install-SingBox }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    [void](Stop-Tunnel)   # a previous connection
    $ip = Get-ServerIp $l
    if (-not $ip) { Fail "Can't look up the server's address. Is the internet working?" }
    Write-Utf8 $LinkF $l
    $name = (Split-Link $l).name; if (-not $name) { $name = "server" }
    Say "==> Connecting to $name ($ip)"
    Write-Utf8 $Conf (New-Config $l $ip)
    $check = & $Exe check -c $Conf 2>&1
    if ($LASTEXITCODE -ne 0) { $check | ForEach-Object { Say "    $_" }; Fail "sing-box rejected the config (see above)." }

    $busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($busy) { Fail "Port $Port is already in use (another proxy app?). Close it, or use -Port N." }

    $p = Start-Process -FilePath $Exe -ArgumentList @("run", "-c", "`"$Conf`"") -WorkingDirectory $Dir `
           -WindowStyle Hidden -RedirectStandardError $LogF -RedirectStandardOutput "$LogF.out" -PassThru
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      if ($p.HasExited) { break }
      if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { $ok = $true; break }
    }
    if (-not $ok) {
      Say "    sing-box didn't start. Last lines of its log:"
      Get-Content $LogF -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Say "      $_" }
      if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
      exit 1
    }
    $state = [ordered]@{ pid = $p.Id; port = $Port; oldProxy = (Get-ProxySettings) }
    Write-Utf8 $StateF ($state | ConvertTo-Json -Depth 5)
    Set-Proxy
    Say "==> Windows proxy set to 127.0.0.1:$Port; testing"
    if (Test-Proxy) {
      Say "    OK. Your IP now: $(Get-MyIp)"
    } else {
      Say "    The proxy runs but doesn't reach the internet. Last log lines:"
      Get-Content $LogF -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Say "      $_" }
      Say "    ('dial tcp ...: i/o timeout' = the server can't be reached; check the link.)"
      Say "    Disconnect with: vless-proxy.cmd down"
    }
    Say "Apps that were already open may need a restart to use the proxy."
  }

  "down" {
    if (Stop-Tunnel) { Say "==> Disconnected; your previous proxy settings are back" }
    else { Say "==> Not connected" }
  }

  "status" {
    $state = Read-State
    $p = Get-Running $state
    if ($p) {
      Say "Connected:     yes (sing-box pid $($p.Id), proxy 127.0.0.1:$($state.port))"
      $s = Get-ProxySettings
      Say "Windows proxy: $(if ($s.ProxyEnable -eq 1 -and $s.ProxyServer -eq "127.0.0.1:$($state.port)") { 'set' } else { 'NOT set (changed by someone else?)' })"
      $Port = [int]$state.port
      Say "Your IP:       $(Get-MyIp)"
    } elseif ($state) {
      Say "Connected:     no, sing-box stopped. Run 'vless-proxy.cmd down' to restore your proxy settings."
    } else {
      Say "Connected:     no"
    }
  }

  "log" { Get-Content $LogF -Tail 50 -Wait }

  default {   # the help text at the top of this file
    $lines = Get-Content -LiteralPath $PSCommandPath
    $end = [array]::IndexOf($lines, "#>")
    $lines[1..($end - 1)] | ForEach-Object { Say $_ }
  }
}
