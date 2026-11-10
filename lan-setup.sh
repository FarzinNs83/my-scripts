#!/usr/bin/env bash
# =============================================================================
#  lan-setup.sh -- your own "Radmin VPN" on a VPS: a virtual LAN for games
#
#  Players connect to this server with the SoftEther VPN Client and land on
#  one Ethernet segment (10.77.77.0/24, addresses from DHCP). One player
#  hosts the game as a LAN game; the others see it in the game's LAN list
#  (broadcasts pass) or join its 10.77.77.x address. Game traffic goes
#  player -> this VPS -> player, so a VPS near the players means low ping.
#
#  Asks for the VPN port, the download page port and the players' names.
#  Everything else is done here:
#    1. SoftEther VPN Server from apt (softether-vpnserver)
#    2. one listener on your port; the default ones (TCP and UDP 443, 992,
#       1194, 5555), SSTP, OpenVPN and VPN Azure are turned off
#    3. a hub "LAN" with one user per player, and DHCP without a gateway:
#       only LAN traffic goes through, not the internet
#    4. a download page (a secret link): the Windows client installer, one
#       ready connection file per player (<name>.vpn, double-click to add)
#       and fix-lan.bat (the game's LAN list and the firewall, run once)
#    5. lanctl: lanctl start/stop/restart/status/who/link
#
#  Other game servers on the same VPS: the ports must be free and apt does
#  not restart running services. Run it again to add or remove players or
#  to change the ports.
#
#  Usage:
#    bash lan-setup.sh
#    bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/lan-setup.sh)
# =============================================================================
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
# list only: restarting services after apt would kick players off other game servers
export NEEDRESTART_MODE=l

UNIT=softether-vpnserver
WEB_UNIT=lan-files
HUB=LAN
SUBNET=10.77.77
CTL=/usr/local/bin/lanctl
CONF_FILE=/etc/lan-setup.conf
PASS_FILE=/etc/lan-setup.players
WWW=/var/lib/lan-setup/www
CLIENT_EXE=SoftEther-VPN-Client.exe
LOG_FILE=/var/log/lan-setup.log

PORT="" OLD_PORT="" WEB_PORT="" PLAYERS="" OLD_PLAYERS="" ADMIN_PASS="" WEB_TOKEN="" ADMIN_PORT="" LINK=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] Setup failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}
trap '_on_err $LINENO' ERR

case "${1:-}" in
  -h | --help) sed -n '2,30p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
esac

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo -i first)."

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# Questions (the last answers are the defaults)
# ---------------------------------------------------------------------------
# ask <prompt> <default>: one line from the terminal
ask() {
  local v
  read -rp "$1${2:+ [$2]}: " v < /dev/tty || die "Cancelled."
  printf '%s' "${v:-$2}"
}

random_pass() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# port_users <port>: what listens on it (TCP or UDP), leaving out this setup's own units
port_users() {
  local line pid
  ss -Hlntup "sport = :$1" 2> /dev/null | while read -r line; do
    pid=$(grep -o 'pid=[0-9]*' <<< "$line" | head -n 1 | cut -d= -f2) || true
    [[ -n $pid ]] && grep -qsE "/(${UNIT}|${WEB_UNIT})\.service" "/proc/${pid}/cgroup" && continue
    printf '%s\n' "$line"
  done
}

# ask_port <prompt> <current or empty> <first to offer> <port it must not be>
ask_port() {
  local v=$2
  if [[ -z $v ]]; then
    v=$3
    while [[ -n $(port_users "$v") || $v == "$4" ]]; do v=$((v + 1)); done
  fi
  while :; do
    v=$(ask "$1" "$v")
    if ! [[ $v =~ ^[0-9]+$ ]] || ((v < 1024 || v > 65535)); then
      warn "Enter a port from 1024 to 65535."
    elif [[ $v == "$4" ]]; then
      warn "That is the other port of this setup."
    elif [[ -n $(port_users "$v") ]]; then
      warn "Port ${v} is taken:"
      port_users "$v" >&2
    else
      printf '%s' "$v"
      return 0
    fi
  done
}

