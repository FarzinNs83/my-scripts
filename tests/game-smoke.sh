#!/usr/bin/env bash
# Offline checks for game-setup.sh: arguments, junk parameters, peer bookkeeping.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source game-setup.sh

parse_args --domain game.example.com --download
[[ $ENDPOINT == game.example.com && $DOWNLOAD == 1 ]]
ENDPOINT="" DOWNLOAD=0
(
  CMD="" ROUTE_ARGS=()
  parse_args route add claude.ai chatgpt.com 203.0.113.0/24
  [[ $CMD == route && ${#ROUTE_ARGS[@]} == 4 && ${ROUTE_ARGS[3]} == 203.0.113.0/24 ]]
  CMD="" ROUTE_ARGS=()
  parse_args route import '/root/blocked domains.txt'
  [[ ${ROUTE_ARGS[1]} == '/root/blocked domains.txt' ]]
)
for domain in game.example.com a-b.example.co.uk; do valid_domain "$domain"; done
for domain in 198.51.100.1 localhost -bad.example.com bad-.example.com x..example.com 'x;y.com' "$(printf 'a%.0s' {1..64}).example.com"; do
  if valid_domain "$domain"; then echo "accepted domain: $domain" >&2; exit 1; fi
done

parse_args add ali --port 41234 --subnet 10.77.0
[[ $CMD == add && $NAME == ali && $PORT == 41234 && $NET == 10.77.0 ]]
CMD="" NAME="" PORT=""
parse_args bridge --token 'S0g9MQo+'
[[ $CMD == bridge && $TOKEN_IN == 'S0g9MQo+' ]]
for bad in "--port 0" "--port 65536" "--port 80" "--port 443" "--port 00080" "--port 00443" "--port 1;id" "--subnet 10.0" "add a/b" "--endpoint x;y" "--dns 1.1.1.1;id" \
  "bridge --token a;b" "bridge --token a\$(id)"; do
  CMD="" NAME="" TOKEN_IN=""
  # shellcheck disable=SC2086
  if (parse_args $bad) 2> /dev/null; then echo "accepted: $bad" >&2; exit 1; fi
done

for reserved in 80 443 00080 00443; do
  if (PORT=$reserved; pick_port) 2> /dev/null; then echo "reserved listener: $reserved" >&2; exit 1; fi
done

for _ in $(seq 50); do
  j=$(gen_junk)
  v() { sed -n "s/^$1 = //p" <<< "$j"; }
  (( $(v Jc) >= 1 && $(v Jc) <= 128 && $(v Jmin) < $(v Jmax) && $(v Jmax) <= 1280 ))
  (( $(v S1) + 56 != $(v S2) && $(v S1) <= 1132 && $(v S2) <= 1132 ))
  [[ $(printf '%s\n' "$(v H1)" "$(v H2)" "$(v H3)" "$(v H4)" | sort -u | wc -l) == 4 ]]
  (( $(v H1) > 4 && $(v H2) > 4 && $(v H3) > 4 && $(v H4) > 4 ))
done

SERVER_CONF=$(mktemp)
trap 'rm -f "$SERVER_CONF"' EXIT
NET=10.66.66
cat > "$SERVER_CONF" << 'EOF'
[Interface]
PrivateKey = x
Address = 10.66.66.1/24
PostUp = iptables -I FORWARD -i %i -j ACCEPT

[Peer]
# a
PublicKey = A
AllowedIPs = 10.66.66.2/32

[Peer]
# b
PublicKey = B
AllowedIPs = 10.66.66.3/32
EOF
[[ $(next_ip) == 10.66.66.4 ]]
out=$(drop_peer a)
grep -q 'PostUp = iptables' <<< "$out"
grep -q '^# b$' <<< "$out"
if grep -qE '^# a$|PublicKey = A' <<< "$out"; then echo 'peer a not removed' >&2; exit 1; fi
printf '%s\n' "$out" > "$SERVER_CONF"
[[ $(next_ip) == 10.66.66.2 ]]

# Token: what the kharej prints is exactly what Iran reads back
k1="$(printf 'A%.0s' {1..43})=" k2="$(printf 'B%.0s' {1..43})=" k3="$(printf 'C%.0s' {1..43})="
junk=$(gen_junk)
token=$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk")
NET=""
read_token "$token"
[[ $T_KH == 198.51.100.7 && $T_LPORT == 41234 && $T_KPUB == "$k1" && $T_IPRIV == "$k2" && $T_PSK == "$k3" ]]
[[ $NET == 10.68.68 && $T_JUNK == "$junk" && $T_FT == 0 && $T_FTOK == 0 ]] # no faketcp arguments: plain UDP link
read_token "$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk" 0 1)"
[[ $T_FT == 0 && $T_FTOK == 1 && $T_JUNK == "$junk" ]] # starts on UDP, can switch
read_token "$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk" 1 1)"
[[ $T_FT == 1 && $T_FTOK == 1 ]]
read_token "$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk" 1)"
[[ $T_FT == 1 && $T_FTOK == 1 ]] # a fake-TCP token from before FTOK
read_token "$(printf 'KH=198.51.100.7\nLPORT=41234\nKPUB=%s\nIPRIV=%s\nPSK=%s\nNET=10.68.68\n%s\n' "$k1" "$k2" "$k3" "$junk" | base64 -w0)"
[[ $T_FT == 0 && $T_FTOK == 0 ]] # a token from before --faketcp
for ft in "2 1" "1 0" "0 2"; do # bad values, or a fake-TCP start the kharej does not offer
  # shellcheck disable=SC2086
  if (read_token "$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk" $ft)") 2> /dev/null; then
    echo "accepted FT FTOK = $ft" >&2; exit 1
  fi
