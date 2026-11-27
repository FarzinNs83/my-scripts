#!/usr/bin/env bash
# =============================================================================
#  game-setup.sh -- AmneziaWG (WireGuard with DPI obfuscation) for gaming
#
#  Games send most of their traffic over UDP, so this gives players a
#  low-latency UDP path that is separate from the BackPack tunnel and the
#  3x-ui inbounds:
#    - its own interfaces (awg-game for players, awg-link between servers),
#      subnets (10.66.66.0/24 direct, 10.68.68.0/24 through Iran, 10.67.67.0/30
#      link) and UDP ports (random free ones unless --port is given)
#    - its own configs, units, NAT rules, sysctl file and state
#    - it never touches x-ui, BackPack, nginx or AdGuard Home
#  AmneziaWG adds junk packets and random headers to the WireGuard handshake
#  only, so the data packets (and the ping) are the same as plain WireGuard.
#
#  Two layouts:
#    direct       players -> kharej -> internet
#                   kharej: bash game-setup.sh --domain game.example.com
#    through Iran players -> Iran -> awg-link -> kharej -> internet
#                   kharej: bash game-setup.sh link      (prints a token)
#                   Iran:   bash game-setup.sh bridge --token <token> --domain game.example.com
#                 Players connect to the Iran server (their leg stays
#                 domestic); only their subnet is routed into the link, and
#                 the kharej NATs it out to the internet.
#                 The link runs over UDP or fake TCP (phantun, for routes that
#                 block or throttle UDP); `gamectl mode udp|faketcp` on Iran
#                 switches between them (`link --faketcp` starts on fake TCP).
#
#  Usage:
#    bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/game-setup.sh)
#    gamectl add ali | remove ali | show ali | download ali | list | status | repair | uninstall
#
#  Clients: AmneziaVPN or AmneziaWG (Android, iOS, Windows, macOS, Linux).
#  Import the .conf file or scan the QR code that `gamectl show` prints.
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SELF_URL="${GS_SELF_URL:-https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/game-setup.sh}"
AWG_DIR="${GS_AWG_DIR:-/etc/amnezia/amneziawg}"
IFACE="awg-game" # players
UNIT="awg-quick@${IFACE}.service"
SERVER_CONF="${AWG_DIR}/${IFACE}.conf"
LINK_IFACE="awg-link" # Iran <-> kharej
LINK_UNIT="awg-quick@${LINK_IFACE}.service"
LINK_CONF="${AWG_DIR}/${LINK_IFACE}.conf"
LINK_NET="10.67.67" # /30: .1 kharej, .2 Iran
LINK_MTU=1420
LINK_TABLE=6767 # Iran: routing table (and rule priority) for the players' traffic
GS_DIR="${GS_DIR:-/etc/game-setup}"
STATE_FILE="${GS_DIR}/state.env"
LINK_ENV="${GS_DIR}/link.env"
CLIENTS_DIR="${GS_DIR}/clients"
DOWNLOAD_ENV="${GS_DIR}/download.env"
DOWNLOAD_SCRIPT="${GS_DIR}/download.py"
DOWNLOAD_UNIT="game-download.service"
DOWNLOAD_UNIT_FILE="${GS_UNIT_DIR:-/etc/systemd/system}/${DOWNLOAD_UNIT}"
SYSCTL_FILE="/etc/sysctl.d/99-game-setup.conf"
LOG_FILE="/var/log/game-setup.log"
# --faketcp: the link's UDP rides in fake TCP (phantun), for routes that block or throttle UDP
PHANTUN_VER=v0.8.1
declare -A PHANTUN_SHA=( # sha256 of the release zips (GitHub's asset digests); pinned, so a mirror is safe too
  [x86_64]=0cf40f0ac48411f8ced94ce0afd617105c6b9a69ad8db137c3b1e4d184d6fcdb
  [aarch64]=e3f2336b5173df071c8931b5e0e3d44c57453da0456007ed459ed369610c91fa
)
FT_UNIT="game-phantun.service"
FT_UNIT_FILE="${GS_UNIT_DIR:-/etc/systemd/system}/${FT_UNIT}"
FT_IFACE="ft-link"
FT_KH="10.67.68" # kharej phantun TUN: .1 kernel, .2 phantun (the DNAT target)
FT_IR="10.67.69" # Iran phantun TUN
FT_MTU=1400 # 1500 - IPv4 20 - TCP 20 - WireGuard 32 = 1428, with room for smaller provider MTUs
PPA_URL="https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu"
KEYRING="/etc/apt/keyrings/amnezia-ppa.gpg"

CMD=""
NAME=""
PORT=""
NET="10.66.66" # players' /24, first three octets
BRIDGE_NET="10.68.68" # players' /24 in the Iran layout, so it never clashes with a direct server
SUBNET_SET=0
ENDPOINT=""
DOWNLOAD_DOMAIN=""
DOWNLOAD=0
TOKEN_IN=""
BRIDGE=0
FAKETCP=0
DNS="1.1.1.1, 8.8.8.8"
MTU=1280 # fits Iranian mobile networks; games send small packets anyway
YES=0

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
game-setup.sh -- AmneziaWG server for gaming, separate from BackPack / 3x-ui.

Usage:
  sudo bash game-setup.sh [options]            direct: players -> this server
  sudo bash game-setup.sh link [options]       kharej end of the Iran link; prints a token
  sudo bash game-setup.sh bridge --token <t>   Iran: players -> Iran -> link -> kharej
  gamectl <command> [name]

Options:
      --port <n>          UDP port (default: a random free port 20000-60000);
                          for `link` it is the link port on the kharej;
                          80 and 443 are reserved for your other services
      --domain <domain>   required for players: domain pointing to this server;
                          also used for config download links
      --endpoint <host>   alias for --domain; for `link`, an IP is allowed
                          (link default: this server's public IPv4)
      --download         offer HTTPS config downloads, valid for 24 hours;
                          separate HTTPS port; certificate validation forwards
                          TCP/80 temporarily to another free port, never binds
                          80/443 or stops existing services
      --subnet <a.b.c>    players' /24, first three octets
                          (default: 10.66.66 direct, 10.68.68 through Iran)
      --dns "<ip>, <ip>"  DNS for players (default: 1.1.1.1, 8.8.8.8)
      --token <t>         for `bridge`: the token `link` printed on the kharej
      --faketcp           for `link`: Iran starts on fake TCP (phantun) instead
                          of UDP. The kharej always takes both on the same port
                          (open it for UDP and TCP), so Iran can switch any time
                          with `gamectl mode`
  -h, --help             show this help

Commands (same as gamectl):
  add <name>          new player: config file + QR code
  remove <name>       delete a player
  show <name>         print a player's config and QR code again
  list                players, their IPs and last handshake
  status              link and player server state (awg show)
  repair              update routing/firewall and client configs, keeping keys
  download <name>     issue a fresh 24-hour link (replaces the previous link)
  mode [udp|faketcp]  on Iran: show or switch the link's route to the kharej;
                      players stay connected
  link                on the kharej: print the token again
  uninstall [--yes]   remove the server, link, players, NAT and routing rules
                      and state; the amneziawg packages stay installed

In the Iran layout players are managed on the Iran server.
Clients: AmneziaVPN or AmneziaWG. Import the .conf or scan the QR code.
Player configs are kept in /etc/game-setup/clients/<name>.conf.
EOF
}

