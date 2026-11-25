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
#                   kharej: bash game-setup.sh
#    through Iran players -> Iran -> awg-link -> kharej -> internet
#                   kharej: bash game-setup.sh link      (prints a token)
#                   Iran:   bash game-setup.sh bridge --token <token>
#                 Players connect to the Iran server (their leg stays
#                 domestic); only their subnet is routed into the link, and
#                 the kharej NATs it out to the internet.
#
#  Usage:
#    bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/game-setup.sh)
#    gamectl add ali | remove ali | show ali | list | status | uninstall
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
SYSCTL_FILE="/etc/sysctl.d/99-game-setup.conf"
LOG_FILE="/var/log/game-setup.log"
PPA_URL="https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu"
KEYRING="/etc/apt/keyrings/amnezia-ppa.gpg"

CMD=""
NAME=""
PORT=""
NET="10.66.66" # players' /24, first three octets
BRIDGE_NET="10.68.68" # players' /24 in the Iran layout, so it never clashes with a direct server
SUBNET_SET=0
ENDPOINT=""
TOKEN_IN=""
BRIDGE=0
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
                          for `link` it is the link port on the kharej
      --endpoint <host>   address players (or Iran, for `link`) connect to
                          (default: this server's public IPv4)
      --subnet <a.b.c>    players' /24, first three octets
                          (default: 10.66.66 direct, 10.68.68 through Iran)
      --dns "<ip>, <ip>"  DNS for players (default: 1.1.1.1, 8.8.8.8)
      --token <t>         for `bridge`: the token `link` printed on the kharej
  -h, --help              show this help

Commands (same as gamectl):
  add <name>          new player: config file + QR code
  remove <name>       delete a player
  show <name>         print a player's config and QR code again
  list                players, their IPs and last handshake
  status              link and player server state (awg show)
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) PORT=${2:?}; shift 2 ;;
      --endpoint) ENDPOINT=${2:?}; shift 2 ;;
      --subnet) NET=${2:?}; SUBNET_SET=1; shift 2 ;;
      --dns) DNS=${2:?}; shift 2 ;;
      --token) TOKEN_IN=${2:?}; shift 2 ;;
      --yes) YES=1; shift ;;
      -h | --help) CMD=help; shift ;;
      -*) die "Unknown option: $1 (see --help)" ;;
      *) if [[ -z $CMD ]]; then CMD=$1; else NAME=$1; fi; shift ;;
    esac
  done
  [[ -z $PORT ]] || valid_port "$PORT" || die "Invalid port: $PORT"
  [[ $NET =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "Invalid subnet (want three octets, e.g. 10.66.66): $NET"
  [[ -z $ENDPOINT || $ENDPOINT =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid endpoint: $ENDPOINT"
  [[ $DNS =~ ^[0-9a-fA-F.:,\ ]+$ ]] || die "Invalid DNS list: $DNS"
  [[ -z $TOKEN_IN || $TOKEN_IN =~ ^[A-Za-z0-9+/=]+$ ]] || die "Invalid token (copy it again from the kharej)"
  [[ -z $NAME || $NAME =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "Player names: letters, digits, _ and -, up to 32"
  return 0
}

port_busy() { ss -Htuln 2> /dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }

pick_port() { # keeps a free --port, else picks a random free one
  if [[ -n $PORT ]]; then
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
  if [[ $# -eq 2 ]]; then
    local nat="POSTROUTING -s $1.0/24 -o $2 $c -j MASQUERADE"
    up+="; iptables -t nat -A $nat"
    down+="; iptables -t nat -D $nat"
  fi
  printf 'PostUp = %s\nPostDown = %s\n' "$up" "$down"
}

# The kharej hands Iran everything for its end of the link in one token, so no SSH is needed.
make_token() { # <kharej-host> <link-port> <kharej-pub> <iran-priv> <psk> <players-net> <junk lines>
  printf 'KH=%s\nLPORT=%s\nKPUB=%s\nIPRIV=%s\nPSK=%s\nNET=%s\n%s\n' "$@" | base64 -w0
}

read_token() { # <token>: sets T_KH T_LPORT T_KPUB T_IPRIV T_PSK T_JUNK and NET, or dies
  local t key='^[A-Za-z0-9+/]{43}=$'
  t=$(base64 -d <<< "$1" 2> /dev/null) || die "The token is broken; copy it again from the kharej (gamectl link)."
  T_KH=$(sed -n 's/^KH=//p' <<< "$t")
  T_LPORT=$(sed -n 's/^LPORT=//p' <<< "$t")
  T_KPUB=$(sed -n 's/^KPUB=//p' <<< "$t")
  T_IPRIV=$(sed -n 's/^IPRIV=//p' <<< "$t")
  T_PSK=$(sed -n 's/^PSK=//p' <<< "$t")
  NET=$(sed -n 's/^NET=//p' <<< "$t")
  T_JUNK=$(grep -E '^(Jc|Jmin|Jmax|S1|S2|H[1-4]) = [0-9]+$' <<< "$t" || true)
  [[ $T_KH =~ ^[A-Za-z0-9.-]+$ ]] && valid_port "$T_LPORT" &&
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
}

reload() { awg syncconf "$IFACE" <(awg-quick strip "$IFACE"); } # apply peers without dropping anyone

public_ipv4() {
  local url ip
  for url in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
    ip=$(curl -4 -fsS --max-time 8 "$url" 2> /dev/null | tr -d '[:space:]') || continue
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
  done
  ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}'
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
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq "linux-headers-$(uname -r)" > /dev/null ||
    die "Could not install linux-headers-$(uname -r). AmneziaWG needs a KVM/dedicated VPS with its distribution kernel (not OpenVZ/LXC)."
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

write_client() { # <name> <ip> <private key> <psk>
  local pub
  pub=$(sed -n 's/^PrivateKey = //p' "$SERVER_CONF" | awg pubkey)
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = %s\nMTU = %s\n' "$3" "$2" "$DNS" "$MTU"
    grep -E '^(Jc|Jmin|Jmax|S1|S2|H[1-4]) = ' "$SERVER_CONF"
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\n' "$pub" "$4" "$ENDPOINT" "$PORT"
    printf 'AllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n'
  } > "${CLIENTS_DIR}/$1.conf"
}

cmd_add() {
  [[ -n $NAME ]] || die "Usage: gamectl add <name>"
  load_state
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
  if [[ -f $LINK_CONF ]]; then
    systemctl --no-pager status "$LINK_UNIT" | head -n 3 || true
    awg show "$LINK_IFACE" || warn "Interface ${LINK_IFACE} is down: systemctl restart ${LINK_UNIT}"
  fi
  if [[ -f $SERVER_CONF ]]; then
    systemctl --no-pager status "$UNIT" | head -n 3 || true
    awg show "$IFACE" || warn "Interface ${IFACE} is down: systemctl restart ${UNIT}"
  fi
}

cmd_link() { # kharej: server end of the link; the players' subnet from Iran leaves to the internet here
  if [[ -f $LINK_ENV ]]; then
    . "$LINK_ENV"
    say "The link is already set up. Run this on the IRAN server (keep the token private):"
    printf '\n  bash game-setup.sh bridge --token %s\n\n' "$TOKEN"
    return 0
  fi
  [[ $SUBNET_SET == 1 ]] || NET=$BRIDGE_NET
  install_awg
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
  open_port "${PORT}/udp"
  systemctl enable --now "$LINK_UNIT" > /dev/null 2>&1 || die "${LINK_UNIT} did not start: journalctl -u ${LINK_UNIT}"
  TOKEN=$(make_token "$ENDPOINT" "$PORT" "$(awg pubkey <<< "$kpriv")" "$ipriv" "$psk" "$NET" "$junk")
  printf 'LINK_PORT=%q\nTOKEN=%q\n' "$PORT" "$TOKEN" > "$LINK_ENV"
  install_self

  say "Link ready on ${ENDPOINT}:${PORT}/udp. Open this UDP port in the kharej provider's firewall too."
  say "Now run this on the IRAN server (the token holds Iran's key: keep it private):"
  printf '\n  bash game-setup.sh bridge --token %s\n\n' "$TOKEN"
}

cmd_bridge() { # Iran: client end of the link + the players' server; only the players' subnet uses the link
  [[ -n $TOKEN_IN ]] || die "Usage: bash game-setup.sh bridge --token <token from 'gamectl link' on the kharej>"
  [[ ! -f $LINK_CONF && ! -f $SERVER_CONF ]] || die "game-setup is already installed here (gamectl status). Run gamectl uninstall first."
  read_token "$TOKEN_IN"
  install_awg
  subnet_free "$LINK_NET" || die "${LINK_NET}.0/30 is already used on this server."

  say "Writing ${LINK_CONF} (to ${T_KH}:${T_LPORT})"
  umask 077
  install -d -m 700 "$AWG_DIR" "$GS_DIR"
  local p=$LINK_TABLE hs=0
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s.2/30\nMTU = %s\nTable = off\n%s\n' \
      "$T_IPRIV" "$LINK_NET" "$LINK_MTU" "$T_JUNK"
    # loose rp_filter: replies from the internet arrive on the link, not on the default route
    printf 'PostUp = sysctl -qw net.ipv4.conf.%%i.rp_filter=2; ip route replace default dev %%i table %s\n' "$p"
    printf 'PostUp = ip rule add from %s.0/24 to %s.0/24 lookup main priority %s; ip rule add from %s.0/24 lookup %s priority %s\n' \
      "$NET" "$NET" "$((p - 1))" "$NET" "$p" "$p"
    printf 'PostDown = ip rule del priority %s; ip rule del priority %s; ip route flush table %s\n' "$p" "$((p - 1))" "$p"
    printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
      "$T_KPUB" "$T_PSK" "$T_KH" "$T_LPORT"
  } > "$LINK_CONF"
  enable_forwarding
  systemctl enable --now "$LINK_UNIT" > /dev/null 2>&1 || die "${LINK_UNIT} did not start: journalctl -u ${LINK_UNIT}"

  say "Waiting for the link handshake with the kharej"
  for _ in $(seq 15); do
    hs=$(awg show "$LINK_IFACE" latest-handshakes | awk '{print $2}')
    [[ ${hs:-0} != 0 ]] && break
    sleep 1
  done
  if [[ ${hs:-0} != 0 ]]; then
    say "Link is up."
  else
    warn "No handshake with ${T_KH}:${T_LPORT} yet (UDP blocked on the way, or the kharej firewall)."
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
  [[ -f $STATE_FILE ]] && . "$STATE_FILE"
  [[ -f $LINK_ENV ]] && . "$LINK_ENV"
  # PostDown removes the NAT, forward and routing rules
  systemctl disable --now "$UNIT" > /dev/null 2>&1 || true
  systemctl disable --now "$LINK_UNIT" > /dev/null 2>&1 || true
  [[ -n $PORT ]] && close_port "${PORT}/udp"
  [[ -n $LINK_PORT ]] && close_port "${LINK_PORT}/udp"
  rm -rf "$GS_DIR" "$SERVER_CONF" "$LINK_CONF" "$SYSCTL_FILE" /usr/local/bin/gamectl /usr/local/sbin/game-setup
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
  install -m 755 "$src" /usr/local/sbin/game-setup
  ln -sf /usr/local/sbin/game-setup /usr/local/bin/gamectl
}

do_install() { # the players' server; BRIDGE=1 (Iran) sends their traffic into the link instead of NAT
  if [[ -f $SERVER_CONF ]]; then
    say "Already installed. Manage players with: gamectl add|remove|show|list|status"
    cmd_list
    return 0
  fi
  [[ $BRIDGE == 1 ]] || install_awg
  pick_port
  subnet_free "$NET" || die "${NET}.0/24 is already used on this server. Pick another --subnet."
  local wan
  wan=$(wan_iface)
  [[ -n $wan ]] || die "No default IPv4 route found."
  [[ -n $ENDPOINT ]] || ENDPOINT=$(public_ipv4)
  [[ -n $ENDPOINT ]] || die "Could not detect the public IPv4; pass --endpoint."

  say "Writing ${SERVER_CONF} (UDP ${PORT}, players ${NET}.0/24)"
  umask 077
  install -d -m 700 "$AWG_DIR" "$GS_DIR" "$CLIENTS_DIR"
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s.1/24\nListenPort = %s\nMTU = %s\n' \
      "$(awg genkey)" "$NET" "$PORT" "$MTU"
    gen_junk
    if [[ $BRIDGE == 1 ]]; then post_rules; else post_rules "$NET" "$wan"; fi
  } > "$SERVER_CONF"
  printf 'PORT=%q\nNET=%q\nENDPOINT=%q\nDNS=%q\nMTU=%q\n' "$PORT" "$NET" "$ENDPOINT" "$DNS" "$MTU" > "$STATE_FILE"

  enable_forwarding
  open_port "${PORT}/udp"
  systemctl enable --now "$UNIT" > /dev/null 2>&1 || die "${UNIT} did not start: journalctl -u ${UNIT}"
  awg show "$IFACE" > /dev/null || die "Interface ${IFACE} is not up: journalctl -u ${UNIT}"
  install_self

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
    add | remove | show | list | status | uninstall) "cmd_${CMD}" ;;
    *) die "Unknown command: ${CMD} (see --help)" ;;
  esac
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi # also when piped to bash