done
parse_args mode faketcp
[[ $CMD == mode && $NAME == faketcp ]]
CMD="" NAME=""
parse_args link --faketcp
[[ $CMD == link && $FAKETCP == 1 ]]

# Fake TCP unit: every rule is added before phantun starts and removed after it stops, as root
FT_UNIT_FILE=$(mktemp)
trap 'rm -f "$SERVER_CONF" "$FT_UNIT_FILE"' EXIT
iptables() { :; } # only command -v needs it
ft_unit "/usr/local/bin/phantun_server --local 41234" "nat PREROUTING -i eth0 -p tcp --dport 41234 -j DNAT --to-destination 10.67.68.2" \
  "filter FORWARD -i ft-link -j ACCEPT"
unset -f iptables
grep -qxF 'ExecStart=/usr/local/bin/phantun_server --local 41234' "$FT_UNIT_FILE"
grep -qE '^ExecStartPre=\+.* -t nat -I PREROUTING -i eth0 -p tcp --dport 41234 -j DNAT --to-destination 10\.67\.68\.2$' "$FT_UNIT_FILE"
grep -qE '^ExecStopPost=-\+.* -t filter -D FORWARD -i ft-link -j ACCEPT$' "$FT_UNIT_FILE"
[[ $(grep -c '^ExecStartPre=' "$FT_UNIT_FILE") == 4 && $(grep -c '^ExecStopPost=' "$FT_UNIT_FILE") == 2 ]]
grep -qxF 'AmbientCapabilities=CAP_NET_ADMIN' "$FT_UNIT_FILE"
for bad in "$(make_token 'x;y' 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk")" \
  "$(make_token 198.51.100.7 0 "$k1" "$k2" "$k3" 10.68.68 "$junk")" \
  "$(make_token 198.51.100.7 41234 short "$k2" "$k3" 10.68.68 "$junk")" \
  "$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$(head -n 8 <<< "$junk")")" \
  "not-base64!"; do
  if (read_token "$bad") 2> /dev/null; then echo "accepted a bad token" >&2; exit 1; fi
done

# The interface address is used unless it is private (then an outside lookup decides)
for ip in 10.0.0.5 172.16.1.1 172.31.9.9 192.168.1.10 100.64.0.1 100.127.255.1 127.0.0.1 169.254.1.1; do
  is_private_ipv4 "$ip" || { echo "not private: $ip" >&2; exit 1; }
done
for ip in 5.160.110.86 31.57.47.40 172.32.0.1 172.15.0.1 100.128.0.1 100.63.0.1 11.0.0.1; do
  if is_private_ipv4 "$ip"; then echo "private: $ip" >&2; exit 1; fi
done

# NAT only where traffic leaves for the internet (direct server, kharej link end)
rules=$(post_rules 10.68.68 eth0)
grep -qF 'iptables -t nat -A POSTROUTING -s 10.68.68.0/24 -o eth0 -m comment --comment game-setup -j MASQUERADE' <<< "$rules"
grep -qF 'iptables -t nat -D POSTROUTING -s 10.68.68.0/24 -o eth0' <<< "$rules"
rules=$(post_rules)
grep -qF 'PostUp = iptables -I FORWARD -i %i ' <<< "$rules"
if grep -q MASQUERADE <<< "$rules"; then echo 'NAT on the Iran player server' >&2; exit 1; fi
for direction in -i -o; do
  grep -qF -- "FORWARD $direction %i -p tcp --tcp-flags SYN,RST SYN -m comment --comment game-setup -j TCPMSS --set-mss 1240" <<< "$rules"
done
grep -qF "FORWARD -i %i ! -o awg-link ! -d $NET.0/24 -m comment --comment game-setup -j REJECT" <<< "$rules"
rules=$(post_rules 10.68.68 eth0)
if grep -q REJECT <<< "$rules"; then echo 'Iran guard on the internet exit' >&2; exit 1; fi

