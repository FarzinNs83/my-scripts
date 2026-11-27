#!/usr/bin/env bash
# Offline checks for game-setup.sh: arguments, junk parameters, peer bookkeeping.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source game-setup.sh

parse_args add ali --port 41234 --subnet 10.77.0
[[ $CMD == add && $NAME == ali && $PORT == 41234 && $NET == 10.77.0 ]]
CMD="" NAME="" PORT=""
parse_args bridge --token 'S0g9MQo+'
[[ $CMD == bridge && $TOKEN_IN == 'S0g9MQo+' ]]
for bad in "--port 0" "--port 65536" "--port 1;id" "--subnet 10.0" "add a/b" "--endpoint x;y" "--dns 1.1.1.1;id" \
  "bridge --token a;b" "bridge --token a\$(id)"; do
  CMD="" NAME="" TOKEN_IN=""
  # shellcheck disable=SC2086
  if (parse_args $bad) 2> /dev/null; then echo "accepted: $bad" >&2; exit 1; fi
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
[[ $NET == 10.68.68 && $T_JUNK == "$junk" && $T_FT == 0 ]] # no faketcp argument: plain UDP link
read_token "$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk" 1)"
[[ $T_FT == 1 && $T_JUNK == "$junk" ]]
read_token "$(printf 'KH=198.51.100.7\nLPORT=41234\nKPUB=%s\nIPRIV=%s\nPSK=%s\nNET=10.68.68\n%s\n' "$k1" "$k2" "$k3" "$junk" | base64 -w0)"
[[ $T_FT == 0 ]] # a token from before --faketcp
if (read_token "$(make_token 198.51.100.7 41234 "$k1" "$k2" "$k3" 10.68.68 "$junk" 2)") 2> /dev/null; then
  echo "accepted FT=2" >&2; exit 1
fi
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

# NAT only where traffic leaves for the internet (direct server, kharej link end)
rules=$(post_rules 10.68.68 eth0)
grep -qF 'iptables -t nat -A POSTROUTING -s 10.68.68.0/24 -o eth0 -m comment --comment game-setup -j MASQUERADE' <<< "$rules"
grep -qF 'iptables -t nat -D POSTROUTING -s 10.68.68.0/24 -o eth0' <<< "$rules"
rules=$(post_rules)
grep -qF 'PostUp = iptables -I FORWARD -i %i ' <<< "$rules"
if grep -q MASQUERADE <<< "$rules"; then echo 'NAT on the Iran player server' >&2; exit 1; fi
echo 'game-setup checks passed'