_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] Failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_service_port() { valid_port "$1" && (( 10#$1 != 80 && 10#$1 != 443 )); }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) PORT=${2:?}; shift 2 ;;
      --domain | --endpoint) ENDPOINT=${2:?}; shift 2 ;;
      --download) DOWNLOAD=1; shift ;;
      --subnet) NET=${2:?}; SUBNET_SET=1; shift 2 ;;
      --dns) DNS=${2:?}; shift 2 ;;
      --token) TOKEN_IN=${2:?}; shift 2 ;;
      --faketcp) FAKETCP=1; shift ;;
      --yes) YES=1; shift ;;
      -h | --help) CMD=help; shift ;;
      -*) die "Unknown option: $1 (see --help)" ;;
      *) if [[ -z $CMD ]]; then CMD=$1; else NAME=$1; fi; shift ;;
    esac
  done
  [[ -z $PORT ]] || valid_service_port "$PORT" || die "Invalid port: $PORT (80 and 443 are reserved for other services)"
  [[ $NET =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "Invalid subnet (want three octets, e.g. 10.66.66): $NET"
  [[ -z $ENDPOINT || $ENDPOINT =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid endpoint: $ENDPOINT"
  [[ $DNS =~ ^[0-9a-fA-F.:,\ ]+$ ]] || die "Invalid DNS list: $DNS"
  [[ -z $TOKEN_IN || $TOKEN_IN =~ ^[A-Za-z0-9+/=]+$ ]] || die "Invalid token (copy it again from the kharej)"
  [[ -z $NAME || $NAME =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "Player names: letters, digits, _ and -, up to 32"
  return 0
}

valid_domain() { [[ ${#1} -le 253 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.[A-Za-z]{2,63}$ ]]; }

player_options() {
  if [[ -z $ENDPOINT && -t 0 ]]; then
    read -rp 'Domain for player configs and downloads (required): ' ENDPOINT
  fi
  valid_domain "$ENDPOINT" || die "Players need a domain pointing to this server: --domain game.example.com"
  if [[ $DOWNLOAD == 0 && ! -f $DOWNLOAD_ENV && -t 0 ]]; then
    local answer=""
    read -rp 'Offer 24-hour HTTPS config download links? [y/N] ' answer
    [[ ! $answer =~ ^[Yy] ]] || DOWNLOAD=1
  fi
}

port_busy() { ss -Htuln 2> /dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }

pick_port() { # keeps a free --port, else picks a random free one
  if [[ -n $PORT ]]; then
    valid_service_port "$PORT" || die "Invalid port: $PORT (80 and 443 are reserved for other services)"
    ! port_busy "$PORT" || die "Port ${PORT} is already in use (BackPack/x-ui/another service). Pick another --port."
    return 0
  fi
  PORT=$(shuf -i 20000-60000 -n 1)
  while port_busy "$PORT"; do PORT=$(shuf -i 20000-60000 -n 1); done
}

subnet_free() { ! ip -4 addr show | grep -qF "inet $1." && ! ip -4 route show | grep -q "^${1//./\\.}\."; }

wan_iface() { ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'; }

open_port() { # <port>/<proto>
  if command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q '^Status: active'; then
    ufw allow "$1" > /dev/null
  elif command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
    firewall-cmd -q --permanent --add-port="$1" && firewall-cmd -q --reload
  fi
}

close_port() { # <port>/<proto>; best effort
  if command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q '^Status: active'; then
    ufw delete allow "$1" > /dev/null 2>&1 || true
  elif command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
    firewall-cmd -q --permanent --remove-port="$1" 2> /dev/null && firewall-cmd -q --reload || true
  fi
}

enable_forwarding() {
  echo 'net.ipv4.ip_forward = 1' > "$SYSCTL_FILE"
  sysctl -q -p "$SYSCTL_FILE"
}

# Junk-packet and header parameters; both ends must share S1, S2, H1-H4.
# Rules from AmneziaWG: Jmin < Jmax <= 1280, S1 + 56 != S2, H1-H4 distinct and > 4.
gen_junk() {
  local jc jmin jmax s1 s2 h
  jc=$(shuf -i 3-6 -n 1)
  jmin=$(shuf -i 40-60 -n 1)
  jmax=$((jmin + $(shuf -i 20-60 -n 1)))
  s1=$(shuf -i 15-150 -n 1)
  s2=$(shuf -i 15-150 -n 1)
  while ((s2 == s1 + 56)); do s2=$(shuf -i 15-150 -n 1); done
  mapfile -t h < <(shuf -i 5-2147483647 -n 4)
  printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' \
    "$jc" "$jmin" "$jmax" "$s1" "$s2" "${h[@]}"
}

post_rules() { # [<players-net> <wan>]: PostUp/PostDown that let %i forward, plus NAT out of <wan> when given
  local c="-m comment --comment game-setup"
  local fin="FORWARD -i %i $c -j ACCEPT" fout="FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED $c -j ACCEPT"
  local up="iptables -I $fin; iptables -I $fout" down="iptables -D $fin; iptables -D $fout"
  # Pin TCP to the player MTU; a successful handshake does not prove large HTTPS packets fit.
  local direction mss
  for direction in -i -o; do
    mss="FORWARD $direction %i -p tcp --tcp-flags SYN,RST SYN $c -j TCPMSS --set-mss $((MTU - 40))"
    up+="; iptables -t mangle -I $mss"
    down+="; iptables -t mangle -D $mss"
  done
  if [[ $# -eq 2 ]]; then
    local nat="POSTROUTING -s $1.0/24 -o $2 $c -j MASQUERADE"
    up+="; iptables -t nat -A $nat"
    down+="; iptables -t nat -D $nat"
  else
    # A missing/overridden policy route must not send players out with Iran's IP.
    local guard="FORWARD -i %i ! -o $LINK_IFACE ! -d $NET.0/24 $c -j REJECT"
    up+="; iptables -I $guard"
    down+="; iptables -D $guard"
  fi
  printf 'PostUp = %s\nPostDown = %s\n' "$up" "$down"
}

# The kharej hands Iran everything for its end of the link in one token, so no SSH is needed.
# FT: the mode Iran starts in (1 = fake TCP); FTOK: the kharej also takes fake TCP, so Iran can switch
make_token() { # <kharej-host> <link-port> <kharej-pub> <iran-priv> <psk> <players-net> <junk lines> [<FT 0|1> [<FTOK 0|1>]]
  printf 'KH=%s\nLPORT=%s\nKPUB=%s\nIPRIV=%s\nPSK=%s\nNET=%s\n%s\nFT=%s\nFTOK=%s\n' "$@" | base64 -w0
}

read_token() { # <token>: sets T_KH T_LPORT T_KPUB T_IPRIV T_PSK T_JUNK T_FT T_FTOK and NET, or dies
  local t key='^[A-Za-z0-9+/]{43}=$'
  t=$(base64 -d <<< "$1" 2> /dev/null) || die "The token is broken; copy it again from the kharej (gamectl link)."
  T_KH=$(sed -n 's/^KH=//p' <<< "$t")
  T_LPORT=$(sed -n 's/^LPORT=//p' <<< "$t")
  T_KPUB=$(sed -n 's/^KPUB=//p' <<< "$t")
  T_IPRIV=$(sed -n 's/^IPRIV=//p' <<< "$t")
  T_PSK=$(sed -n 's/^PSK=//p' <<< "$t")
  NET=$(sed -n 's/^NET=//p' <<< "$t")
  T_JUNK=$(grep -E '^(Jc|Jmin|Jmax|S1|S2|H[1-4]) = [0-9]+$' <<< "$t" || true)
  T_FT=$(sed -n 's/^FT=//p' <<< "$t")
  T_FT=${T_FT:-0} # tokens from before --faketcp have no FT line
  T_FTOK=$(sed -n 's/^FTOK=//p' <<< "$t")
  T_FTOK=${T_FTOK:-$T_FT} # nor FTOK: fake TCP only when it was the mode
  [[ $T_FT =~ ^[01]$ && $T_FTOK =~ ^[01]$ && $T_FT -le $T_FTOK ]] && [[ $T_KH =~ ^[A-Za-z0-9.-]+$ ]] && valid_port "$T_LPORT" &&
    [[ $T_KPUB =~ $key && $T_IPRIV =~ $key && $T_PSK =~ $key ]] &&
    [[ $NET =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && [[ $(wc -l <<< "$T_JUNK") == 9 ]] ||
    die "The token is incomplete; copy it again from the kharej (gamectl link)."
}

next_ip() { # first free host address in the /24 (.1 is the server)
  local i
  for i in $(seq 2 254); do
    grep -qxF "AllowedIPs = ${NET}.${i}/32" "$SERVER_CONF" || { echo "${NET}.${i}"; return 0; }
  done
  die "No free addresses left in ${NET}.0/24"
}

drop_peer() { # <name>: print the server config without that player's [Peer] block
  awk -v n="# $1" 'BEGIN { RS = ""; ORS = "\n\n" }
    { c = split($0, l, "\n"); k = 0; for (i = 1; i <= c; i++) if (l[i] == n) k = 1; if (!k) print }' "$SERVER_CONF"
}

load_state() {
  [[ -f $STATE_FILE && -f $SERVER_CONF ]] || die "No player server on this machine. Run: bash game-setup.sh (or bridge on Iran)"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  # Older state files did not record the layout.
  if [[ -f $LINK_CONF ]] && grep -qxF 'Table = off' "$LINK_CONF"; then BRIDGE=1; fi
}

reload() { awg syncconf "$IFACE" <(awg-quick strip "$IFACE"); } # apply peers without dropping anyone

is_private_ipv4() { [[ $1 =~ ^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }

# The interface address when it is public: some Iranian datacenters send traffic to
# lookup sites out through another IP, so a lookup can name an address players cannot reach.
public_ipv4() {
  local url ip src
  src=$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
  if [[ -n $src ]] && ! is_private_ipv4 "$src"; then
    echo "$src"
    return 0
  fi
  for url in https://ipv4.icanhazip.com https://4.ident.me https://api4.ipify.org; do # behind NAT: ask outside
    ip=$(curl -4 -fsS --max-time 8 "$url" 2> /dev/null | tr -d '[:space:]') || continue
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
  done
  echo "$src"
}

install_awg() {
  local id suite fpr
  id=$(. /etc/os-release && printf '%s' "${ID:-}")
  case $id in
    ubuntu) suite=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}") ;;
    debian) suite=focal ;; # what the AmneziaWG docs use on Debian; the module is built by DKMS
    *) die "Ubuntu or Debian only (found: ${id:-unknown})." ;;
  esac
  say "Installing curl, gnupg, iptables and qrencode"
  apt-get -o DPkg::Lock::Timeout=120 update -qq
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq curl gnupg iptables qrencode > /dev/null
  if command -v awg-quick > /dev/null 2>&1 && modprobe amneziawg 2> /dev/null; then
    say "AmneziaWG is already installed."
    return 0
  fi
  say "Installing kernel headers for $(uname -r)"
  if ! apt-get -o DPkg::Lock::Timeout=120 install -y -qq "linux-headers-$(uname -r)" > /dev/null; then
    # an old running kernel whose headers left the archive: a kernel upgrade and reboot fix it
    [[ $(systemd-detect-virt 2> /dev/null) != @(openvz|lxc|lxc-libvirt) ]] &&
      apt-cache policy linux-headers-generic 2> /dev/null | grep -q 'Candidate: [0-9]' &&
      die "The headers for the running kernel $(uname -r) are no longer in the archive. Upgrade the kernel and reboot, then run this again: apt-get install -y linux-generic && reboot"
    die "Could not install linux-headers-$(uname -r). AmneziaWG needs a KVM/dedicated VPS with its distribution kernel (not OpenVZ/LXC)."
  fi
  curl -fsI --max-time 15 "${PPA_URL}/dists/${suite}/Release" > /dev/null 2>&1 || suite=noble # newest release not in the PPA yet
  say "Adding the AmneziaWG PPA (${suite})"
  # shortcut: no offline fallback; an Iran server that cannot reach Launchpad needs an apt proxy for this step
  fpr=$(curl -fsS --max-time 20 https://api.launchpad.net/1.0/~amnezia/+archive/ubuntu/ppa |
    grep -o '"signing_key_fingerprint": *"[0-9A-F]*"' | grep -o '[0-9A-F]\{40\}') ||
    die "Could not reach Launchpad for the AmneziaWG PPA (filtered network? set an apt/https proxy and run again)."
  install -d -m 755 "$(dirname "$KEYRING")"
  curl -fsS --max-time 20 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${fpr}&options=mr" | gpg --dearmor --yes -o "$KEYRING"
  echo "deb [signed-by=${KEYRING}] ${PPA_URL} ${suite} main" > /etc/apt/sources.list.d/amnezia-ppa.list
  apt-get -o DPkg::Lock::Timeout=120 update -qq
  say "Installing amneziawg (builds the kernel module, takes a minute)"
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq amneziawg > /dev/null
  modprobe amneziawg || die "The amneziawg kernel module did not load. Check: dkms status"
}

install_phantun() { # pinned release; GitHub, then the ghfast.top mirror, then /root/<zip>; always sha256-checked
  local arch zip sum url tmp
  arch=$(uname -m)
  sum=${PHANTUN_SHA[$arch]:-}
  [[ -n $sum ]] || die "Fake TCP (phantun) is set up for x86_64 and aarch64 only (this server: ${arch})."
  zip="phantun_${arch}-unknown-linux-musl.zip"
  url="https://github.com/dndx/phantun/releases/download/${PHANTUN_VER}/${zip}"
  command -v unzip > /dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=120 install -y -qq unzip > /dev/null
  tmp=$(mktemp -d)
  if [[ -f /root/$zip ]]; then
    cp "/root/$zip" "$tmp/$zip"
  else
    say "Downloading phantun ${PHANTUN_VER}"
    curl -fsSL --max-time 120 -o "$tmp/$zip" "$url" || curl -fsSL --max-time 120 -o "$tmp/$zip" "https://ghfast.top/$url" || true
  fi
  if [[ $(sha256sum "$tmp/$zip" 2> /dev/null | cut -d' ' -f1) != "$sum" ]]; then
    rm -rf "$tmp"
    die "Could not get a verified ${zip}. Download ${url} on another machine, copy it to /root here and run again."
  fi
  unzip -qjo "$tmp/$zip" -d "$tmp/x"
  install -m 0755 "$tmp/x/phantun_client" "$tmp/x/phantun_server" /usr/local/bin/ ||
    { rm -rf "$tmp"; die "${zip} has no phantun_client / phantun_server"; }
  rm -rf "$tmp"
}

ft_unit() { # <phantun command line> <"table chain spec">...: the fake-TCP carrier, its iptables rules added and removed with it
  local ipt r rules=""
  ipt=$(command -v iptables)
  for r in "${@:2}"; do # "+" runs the rule as root; phantun itself only gets CAP_NET_ADMIN
    rules+="ExecStartPre=-+${ipt} -t ${r%% *} -D ${r#* }
ExecStartPre=+${ipt} -t ${r%% *} -I ${r#* }
ExecStopPost=-+${ipt} -t ${r%% *} -D ${r#* }
"
  done
  cat > "$FT_UNIT_FILE" <<UNIT
[Unit]
Description=Fake TCP (phantun) for the game-setup link
After=network-online.target
Wants=network-online.target

[Service]
Environment=RUST_LOG=warn
DynamicUser=yes
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
${rules}ExecStart=$1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
}

start_phantun() {
  systemctl daemon-reload
  systemctl enable "$FT_UNIT" > /dev/null 2>&1
  systemctl restart "$FT_UNIT" || die "${FT_UNIT} did not start: journalctl -u ${FT_UNIT}"
}

download_python() {
  cat <<'PYDOWNLOAD'
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import sys
import time


def issue(root, name):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", name) or not (root / "clients" / (name + ".conf")).is_file():
        raise ValueError("No such player")
    folder = root / "downloads"
    folder.mkdir(mode=0o700, exist_ok=True)
    token = secrets.token_urlsafe(32)
    record = {"hash": hashlib.sha256(token.encode()).hexdigest(), "expires": time.time() + 86400}
    temporary = folder / (name + "." + secrets.token_hex(8) + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.chmod(temporary, 0o600)
            json.dump(record, stream)
        temporary.replace(folder / (name + ".json"))
    finally:
        temporary.unlink(missing_ok=True)
    return name + "/" + token + ".conf"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        match = re.fullmatch(r"/([A-Za-z0-9_-]{1,32})/([A-Za-z0-9_-]{43})\.conf", self.path)
        if not match:
            self.send_error(404)
            return
        name, token = match.groups()
        try:
            record = json.loads((self.server.root / "downloads" / (name + ".json")).read_text())
            if time.time() >= record["expires"] or not hmac.compare_digest(
                    record["hash"], hashlib.sha256(token.encode()).hexdigest()):
                self.send_error(404)
                return
            content = (self.server.root / "clients" / (name + ".conf")).read_bytes()
        except (OSError, ValueError, KeyError, TypeError):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="' + name + '.conf"')
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, *_):
        pass  # Download URLs contain credentials; keep them out of access logs.


class Server(http.server.ThreadingHTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        try:
            # Reload renewed certificates without restarting the service.
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(self.cert, self.key)
            return context.wrap_socket(connection, server_side=True), address
        except (OSError, ValueError):
            connection.close()
            raise


if __name__ == "__main__":
    root = Path(sys.argv[1])
    if sys.argv[2] == "issue":
        print(issue(root, sys.argv[3]))
    else:
        server = Server(("0.0.0.0", int(sys.argv[2])), Handler)
        server.root, server.cert, server.key = root, sys.argv[3], sys.argv[4]
        server.serve_forever()
PYDOWNLOAD
}

setup_downloads() {
  valid_domain "$ENDPOINT" || die "Downloads need --domain game.example.com (the same domain as player configs)."
  local PORT="" DOWNLOAD_PORT="" cert key acme_port nat input
  [[ ! -f $DOWNLOAD_ENV ]] || . "$DOWNLOAD_ENV"
  [[ -z $DOWNLOAD_PORT ]] || valid_service_port "$DOWNLOAD_PORT" || die "Download port ${DOWNLOAD_PORT} is invalid; 80/443 are reserved."
  if [[ -z $DOWNLOAD_PORT ]]; then pick_port; DOWNLOAD_PORT=$PORT; fi
  DOWNLOAD_DOMAIN=$ENDPOINT
  cert="/etc/letsencrypt/live/${DOWNLOAD_DOMAIN}/fullchain.pem"
  key="/etc/letsencrypt/live/${DOWNLOAD_DOMAIN}/privkey.pem"
  command -v python3 > /dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=120 install -y -qq python3 > /dev/null
  command -v openssl > /dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=120 install -y -qq openssl > /dev/null
  if [[ ! -s $key ]] || ! openssl x509 -in "$cert" -noout -checkend 86400 > /dev/null 2>&1; then
    command -v certbot > /dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=120 install -y -qq certbot > /dev/null
    PORT=""
    pick_port
    while [[ $PORT == "$DOWNLOAD_PORT" ]]; do PORT=""; pick_port; done
    acme_port=$PORT
    nat="PREROUTING -p tcp --dport 80 -m comment --comment game-setup-acme -j REDIRECT --to-ports ${acme_port}"
    input="INPUT -p tcp --dport ${acme_port} -m conntrack --ctorigdstport 80 -m comment --comment game-setup-acme -j ACCEPT"
    say "Getting an HTTPS certificate for ${DOWNLOAD_DOMAIN}; DNS must point here and provider TCP/80 must be open."
    say "Temporary forwarding: TCP/80 -> ${acme_port}. No game service listens on 80/443; HTTP traffic on 80 is diverted during validation."
    # Redirect only during validation, so nginx/other services keep their port and config.
    certbot certonly --standalone --http-01-port "$acme_port" --preferred-challenges http \
      --non-interactive --agree-tos --register-unsafely-without-email --cert-name "$DOWNLOAD_DOMAIN" -d "$DOWNLOAD_DOMAIN" \
      --pre-hook "iptables -t nat -C $nat 2>/dev/null || iptables -t nat -I $nat || exit 1; iptables -C $input 2>/dev/null || iptables -I $input" \
      --post-hook "iptables -t nat -D $nat; iptables -D $input" ||
      die "HTTPS certificate failed. Check the domain's A/AAAA records and provider TCP/80, then retry with --download."
    systemctl enable --now certbot.timer > /dev/null 2>&1
  fi
  umask 077
  install -d -m 700 "$GS_DIR"
  download_python > "$DOWNLOAD_SCRIPT"
  printf 'DOWNLOAD_DOMAIN=%q\nDOWNLOAD_PORT=%q\n' "$DOWNLOAD_DOMAIN" "$DOWNLOAD_PORT" > "$DOWNLOAD_ENV"
  cat > "$DOWNLOAD_UNIT_FILE" <<UNIT
[Unit]
Description=24-hour HTTPS game config downloads
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${DOWNLOAD_SCRIPT} ${GS_DIR} ${DOWNLOAD_PORT} ${cert} ${key}
Restart=on-failure
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNIT
  open_port "${DOWNLOAD_PORT}/tcp"
  systemctl daemon-reload
  systemctl enable "$DOWNLOAD_UNIT" > /dev/null 2>&1
  systemctl restart "$DOWNLOAD_UNIT"
  say "HTTPS downloads: ${DOWNLOAD_DOMAIN}:${DOWNLOAD_PORT}. Open TCP/${DOWNLOAD_PORT} in the provider firewall too."
}

cmd_download() {
  [[ -n $NAME && -f ${CLIENTS_DIR}/${NAME}.conf ]] || die "Usage: gamectl download <existing player>"
  if [[ $DOWNLOAD == 1 ]]; then
    load_state
    setup_downloads
  fi
  [[ -f $DOWNLOAD_ENV ]] || die "Enable downloads first: bash game-setup.sh repair --domain game.example.com --download"
  local DOWNLOAD_PORT path
  . "$DOWNLOAD_ENV"
  systemctl is-active --quiet "$DOWNLOAD_UNIT" || die "Downloads are down: systemctl restart ${DOWNLOAD_UNIT}"
  path=$(python3 "$DOWNLOAD_SCRIPT" "$GS_DIR" issue "$NAME")
  say "Download for ${NAME} (expires in 24 hours; previous link revoked):"
  printf 'https://%s:%s/%s\n' "$DOWNLOAD_DOMAIN" "$DOWNLOAD_PORT" "$path"
}

save_state() {
  printf 'PORT=%q\nNET=%q\nENDPOINT=%q\nDNS=%q\nMTU=%q\nBRIDGE=%q\n' "$PORT" "$NET" "$ENDPOINT" "$DNS" "$MTU" "$BRIDGE" > "$STATE_FILE"
}

cmd_repair() {
  [[ -f $SERVER_CONF || -f $LINK_CONF ]] || die "Nothing is installed."
  local endpoint=$ENDPOINT conf unit rules tmp wan f TOKEN=""
  umask 077
  if [[ -f $SERVER_CONF ]]; then
    load_state
    [[ -z $endpoint ]] || ENDPOINT=$endpoint
    player_options
    endpoint=$ENDPOINT
  fi
  wan=$(wan_iface)
  [[ -n $wan ]] || die "No default IPv4 route found."
  enable_forwarding
  for conf in "$LINK_CONF" "$SERVER_CONF"; do
    [[ -f $conf ]] || continue
    if [[ $conf == "$LINK_CONF" ]]; then
      grep -qxF 'Table = off' "$conf" && continue # Iran's policy-routing hooks are kept.
      . "$LINK_ENV"
      read_token "$TOKEN"
      rules=$(post_rules "$NET" "$wan")
      unit=$LINK_UNIT
    else
      load_state
      [[ -z $endpoint ]] || ENDPOINT=$endpoint
      if [[ $BRIDGE == 1 ]]; then
        rules=$(post_rules)
      else
        rules=$(post_rules "$NET" "$wan")
      fi
      unit=$UNIT
    fi
    tmp=$(mktemp "${conf}.XXXX")
    awk -v rules="$rules" '
      /^(PostUp|PostDown) = .*--comment game-setup/ {next}
      {print}
      /^\[Interface\]$/ {print rules}
    ' "$conf" > "$tmp"
    chmod 600 "$tmp"
    cp -p "$conf" "${conf}.bak"
    systemctl stop "$unit" # Old PostDown must run before replacing its rules.
    mv "$tmp" "$conf"
    if ! systemctl start "$unit"; then
      cp -p "${conf}.bak" "$conf"
      systemctl start "$unit" || true
      die "Repair failed; restored ${conf}. Check: journalctl -u ${unit}"
    fi
  done
  if [[ -f $SERVER_CONF ]]; then
    [[ $BRIDGE != 1 ]] || systemctl restart "$LINK_UNIT"
    save_state
    for f in "$CLIENTS_DIR"/*.conf; do
      [[ -f $f ]] || continue
      sed -i "s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, ::/0|; s|^Endpoint = .*|Endpoint = ${ENDPOINT}:${PORT}|" "$f"
    done
    if [[ $DOWNLOAD == 1 || -f $DOWNLOAD_ENV ]]; then setup_downloads; fi
  fi
  install_self
  say "Repaired; player keys kept. Re-import the updated client configs (gamectl show <name>)."
}

write_client() { # <name> <ip> <private key> <psk>
  local pub
  pub=$(sed -n 's/^PrivateKey = //p' "$SERVER_CONF" | awg pubkey)
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = %s\nMTU = %s\n' "$3" "$2" "$DNS" "$MTU"
    grep -E '^(Jc|Jmin|Jmax|S1|S2|H[1-4]) = ' "$SERVER_CONF"
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\n' "$pub" "$4" "$ENDPOINT" "$PORT"
    # IPv6 has no server egress: capture it too so clients fall back to the tunneled IPv4.
    printf 'AllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n'
  } > "${CLIENTS_DIR}/$1.conf"
}

cmd_add() {
  [[ -n $NAME ]] || die "Usage: gamectl add <name>"
  load_state
  valid_domain "$ENDPOINT" || die "Set the player domain first: bash game-setup.sh repair --domain game.example.com"
  [[ ! -f ${CLIENTS_DIR}/${NAME}.conf ]] || die "Player ${NAME} already exists (gamectl show ${NAME})"
  local ip priv psk
  ip=$(next_ip)
  priv=$(awg genkey)
  psk=$(awg genpsk)
  umask 077
  printf '\n[Peer]\n# %s\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
    "$NAME" "$(awg pubkey <<< "$priv")" "$psk" "$ip" >> "$SERVER_CONF"
  write_client "$NAME" "$ip" "$priv" "$psk"
  reload
  say "Added player ${NAME} (${ip})"
  cmd_show
}

cmd_remove() {
  [[ -n $NAME ]] || die "Usage: gamectl remove <name>"
  load_state
  [[ -f ${CLIENTS_DIR}/${NAME}.conf ]] || die "No player named ${NAME}"
  local tmp
  tmp=$(mktemp "${SERVER_CONF}.XXXX")
  drop_peer "$NAME" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SERVER_CONF"
  rm -f "${CLIENTS_DIR}/${NAME}.conf"
  rm -f "${GS_DIR}/downloads/${NAME}.json"
  reload
  say "Removed player ${NAME}"
}

cmd_show() {
  [[ -n $NAME ]] || die "Usage: gamectl show <name>"
  local f="${CLIENTS_DIR}/${NAME}.conf"
  [[ -f $f ]] || die "No player named ${NAME}"
  printf '\n----- %s -----\n' "$f"
  cat "$f"
  printf -- '-----\n\n'
  qrencode -t ansiutf8 < "$f" || true
  say "Import ${f} into AmneziaVPN / AmneziaWG, or scan the QR code."
  [[ ! -f $DOWNLOAD_ENV ]] || DOWNLOAD=0 cmd_download
}

cmd_list() {
  load_state
  local hs f name ip pub t
  hs=$(awg show "$IFACE" latest-handshakes 2> /dev/null || true)
  printf '%-20s %-15s %s\n' PLAYER IP LAST-HANDSHAKE
  for f in "$CLIENTS_DIR"/*.conf; do
    [[ -e $f ]] || continue
    name=$(basename "$f" .conf)
    ip=$(sed -n 's/^Address = \(.*\)\/32$/\1/p' "$f")
    pub=$(sed -n 's/^PrivateKey = //p' "$f" | awg pubkey)
    t=$(awk -v k="$pub" '$1 == k {print $2}' <<< "$hs")
    if [[ -z $t || $t == 0 ]]; then t=never; else t="$(($(date +%s) - t))s ago"; fi
    printf '%-20s %-15s %s\n' "$name" "$ip" "$t"
  done
}

cmd_status() {
  [[ -f $LINK_CONF || -f $SERVER_CONF ]] || die "Nothing is installed. Run: bash game-setup.sh --help"
  if [[ -f $FT_UNIT_FILE ]]; then
    systemctl --no-pager status "$FT_UNIT" | head -n 3 || true
  fi
  if [[ -f $LINK_CONF ]]; then
    [[ $(sed -n 's/^LINK_UDP=//p' "$LINK_ENV" 2> /dev/null) ]] && NAME="" cmd_mode
    systemctl --no-pager status "$LINK_UNIT" | head -n 3 || true
    awg show "$LINK_IFACE" || warn "Interface ${LINK_IFACE} is down: systemctl restart ${LINK_UNIT}"
  fi
  if [[ -f $SERVER_CONF ]]; then
    systemctl --no-pager status "$UNIT" | head -n 3 || true
    awg show "$IFACE" || warn "Interface ${IFACE} is down: systemctl restart ${UNIT}"
    load_state
    say "Player route (must use ${LINK_IFACE} on Iran):"
    ip -4 route get 1.1.1.1 from "${NET}.2" iif "$IFACE" || true
    say "Internet exit from the player subnet (ip / country):"
    curl -4 -fsS --max-time 10 --interface "${NET}.1" https://1.1.1.1/cdn-cgi/trace |
      awk -F= '$1 == "ip" || $1 == "loc" {print}' || warn "Player-subnet internet check failed; a handshake alone is not enough."
  fi
  [[ ! -f $DOWNLOAD_ENV ]] || systemctl --no-pager status "$DOWNLOAD_UNIT" | head -n 3 || true
}

# Iran: point awg-link at the kharej directly (UDP) or at the local phantun (fake TCP).
# The kharej takes both on the same port and answers wherever the last packet came from,
# and the session keys stay, so players are not dropped.
cmd_mode() {
  [[ -f $LINK_ENV && -f $LINK_CONF ]] || die "No link here. gamectl mode runs on the Iran server of the link."
  local LINK_KPUB="" LINK_UDP="" LINK_FT="" ep cur i ok=0
  . "$LINK_ENV"
  [[ -n $LINK_UDP ]] || die "This is the kharej end of the link; switch the route on the Iran server."
  cur=$(sed -n 's/^Endpoint = //p' "$LINK_CONF")
  case $NAME in
    "")
      printf 'Link route: %s (%s)\n' "$([[ $cur == "$LINK_UDP" ]] && echo udp || echo faketcp)" "$cur"
      [[ -n $LINK_FT ]] || say "Fake TCP is not available on this link (set it up again with a newer game-setup.sh)."
      return 0
      ;;
    udp) ep=$LINK_UDP ;;
    faketcp)
      [[ -n $LINK_FT ]] || die "This link has no fake TCP. Set it up again with a newer game-setup.sh (gamectl uninstall on both servers, then link / bridge)."
      ep=$LINK_FT
      systemctl is-active --quiet "$FT_UNIT" || systemctl restart "$FT_UNIT" || die "${FT_UNIT} is not running: journalctl -u ${FT_UNIT}"
      ;;
    *) die "Usage: gamectl mode [udp|faketcp]" ;;
  esac
  awg set "$LINK_IFACE" peer "$LINK_KPUB" endpoint "$ep"
  sed -i "s|^Endpoint = .*|Endpoint = ${ep}|" "$LINK_CONF" # kept across restarts
  say "Link route: ${NAME} (${ep}). Checking the kharej end ..."
  for i in $(seq 8); do # fake TCP opens its connection on the first packet, so give it a few tries
    ping -c 1 -W 2 "${LINK_NET}.1" > /dev/null 2>&1 && { ok=1; break; }
  done
  if [[ $ok == 1 ]]; then
    say "The kharej answers over ${NAME} (try ${i})."
  else
    warn "No answer from the kharej over ${NAME}. Switch back with: gamectl mode $([[ $NAME == udp ]] && echo faketcp || echo udp)"
    return 1
  fi
}

cmd_link() { # kharej: server end of the link; the players' subnet from Iran leaves to the internet here
  if [[ -f $LINK_ENV ]]; then
    . "$LINK_ENV"
    [[ -n ${TOKEN:-} ]] || die "This is the Iran end of the link. Switch its route with: gamectl mode udp|faketcp"
    say "The link is already set up. Run this on the IRAN server (keep the token private):"
    printf '\n  bash game-setup.sh bridge --token %s\n\n' "$TOKEN"
    return 0
  fi
  [[ $SUBNET_SET == 1 ]] || NET=$BRIDGE_NET
  # fake TCP is offered next to UDP whenever phantun runs here, so Iran can switch later
  local ftok=0
  [[ -n ${PHANTUN_SHA[$(uname -m)]:-} ]] && ftok=1
  [[ $FAKETCP == 0 || $ftok == 1 ]] || die "Fake TCP (phantun) is set up for x86_64 and aarch64 only (this server: $(uname -m))."
  [[ $ftok == 0 ]] || LINK_MTU=$FT_MTU # one MTU that fits both routes, so switching needs no restart
  install_awg
  [[ $ftok == 0 ]] || install_phantun
  subnet_free "$LINK_NET" || die "${LINK_NET}.0/30 is already used on this server."
  subnet_free "$NET" || die "${NET}.0/24 is already used on this server. Pick another --subnet."
  pick_port
  local wan kpriv ipriv psk junk
  wan=$(wan_iface)
  [[ -n $wan ]] || die "No default IPv4 route found."
  [[ -n $ENDPOINT ]] || ENDPOINT=$(public_ipv4)
  [[ -n $ENDPOINT ]] || die "Could not detect the public IPv4; pass --endpoint."
  kpriv=$(awg genkey)
  ipriv=$(awg genkey)
  psk=$(awg genpsk)
  junk=$(gen_junk)

  say "Writing ${LINK_CONF} (UDP ${PORT}, players ${NET}.0/24 out via ${wan})"
  umask 077
  install -d -m 700 "$AWG_DIR" "$GS_DIR"
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s.1/30\nListenPort = %s\nMTU = %s\n%s\n' \
      "$kpriv" "$LINK_NET" "$PORT" "$LINK_MTU" "$junk"
    post_rules "$NET" "$wan"
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s.2/32, %s.0/24\n' \
      "$(awg pubkey <<< "$ipriv")" "$psk" "$LINK_NET" "$NET"
  } > "$LINK_CONF"
  enable_forwarding
  local ports="${PORT}/udp" c="-m comment --comment game-setup"
  open_port "${PORT}/udp"
  if [[ $ftok == 1 ]]; then # Iran's fake TCP on PORT is DNATed to phantun, which hands the UDP to awg-link
    ports+=" and ${PORT}/tcp"
    open_port "${PORT}/tcp"
    ft_unit "/usr/local/bin/phantun_server --local ${PORT} --remote 127.0.0.1:${PORT} --tun ${FT_IFACE} --tun-local ${FT_KH}.1 --tun-peer ${FT_KH}.2 --ipv4-only" \
      "nat PREROUTING -i ${wan} -p tcp --dport ${PORT} $c -j DNAT --to-destination ${FT_KH}.2" \
      "filter FORWARD -i ${FT_IFACE} $c -j ACCEPT" "filter FORWARD -o ${FT_IFACE} $c -j ACCEPT"
    start_phantun
  fi
  systemctl enable --now "$LINK_UNIT" > /dev/null 2>&1 || die "${LINK_UNIT} did not start: journalctl -u ${LINK_UNIT}"
  TOKEN=$(make_token "$ENDPOINT" "$PORT" "$(awg pubkey <<< "$kpriv")" "$ipriv" "$psk" "$NET" "$junk" "$FAKETCP" "$ftok")
  printf 'LINK_PORT=%q\nTOKEN=%q\n' "$PORT" "$TOKEN" > "$LINK_ENV"
  install_self

  say "Link ready on ${ENDPOINT}: ${ports}. Open them in the kharej provider's firewall too."
  [[ $ftok == 0 ]] || say "Iran starts on $([[ $FAKETCP == 1 ]] && echo 'fake TCP' || echo UDP) and can switch with: gamectl mode udp|faketcp"
  say "Now run this on the IRAN server (the token holds Iran's key: keep it private):"
  printf '\n  bash game-setup.sh bridge --token %s\n\n' "$TOKEN"
}

cmd_bridge() { # Iran: client end of the link + the players' server; only the players' subnet uses the link
  [[ -n $TOKEN_IN ]] || die "Usage: bash game-setup.sh bridge --token <token from 'gamectl link' on the kharej>"
  [[ ! -f $LINK_CONF && ! -f $SERVER_CONF ]] || die "game-setup is already installed here (gamectl status). Run gamectl uninstall first."
  player_options
  read_token "$TOKEN_IN"
  install_awg
  subnet_free "$LINK_NET" || die "${LINK_NET}.0/30 is already used on this server."
  local udp_ep="${T_KH}:${T_LPORT}" ft_ep="" endpoint lp wan wait=15 c="-m comment --comment game-setup"
  endpoint=$udp_ep
  if [[ $T_FTOK == 1 ]]; then # awg-link talks UDP to the local phantun client, which carries it to the kharej as fake TCP
    LINK_MTU=$FT_MTU
    install_phantun
    wan=$(wan_iface)
    [[ -n $wan ]] || die "No default IPv4 route found."
    lp=$(shuf -i 20000-60000 -n 1)
    while port_busy "$lp"; do lp=$(shuf -i 20000-60000 -n 1); done
    ft_unit "/usr/local/bin/phantun_client --local 127.0.0.1:${lp} --remote ${T_KH}:${T_LPORT} --tun ${FT_IFACE} --tun-local ${FT_IR}.1 --tun-peer ${FT_IR}.2 --ipv4-only" \
      "nat POSTROUTING -s ${FT_IR}.2 -o ${wan} $c -j MASQUERADE" \
      "filter FORWARD -i ${FT_IFACE} $c -j ACCEPT" "filter FORWARD -o ${FT_IFACE} $c -j ACCEPT"
    enable_forwarding
    start_phantun
    ft_ep="127.0.0.1:${lp}"
    [[ $T_FT == 0 ]] || { endpoint=$ft_ep; wait=30; }
    say "Fake TCP to ${T_KH}:${T_LPORT}/tcp ready (phantun, local UDP ${lp})"
  fi

  say "Writing ${LINK_CONF} (to ${T_KH}:${T_LPORT} over $([[ $endpoint == "$ft_ep" ]] && echo 'fake TCP' || echo UDP))"
  umask 077
  install -d -m 700 "$AWG_DIR" "$GS_DIR"
  printf 'LINK_KPUB=%q\nLINK_UDP=%q\nLINK_FT=%q\n' "$T_KPUB" "$udp_ep" "$ft_ep" > "$LINK_ENV" # for gamectl mode
  local p=$LINK_TABLE hs=0
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s.2/30\nMTU = %s\nTable = off\n%s\n' \
      "$T_IPRIV" "$LINK_NET" "$LINK_MTU" "$T_JUNK"
    # loose rp_filter: replies from the internet arrive on the link, not on the default route
    printf 'PostUp = sysctl -qw net.ipv4.conf.%%i.rp_filter=2; ip route replace default dev %%i table %s\n' "$p"
    printf 'PostUp = ip rule add from %s.0/24 to %s.0/24 lookup main priority %s; ip rule add from %s.0/24 lookup %s priority %s\n' \
      "$NET" "$NET" "$((p - 1))" "$NET" "$p" "$p"
    printf 'PostDown = ip rule del priority %s; ip rule del priority %s; ip route flush table %s\n' "$p" "$((p - 1))" "$p"
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
      "$T_KPUB" "$T_PSK" "$endpoint"
  } > "$LINK_CONF"
  enable_forwarding
  systemctl enable --now "$LINK_UNIT" > /dev/null 2>&1 || die "${LINK_UNIT} did not start: journalctl -u ${LINK_UNIT}"

  say "Waiting for the link handshake with the kharej"
  for _ in $(seq "$wait"); do
    hs=$(awg show "$LINK_IFACE" latest-handshakes | awk '{print $2}')
    [[ ${hs:-0} != 0 ]] && break
    sleep 1
  done
  if [[ ${hs:-0} != 0 ]]; then
    say "Link is up."
  else
    if [[ $T_FT == 1 ]]; then
      warn "No handshake with ${T_KH}:${T_LPORT} over fake TCP yet (TCP port closed on the kharej, or filtered)."
      warn "Logs: journalctl -u ${FT_UNIT} (both servers). Try UDP: gamectl mode udp"
    else
      warn "No handshake with ${T_KH}:${T_LPORT} yet (UDP blocked on the way, or the kharej firewall)."
      if [[ $T_FTOK == 1 ]]; then
        warn "If UDP is blocked, switch the link to fake TCP: gamectl mode faketcp"
      else
        warn "If UDP is blocked: gamectl uninstall on both servers, then on the kharej: bash game-setup.sh link --faketcp"
      fi
    fi
    warn "Players can connect, but get no internet until it works. Check: gamectl status"
  fi

  BRIDGE=1
  do_install
}

cmd_uninstall() {
  if [[ $YES != 1 ]]; then
    local a=""
    [[ -r /dev/tty ]] && read -rp "Remove game-setup from this server (players, link, rules)? [y/N] " a < /dev/tty
    [[ $a =~ ^[Yy] ]] || die "Cancelled."
  fi
  local LINK_PORT=""
  local DOWNLOAD_PORT=""
  [[ -f $STATE_FILE ]] && . "$STATE_FILE"
  [[ -f $LINK_ENV ]] && . "$LINK_ENV"
  [[ -f $DOWNLOAD_ENV ]] && . "$DOWNLOAD_ENV"
  # PostDown removes the NAT, forward and routing rules
  systemctl disable --now "$UNIT" > /dev/null 2>&1 || true
  systemctl disable --now "$LINK_UNIT" > /dev/null 2>&1 || true
  systemctl disable --now "$FT_UNIT" > /dev/null 2>&1 || true # ExecStopPost removes its NAT rules
  systemctl disable --now "$DOWNLOAD_UNIT" > /dev/null 2>&1 || true
  [[ -n $PORT ]] && close_port "${PORT}/udp"
  [[ -n $LINK_PORT ]] && close_port "${LINK_PORT}/udp" && close_port "${LINK_PORT}/tcp"
  [[ -n $DOWNLOAD_PORT ]] && close_port "${DOWNLOAD_PORT}/tcp"
  rm -rf "$GS_DIR" "$SERVER_CONF" "$LINK_CONF" "$SYSCTL_FILE" /usr/local/bin/gamectl /usr/local/sbin/game-setup
  rm -f "${SERVER_CONF}.bak" "${LINK_CONF}.bak" "$FT_UNIT_FILE" "$DOWNLOAD_UNIT_FILE" /usr/local/bin/phantun_client /usr/local/bin/phantun_server
  systemctl daemon-reload
  say "Removed. The amneziawg packages and the PPA stay installed."
}

install_self() {
  local src
  src=$(readlink -f "$0" 2> /dev/null || printf '%s' "$0")
  case $src in
    /dev/fd/* | /proc/* | /dev/stdin | pipe:*)
      src=$(mktemp)
      if ! curl -fsSL --max-time 60 -o "$src" "$SELF_URL" || ! bash -n "$src" 2> /dev/null; then
        warn "Could not download ${SELF_URL}; gamectl was not installed (use: bash game-setup.sh <command>)."
        return 0
      fi
      ;;
  esac
  [[ -f $src ]] || return 0
  [[ $src == /usr/local/sbin/game-setup ]] || install -m 755 "$src" /usr/local/sbin/game-setup
  ln -sf /usr/local/sbin/game-setup /usr/local/bin/gamectl
}

do_install() { # the players' server; BRIDGE=1 (Iran) sends their traffic into the link instead of NAT
  if [[ -f $SERVER_CONF ]]; then
    if [[ -n $ENDPOINT || $DOWNLOAD == 1 ]]; then cmd_repair; return 0; fi
    say "Already installed. Manage players with: gamectl add|remove|show|list|status"
    cmd_list
    return 0
  fi
  if [[ $BRIDGE != 1 ]]; then player_options; install_awg; fi
  pick_port
  subnet_free "$NET" || die "${NET}.0/24 is already used on this server. Pick another --subnet."
  local wan
  wan=$(wan_iface)
  [[ -n $wan ]] || die "No default IPv4 route found."

  say "Writing ${SERVER_CONF} (UDP ${PORT}, players ${NET}.0/24)"
  umask 077
  install -d -m 700 "$AWG_DIR" "$GS_DIR" "$CLIENTS_DIR"
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s.1/24\nListenPort = %s\nMTU = %s\n' \
      "$(awg genkey)" "$NET" "$PORT" "$MTU"
    gen_junk
    if [[ $BRIDGE == 1 ]]; then post_rules; else post_rules "$NET" "$wan"; fi
  } > "$SERVER_CONF"
  save_state

  enable_forwarding
  open_port "${PORT}/udp"
  systemctl enable --now "$UNIT" > /dev/null 2>&1 || die "${UNIT} did not start: journalctl -u ${UNIT}"
  awg show "$IFACE" > /dev/null || die "Interface ${IFACE} is not up: journalctl -u ${UNIT}"
  install_self
  [[ $DOWNLOAD == 0 ]] || setup_downloads

  NAME=player1
  cmd_add
  printf '\n'
  say "Players connect to ${ENDPOINT}:${PORT}/udp. Open this UDP port in the provider's firewall too."
  [[ $BRIDGE == 1 ]] && say "Their traffic goes through the link and leaves from the kharej."
  say "More players: gamectl add <name>   (list | show | remove | status)"
}

main() {
  parse_args "$@"
  [[ $CMD == help ]] && { usage; return 0; }
  [[ $EUID -eq 0 ]] || die "Run as root (sudo -i first)."
  trap '_on_err $LINENO' ERR
  case ${CMD:-install} in
    install | link | bridge)
      touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
      exec > >(tee -a "$LOG_FILE") 2>&1
      if [[ ${CMD:-install} == install ]]; then do_install; else "cmd_${CMD}"; fi
      ;;
    add | remove | show | list | status | mode | repair | download | uninstall) "cmd_${CMD}" ;;
    *) die "Unknown command: ${CMD} (see --help)" ;;
  esac
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi # also when piped to bash