ask_all() {
  local -a n
  local bad v
  # shellcheck disable=SC1090
  [[ -f $CONF_FILE ]] && . "$CONF_FILE"
  OLD_PORT=$PORT
  # the first version of this script had one shared user "player"
  OLD_PLAYERS="${PLAYERS:-player}"

  PORT=$(ask_port "VPN port (TCP; players connect to it)" "$PORT" 5555 "")
  WEB_PORT=$(ask_port "Download page port (TCP)" "$WEB_PORT" 8080 "$PORT")

  while :; do
    PLAYERS=$(ask "Player names, separated by spaces (e.g. ali reza sara)" "$PLAYERS")
    read -ra n <<< "$PLAYERS"
    bad=0
    for v in "${n[@]}"; do [[ $v =~ ^[A-Za-z0-9_-]{1,32}$ ]] || bad=1; done
    # SoftEther user names ignore case: ali and Ali would be one user
    [[ $(printf '%s\n' "${n[@]}" | tr 'A-Z' 'a-z' | sort | uniq -d) ]] && bad=1
    ((${#n[@]} && !bad)) && break
    warn "English letters, digits, _ and - only (up to 32 each), no name twice."
  done
  PLAYERS="${n[*]}"

  # printf %q: the values are sourced back on the next run and by lanctl
  {
    printf 'PORT=%q\n' "$PORT"
    printf 'WEB_PORT=%q\n' "$WEB_PORT"
    printf 'PLAYERS=%q\n' "$PLAYERS"
    # SoftEther's admin password: the admin port is the VPN port, so it must not stay empty
    printf 'ADMIN_PASS=%q\n' "${ADMIN_PASS:-$(random_pass 24)}"
    # the download page's secret path: whoever has the link gets the connection files
    printf 'WEB_TOKEN=%q\n' "${WEB_TOKEN:-$(random_pass 16)}"
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  # shellcheck disable=SC1090
  . "$CONF_FILE"
}

# player_pass <name>: the player's password, made once and kept in PASS_FILE
player_pass() {
  local p
  touch "$PASS_FILE" && chmod 600 "$PASS_FILE"
  p=$(awk -v n="$1" '$1 == n {print $2}' "$PASS_FILE")
  if [[ -z $p ]]; then
    p=$(random_pass 16)
    printf '%s %s\n' "$1" "$p" >> "$PASS_FILE"
  fi
  printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# SoftEther
# ---------------------------------------------------------------------------
ensure_packages() {
  dpkg -s softether-vpnserver > /dev/null 2>&1 && return 0
  say "Installing softether-vpnserver ..."
  # shellcheck disable=SC1091
  if [[ $(. /etc/os-release && printf '%s' "$ID") == ubuntu ]]; then
    command -v add-apt-repository > /dev/null || apt-get install -y -qq software-properties-common
    add-apt-repository -y universe > /dev/null
  fi
  apt-get -o DPkg::Lock::Timeout=180 update -qq
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq softether-vpnserver python3 \
    || die "Could not install softether-vpnserver (Ubuntu 22.04+ / Debian 12+ have it)."
  systemctl cat "$UNIT" > /dev/null 2>&1 || die "The package has no ${UNIT} unit."
}

# TCP ports the SoftEther server listens on
vpn_ports() { ss -Hltnp 2> /dev/null | awk '/"vpnserver"/ {sub(/.*:/, "", $4); print $4}' | sort -un; }

# _vpncmd <args...>: one admin command; the output only when it fails
# (timeout: vpncmd asks again for a wrong password)
_vpncmd() {
  local out
  out=$(timeout 30 vpncmd "localhost:${ADMIN_PORT}" /SERVER "/PASSWORD:${ADMIN_PASS}" "$@" < /dev/null 2>&1) \
    || { tail -n 4 <<< "$out" >&2; return 1; }
}
srv() { _vpncmd /CMD "$@"; }
hub() { _vpncmd "/HUB:${HUB}" /CMD "$@"; }

wait_port() {
  local i
  for i in $(seq 1 30); do
    vpn_ports | grep -qx "$1" && return 0
    sleep 1
  done
  return 1
}

admin_login() {
  local i
  systemctl enable -q --now "$UNIT"
  for i in $(seq 1 30); do
    ADMIN_PORT=$(vpn_ports | head -n 1)
    [[ -n $ADMIN_PORT ]] && break
    sleep 1
  done
  [[ -n $ADMIN_PORT ]] || die "SoftEther does not listen on any TCP port (journalctl -u ${UNIT})."
  vpn_ports | grep -qx "$PORT" && ADMIN_PORT=$PORT

  # a fresh install has no admin password
  if ! srv ServerInfoGet 2> /dev/null; then
    timeout 30 vpncmd "localhost:${ADMIN_PORT}" /SERVER /CMD ServerPasswordSet "$ADMIN_PASS" < /dev/null > /dev/null 2>&1 \
      || die "Cannot log in to SoftEther. If you set its admin password yourself, put it in ${CONF_FILE} as ADMIN_PASS=... and run again."
  fi
  srv ServerPasswordSet "$ADMIN_PASS"
}

configure() {
  local p extra name

  say "Listener on TCP ${PORT} ..."
  srv ListenerCreate "$PORT" 2> /dev/null || true # already there on a re-run
  wait_port "$PORT" || die "SoftEther could not listen on TCP ${PORT}."
  ADMIN_PORT=$PORT
  for p in 443 992 1194 5555 $OLD_PORT; do
    [[ $p == "$PORT" ]] || srv ListenerDelete "$p" 2> /dev/null || true
  done

  # the other protocols would hold more ports (UDP 443/992/1194/5555, SSTP on the listener) or phone home
  srv PortsUDPSet 0
  srv ProtoOptionsSet OpenVPN /NAME:Enabled /VALUE:false
  srv ProtoOptionsSet SSTP /NAME:Enabled /VALUE:false
  srv VpnAzureSetEnable no
  srv KeepDisable 2> /dev/null || true

  say "Hub ${HUB}, players: ${PLAYERS} ..."
  srv HubCreate "$HUB" "/PASSWORD:${ADMIN_PASS}" 2> /dev/null || true
  srv HubDelete DEFAULT 2> /dev/null || true
  for name in $OLD_PLAYERS; do
    [[ " ${PLAYERS,,} " == *" ${name,,} "* ]] && continue
    hub UserDelete "$name" 2> /dev/null || true
    sed -i "/^${name} /d" "$PASS_FILE" 2> /dev/null || true
  done
  for name in $PLAYERS; do
    hub UserCreate "$name" /GROUP:none /REALNAME:none /NOTE:none 2> /dev/null || true
    hub UserPasswordSet "$name" "/PASSWORD:$(player_pass "$name")"
  done
  # SecureNAT only for DHCP: no NAT and no gateway, so the players' internet stays on their own line
  hub SecureNatHostSet /MAC:none "/IP:${SUBNET}.1" /MASK:255.255.255.0
  hub NatDisable
  hub DhcpSet "/START:${SUBNET}.10" "/END:${SUBNET}.250" /MASK:255.255.255.0 /EXPIRE:86400 \
    /GW:none /DNS:none /DNS2:none /DOMAIN:none /LOG:no
  hub SecureNatEnable

  extra=$(vpn_ports | grep -vx "$PORT" | tr '\n' ' ') || true
  [[ -z $extra ]] || warn "SoftEther still listens on TCP ${extra}(another listener you made?)."
}

# ---------------------------------------------------------------------------
# Download page
# ---------------------------------------------------------------------------
# the Windows client from GitHub, straight or through a GitHub proxy
fetch_client() {
  local dir=$1 url u
  [[ -s ${dir}/${CLIENT_EXE} ]] && return 0
  say "Downloading the SoftEther VPN Client for Windows (~55 MB) ..."
  url=$(curl -fsS --max-time 20 https://api.github.com/repos/SoftEtherVPN/SoftEtherVPN_Stable/releases/latest 2> /dev/null \
    | grep -o '"browser_download_url": *"[^"]*vpnclient[^"]*windows[^"]*\.exe"' | head -n 1 | cut -d'"' -f4) || true
  # shortcut: pinned to the release current in 2026-11, when the API is unreachable
  [[ -n $url ]] || url=https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.41-9787-rtm/softether-vpnclient-v4.41-9787-rtm-2023.03.14-windows-x86_x64-intel.exe
  for u in "$url" "https://ghfast.top/${url}" "https://gh-proxy.com/${url}"; do
    if curl -fL --max-time 900 -o "${dir}/${CLIENT_EXE}.part" "$u" 2> /dev/null \
      && (($(stat -c %s "${dir}/${CLIENT_EXE}.part") > 10000000)); then
      mv "${dir}/${CLIENT_EXE}.part" "${dir}/${CLIENT_EXE}"
      return 0
    fi
  done
  rm -f "${dir}/${CLIENT_EXE}.part"
  warn "Could not download the client. Put it there yourself: ${dir}/${CLIENT_EXE}"
  warn "  (softether-vpnclient-...-windows-x86_x64-intel.exe from softether-download.com)"
}

# write_vpn <name> <password> <host> <out>: a connection file the client imports on double-click
write_vpn() {
  python3 -I - "$1" "$2" "$3" "$PORT" "$HUB" "$4" << 'PY'
import base64, struct, sys
name, pw, host, port, hub, out = sys.argv[1:]

def sha0(m):
    h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    m += b"\x80" + b"\0" * ((55 - len(m)) % 64) + struct.pack(">Q", len(m) * 8)
    for o in range(0, len(m), 64):
        w = list(struct.unpack(">16I", m[o:o + 64]))
        for t in range(16, 80):
            w.append(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16])  # SHA-1 would rotate here
        a, b, c, d, e = h
        for t in range(80):
            if t < 20:
                f, k = (b & c) | (~b & d), 0x5A827999
            elif t < 40:
                f, k = b ^ c ^ d, 0x6ED9EBA1
            elif t < 60:
                f, k = (b & c) | (b & d) | (c & d), 0x8F1BBCDC
            else:
                f, k = b ^ c ^ d, 0xCA62C1D6
            a, b, c, d, e = (((a << 5) | (a >> 27)) + f + e + k + w[t]) & 0xFFFFFFFF, a, ((b << 30) | (b >> 2)) & 0xFFFFFFFF, c, d
        h = [(x + y) & 0xFFFFFFFF for x, y in zip(h, (a, b, c, d, e))]
    return struct.pack(">5I", *h)

assert sha0(b"abc").hex() == "0164b8a914cd2a5e74c4f7ff082c4d97f1edf880"
# SoftEther stores SHA-0(password + upper-case user name)
hashed = base64.b64encode(sha0(pw.encode() + name.upper().encode())).decode()
lines = f"""# VPN Client VPN Connection Setting File
# Written by lan-setup.sh. Double-click to add it to SoftEther VPN Client.

declare root
{{
	bool CheckServerCert false
	uint64 CreateDateTime 0
	uint64 LastConnectDateTime 0
	bool RetryOnServerCert false
	bool StartupAccount false
	uint64 UpdateDateTime 0

	declare ClientAuth
	{{
		uint AuthType 1
		byte HashedPassword {hashed}
		string Username {name}
	}}
	declare ClientOption
	{{
		string AccountName GameLAN
		uint AdditionalConnectionInterval 1
		uint ConnectionDisconnectSpan 0
		string DeviceName VPN
		bool DisableQoS false
		bool HalfConnection false
		bool HideNicInfoWindow false
		bool HideStatusWindow false
		string Hostname {host}
		string HubName {hub}
		uint MaxConnection 1
		bool NoRoutingTracking false
		bool NoUdpAcceleration false
		uint NumRetry 4294967295
		uint Port {port}
		uint PortUDP 0
		string ProxyName $
		byte ProxyPassword $
		uint ProxyPort 0
		uint ProxyType 0
		string ProxyUsername $
		bool RequireBridgeRoutingMode false
		bool RequireMonitorMode false
		uint RetryInterval 15
		bool UseCompress false
		bool UseEncrypt true
	}}
}}
"""
with open(out, "w", encoding="utf-8-sig", newline="\r\n") as f:
    f.write(lines)
PY
}

write_page() {
  local ip=$1 dir="${WWW}/${WEB_TOKEN}" name links=""
  mkdir -p "$dir"
  # only the secret path is listed nowhere
  : > "${WWW}/index.html"
  find "$WWW" -mindepth 1 -maxdepth 1 -type d ! -name "$WEB_TOKEN" -exec rm -rf {} +
  rm -f "${dir}"/*.vpn
  fetch_client "$dir"

  for name in $PLAYERS; do
    write_vpn "$name" "$(player_pass "$name")" "$ip" "${dir}/${name}.vpn"
    links+="<a class=b href=\"${name}.vpn\" download>${name}</a> "
  done

  # CRLF: cmd.exe misreads a .bat with bare LF line ends
  sed 's/$/\r/' > "${dir}/fix-lan.bat" << 'EOF'
@echo off
rem Written by lan-setup.sh: the game's LAN list goes through the VPN, and the firewall lets players in
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'" & exit /b)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$a = (Get-NetAdapter -InterfaceDescription 'VPN Client Adapter*' -ErrorAction SilentlyContinue).Name; if (-not $a) { Write-Host 'Connect in SoftEther VPN Client first, then run this again.'; exit 1 }; Set-NetIPInterface -InterfaceAlias $a -InterfaceMetric 1; Set-NetConnectionProfile -InterfaceAlias $a -NetworkCategory Private; Write-Host 'Done. You only need this once.'"
pause
EOF

  cat > "${dir}/index.html" << EOF
<!doctype html>
<html lang="fa" dir="rtl">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Game LAN</title>
<style>
  body { font-family: Tahoma, sans-serif; max-width: 640px; margin: 0 auto; padding: 16px; line-height: 2; background: #fff; color: #111; }
  .b { display: inline-block; padding: 2px 14px; margin: 4px; border: 1px solid #888; border-radius: 6px; text-decoration: none; color: inherit; }
  li { margin-bottom: 12px; }
  @media (prefers-color-scheme: dark) { body { background: #111; color: #eee; } a { color: #8bf; } }
</style>
<h2>بازی LAN</h2>
<ol>
  <li><a class=b href="${CLIENT_EXE}">SoftEther VPN Client</a> را دانلود و نصب کن (در نصب، «SoftEther VPN Client» را انتخاب کن).</li>
  <li>فایل اسم خودت را دانلود کن و رویش دابل‌کلیک کن:<br>${links}</li>
  <li>در برنامه روی «GameLAN» دابل‌کلیک کن تا وصل شود. اگر پرسید کارت شبکه بسازد، Yes بزن.</li>
  <li>فقط بار اول، وقتی وصلی: <a class=b href="fix-lan.bat" download>fix-lan.bat</a> را اجرا کن و اجازه‌ی Administrator را بده.</li>
</ol>
<p>بعد یکی از شما در بازی سرور LAN می‌سازد و بقیه از لیست LAN بازی، یا با آدرس ${SUBNET}.x او، وصل می‌شوند.
Radmin و Hamachi را موقع بازی قطع کنید.</p>
</html>
EOF
  chmod -R a+rX "$WWW"

  cat > "/etc/systemd/system/${WEB_UNIT}.service" << EOF
[Unit]
Description=lan-setup download page
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
ExecStart=/usr/bin/python3 -m http.server ${WEB_PORT} --directory ${WWW}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q "$WEB_UNIT"
  systemctl restart "$WEB_UNIT"
  LINK="http://${ip}:${WEB_PORT}/${WEB_TOKEN}/"
  printf 'LINK=%q\n' "$LINK" >> "$CONF_FILE"
}

write_ctl() {
  cat > "$CTL" << EOF
#!/usr/bin/env bash
# Written by lan-setup.sh
set -euo pipefail
[[ \${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
# shellcheck disable=SC1091
. ${CONF_FILE}

case "\${1:-}" in
  start) systemctl enable -q --now ${UNIT} ${WEB_UNIT} && echo "LAN started (also starts at boot)." ;;
  stop) systemctl disable -q --now ${UNIT} ${WEB_UNIT} && echo "LAN stopped (stays off after a reboot)." ;;
  restart) systemctl restart ${UNIT} ${WEB_UNIT} && echo "LAN restarted." ;;
  status) systemctl status ${UNIT} ${WEB_UNIT} --no-pager -n 0 ;;
  who) timeout 30 vpncmd "localhost:\${PORT}" /SERVER /HUB:${HUB} "/PASSWORD:\${ADMIN_PASS}" /CMD IpTable < /dev/null | sed -n '/^IpTable command/,\$p' ;;
  link) echo "\${LINK}" ;;
  *)
    cat >&2 << 'USAGE'
Usage: lanctl <command>
  start | stop | restart | status
  who       who is connected, with their ${SUBNET}.x addresses (SID-<NAME>-...)
  link      the download page for the players
USAGE
    exit 1
    ;;
esac
EOF
  chmod 755 "$CTL"
}

open_ports() {
  local lo hi
  # UDP acceleration (game packets over UDP instead of TCP) uses a random local UDP port
  read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range
  if command -v ufw > /dev/null && ufw status 2> /dev/null | grep -q 'Status: active'; then
    ufw allow "${PORT}/tcp" > /dev/null
    ufw allow "${WEB_PORT}/tcp" > /dev/null
    ufw allow "${lo}:${hi}/udp" > /dev/null
  fi
  if command -v firewall-cmd > /dev/null && [[ $(firewall-cmd --state 2> /dev/null) == running ]]; then
    firewall-cmd -q --permanent --add-port="${PORT}/tcp" || true
    firewall-cmd -q --permanent --add-port="${WEB_PORT}/tcp" || true
    firewall-cmd -q --permanent --add-port="${lo}-${hi}/udp" || true
    firewall-cmd -q --reload || true
  fi
}

# the interface's public address first: the outgoing IP can be a provider NAT that changes per request
public_ipv4() {
  local u ip
  ip=$(ip -4 -o addr show scope global | awk '{split($4, a, "/"); print a[1]}' \
    | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -n 1) || true
  [[ -n $ip ]] && { printf '%s\n' "$ip"; return 0; }
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 10 "$u" 2> /dev/null | tr -d '[:space:]') || continue
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { printf '%s\n' "$ip"; return 0; }
  done
  hostname -I | awk '{print $1}'
}

main() {
  say "lan-setup.sh -- log: ${LOG_FILE}"
  [[ -r /etc/os-release ]] && say "OS: $(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
  ask_all
  ensure_packages
  admin_login
  configure
  write_page "$(public_ipv4)"
  write_ctl
  open_ports
  cat << EOF

[+] Done. Send this link to the players (it holds their connection files):

      ${LINK}

    Each player: install the client from the page, double-click their
    <name>.vpn, connect, and run fix-lan.bat once. One player hosts a LAN
    game; the others find it in the LAN list or join its ${SUBNET}.x address.

    Start/stop : lanctl start | stop | restart | status
    Who is on  : lanctl who        The link again: lanctl link
    Players    : run this script again to add or remove names
    Open TCP ${PORT} and ${WEB_PORT} in your provider's firewall too, if it has one.
EOF
}

main "$@"