# Upgrade an existing bridge twice: keys survive, rules do not accumulate, clients get the domain.
(
  test_dir=$(mktemp -d)
  trap 'rm -rf "$test_dir"' EXIT
  GS_DIR=$test_dir CLIENTS_DIR=$test_dir/clients STATE_FILE=$test_dir/state.env
  SERVER_CONF=$test_dir/awg-game.conf LINK_CONF=$test_dir/awg-link.conf
  LINK_ENV=$test_dir/link.env
  DOWNLOAD_ENV=$test_dir/download.env
  IPSET_FILE=$test_dir/routes.ipset
  DNS_CACHE_FILE=$test_dir/dns-cache.ipset
  mkdir "$CLIENTS_DIR"
  NET=10.68.68 PORT=41234 ENDPOINT=198.51.100.8 DOWNLOAD=0
  save_state
  printf '[Interface]\nTable = off\n' > "$LINK_CONF"
  printf '[Interface]\nPrivateKey = server-key\n%s\n' "$junk" > "$SERVER_CONF"
  cat >> "$SERVER_CONF" <<'CONF'
PostUp = iptables -I FORWARD -i %i -m comment --comment game-setup -j ACCEPT
PostDown = iptables -D FORWARD -i %i -m comment --comment game-setup -j ACCEPT

[Peer]
# ali
PublicKey = player-key
AllowedIPs = 10.68.68.2/32
CONF
  awg() { cat > /dev/null; echo server-public-key; }
  write_client ali 10.68.68.2 player-private-key player-psk
  grep -qxF 'AllowedIPs = 0.0.0.0/0, ::/0' "$CLIENTS_DIR/ali.conf"
  sed -i 's|AllowedIPs = .*|AllowedIPs = 0.0.0.0/0|' "$CLIENTS_DIR/ali.conf"
  wan_iface() { echo eth0; }
  enable_forwarding() { :; }
  prepare_routing() { SPLIT=1 DNS_PORT=53001 DNS="${NET}.1" ROUTE_WAN=eth0 WAN_RPF=1; }
  install_self() { :; }
  systemctl() { printf '%s\n' "$*" >> "$test_dir/systemctl.log"; }
  ENDPOINT=game.example.com
  cmd_repair
  cmd_repair
  grep -qxF 'PrivateKey = server-key' "$SERVER_CONF"
  grep -qxF 'PublicKey = player-key' "$SERVER_CONF"
  grep -qxF 'AllowedIPs = 10.68.68.2/32' "$SERVER_CONF"
  [[ $(grep -c '^PostUp = ' "$SERVER_CONF") == 1 && $(grep -c '^PostDown = ' "$SERVER_CONF") == 1 ]]
  grep -q -- '! -o awg-link' "$SERVER_CONF"
  grep -qxF 'PrivateKey = player-private-key' "$CLIENTS_DIR/ali.conf"
  grep -qxF 'PresharedKey = player-psk' "$CLIENTS_DIR/ali.conf"
  grep -qxF 'Endpoint = game.example.com:41234' "$CLIENTS_DIR/ali.conf"
  grep -qxF 'AllowedIPs = 0.0.0.0/0, ::/0' "$CLIENTS_DIR/ali.conf"
  grep -qxF 'DNS = 10.68.68.1' "$CLIENTS_DIR/ali.conf"
  grep -qF 'fwmark 6768 lookup main priority 6765' "$SERVER_CONF"
  grep -qF -- '--match-set game-ips dst' "$SERVER_CONF"
  grep -qF -- '--match-set game-dns dst' "$SERVER_CONF"
  grep -qF -- '--dport 53 -m comment --comment game-setup -j REDIRECT --to-ports 53001' "$SERVER_CONF"
  grep -qxF 'SPLIT=1' "$STATE_FILE"
  grep -qxF 'ENDPOINT=game.example.com' "$STATE_FILE"
  grep -qxF 'Table = off' "$LINK_CONF"
  sed -i 's|^PostUp = |PostUp = echo original-hook; |' "$SERVER_CONF"
  systemctl() {
    if [[ $1 == start && ! -f $test_dir/failed ]]; then touch "$test_dir/failed"; return 1; fi
    return 0
  }
  if (cmd_repair) 2> /dev/null; then echo 'repair ignored a failed restart' >&2; exit 1; fi
  cmp "$SERVER_CONF" "$SERVER_CONF.bak"
  grep -qF 'echo original-hook' "$SERVER_CONF"

  # The kharej repair must still NAT Iran's players, without changing its link peer.
  rm -f "$SERVER_CONF"
  printf 'TOKEN=%q\n' "$token" > "$LINK_ENV"
  printf '[Interface]\nPrivateKey = link-key\n\n[Peer]\nAllowedIPs = 10.67.67.2/32, 10.68.68.0/24\n' > "$LINK_CONF"
  cmd_repair
  grep -qF 'POSTROUTING -s 10.68.68.0/24 -o eth0' "$LINK_CONF"
  grep -qxF 'AllowedIPs = 10.67.67.2/32, 10.68.68.0/24' "$LINK_CONF"
  if grep -q REJECT "$LINK_CONF"; then echo 'Iran guard on the kharej link' >&2; exit 1; fi
)

echo 'game-setup checks passed'
