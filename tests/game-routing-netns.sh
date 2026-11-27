#!/usr/bin/env bash
# Real DNS, TCP/UDP egress and link-failure checks, entirely inside disposable network namespaces.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source game-setup.sh
[[ $EUID == 0 ]] || { echo 'Run this integration check as root.' >&2; exit 77; }
for tool in ip iptables ipset dnsmasq python3; do command -v "$tool" > /dev/null || exit 77; done
test_dir=$(mktemp -d)
ir=gs$$-ir kh=gs$$-kh client=gs$$-client internet=gs$$-internet
server_pid="" dns_pid=""
cleanup() {
  [[ -z $dns_pid ]] || kill "$dns_pid" 2> /dev/null || true
  [[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true
  for ns in "$client" "$ir" "$kh" "$internet"; do ip netns del "$ns" 2> /dev/null || true; done
  rm -rf "$test_dir"
}
trap cleanup EXIT
for ns in "$ir" "$kh" "$client" "$internet"; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done
pair=0
connect() {
  ((pair += 1))
  local left=g$$${pair}a right=g$$${pair}b
  ip link add "$left" type veth peer name "$right"
  ip link set "$left" netns "$1"
  ip link set "$right" netns "$4"
  ip -n "$1" link set "$left" name "$2"
  ip -n "$4" link set "$right" name "$5"
  ip -n "$1" addr add "$3" dev "$2"
  ip -n "$4" addr add "$6" dev "$5"
  ip -n "$1" link set "$2" up
  ip -n "$4" link set "$5" up
}
connect "$ir" awg-game 10.68.68.1/24 "$client" vpn0 10.68.68.2/24
connect "$ir" awg-link 10.67.67.2/30 "$kh" link0 10.67.67.1/30
connect "$ir" eth0 192.0.2.2/24 "$internet" iran0 192.0.2.1/24
connect "$kh" eth0 198.51.100.2/24 "$internet" kharej0 198.51.100.1/24
ip -n "$client" route add default via 10.68.68.1
ip -n "$ir" route add default via 192.0.2.1
ip -n "$kh" route add default via 198.51.100.1
ip -n "$kh" route add 10.68.68.0/24 via 10.67.67.2
# A veth needs a next hop; WireGuard itself is a layer-3 device and uses 'default dev awg-link'.
ip -n "$ir" route add default via 10.67.67.1 table 6767
ip -n "$ir" rule add from 10.68.68.0/24 to 10.68.68.0/24 lookup main priority 6766
ip -n "$ir" rule add from 10.68.68.0/24 lookup 6767 priority 6767
for ns in "$ir" "$kh"; do ip netns exec "$ns" sysctl -qw net.ipv4.ip_forward=1; done
ip netns exec "$ir" sysctl -qw net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.eth0.rp_filter=1 net.ipv4.conf.awg-link.rp_filter=2
ip netns exec "$kh" iptables -t nat -A POSTROUTING -s 10.68.68.0/24 -o eth0 -j MASQUERADE
for address in 1.1.1.1 198.18.0.9 198.18.0.10 203.0.113.9; do ip -n "$internet" addr add "$address/32" dev lo; done

GS_DIR=$test_dir IPSET_FILE=$test_dir/routes.ipset DNS_CONF=$test_dir/dnsmasq.conf
DNS_CACHE_FILE=$test_dir/dns-cache.ipset
ROUTE_SCRIPT=$test_dir/routing.py SPLIT=1 NET=10.68.68 DNS_PORT=53001 WAN_RPF=1
printf 'selected.test\n203.0.113.0/24\n' > "$test_dir/targets.txt"
ip netns exec "$ir" env GS_DIR="$test_dir" GS_UNIT_DIR="$test_dir" bash -e -c '
  source game-setup.sh
  NET=10.68.68 PORT=41234 DNS_PORT=53001 DNS=1.1.1.1
  prepare_routing
  [[ $SPLIT == 1 && $DNS == 10.68.68.1 && $WAN_RPF == 1 ]]
'
grep -qxF "ReadWritePaths=${DNS_CACHE_FILE}" "$test_dir/game-dns.service"
grep -qxF 'WantedBy=multi-user.target awg-quick@awg-game.service' "$test_dir/game-dns.service"
if command -v systemd-analyze > /dev/null; then
  printf '[Service]\nType=oneshot\nExecStart=/bin/true\nRemainAfterExit=yes\n' > "$test_dir/awg-quick@awg-game.service"
  SYSTEMD_UNIT_PATH="${test_dir}:/usr/lib/systemd/system" systemd-analyze verify "$test_dir/game-dns.service"
fi
wan_iface() { echo eth0; }
rules=$(post_rules)
up=$(sed -n 's/^PostUp = //p' <<< "$rules")
down=$(sed -n 's/^PostDown = //p' <<< "$rules")
ip netns exec "$ir" bash -e -c "${up//%i/awg-game}"

cat > "$test_dir/server.py" <<'PY'
import http.server
import socket
import socketserver
import struct
import threading


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        end, labels = 12, []
        while data[end]:
            length = data[end]
            labels.append(data[end + 1:end + 1 + length].decode())
            end += length + 1
        name = ".".join(labels)
        print(name, self.client_address[0], flush=True)
        address = "198.18.0.9" if name.endswith(("selected.test", "newtarget.test")) else "198.18.0.10"
        response = data[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0) + data[12:end + 5]
        response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton(address)
        sock.sendto(response, self.client_address)


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        self.request[1].sendto(self.client_address[0].encode(), self.client_address)


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(self.client_address[0].encode())

    def log_message(self, *_):
        pass


for server in (socketserver.UDPServer(("1.1.1.1", 53), DNS),
               socketserver.UDPServer(("198.18.0.9", 8081), UDP),
               socketserver.UDPServer(("198.18.0.10", 8081), UDP)):
    threading.Thread(target=server.serve_forever, daemon=True).start()
http.server.HTTPServer(("0.0.0.0", 8080), HTTP).serve_forever()
PY
ip netns exec "$internet" python3 "$test_dir/server.py" > "$test_dir/queries.log" 2>&1 & server_pid=$!
ip netns exec "$ir" dnsmasq --keep-in-foreground --conf-file="$DNS_CONF" > "$test_dir/dns.log" 2>&1 & dns_pid=$!
# Wait for the two actual listeners, rather than assuming process creation means readiness.
for _ in {1..50}; do
  if ip netns exec "$ir" ss -Huln | grep -q ':53001 ' && ip netns exec "$internet" ss -Htln | grep -q ':8080 '; then break; fi
  sleep .1
done
cat > "$test_dir/client.py" <<'PY'
import http.client
import socket
import struct
import sys


def resolve(name):
    question = b"".join(bytes([len(part)]) + part.encode() for part in name.split(".")) + b"\x00\x00\x01\x00\x01"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(3)
        # Even a client asking an external resolver must pass through the VPN's DNS.
        sock.sendto(b"\x12\x34" + struct.pack("!HHHHH", 0x0100, 1, 0, 0, 0) + question, ("8.8.8.8", 53))
        reply = sock.recv(4096)
        assert reply[3] & 15 == 0, reply
        return socket.inet_ntoa(reply[-4:])


def exit_ip(address):
    connection = http.client.HTTPConnection(address, 8080, timeout=3)
    try:
        connection.request("GET", "/")
        return connection.getresponse().read().decode()
    finally:
        connection.close()


if sys.argv[1] == "up":
    for name, expected in (("sub.selected.test", "198.51.100.2"), ("ordinary.test", "192.0.2.2")):
        address = resolve(name)
        assert exit_ip(address) == expected, (name, exit_ip(address))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(3)
            sock.sendto(b"game", (address, 8081))
            assert sock.recv(100).decode() == expected, name
    assert exit_ip("203.0.113.9") == "198.51.100.2", "explicit CIDR did not use the kharej"
elif sys.argv[1] == "added":
    assert exit_ip(resolve("newtarget.test")) == "198.51.100.2", "live domain addition did not use the kharej"
else:
    assert exit_ip(resolve("another.ordinary.test")) == "192.0.2.2", "ordinary DNS/internet failed with link down"
    try:
        leaked_ip = exit_ip("198.18.0.9")
    except (OSError, http.client.HTTPException):
        pass
    else:
        raise AssertionError("listed traffic escaped with the link down: " + leaked_ip)
PY
if ! ip netns exec "$client" python3 "$test_dir/client.py" up; then cat "$test_dir/dns.log" "$test_dir/queries.log"; exit 1; fi
grep -qF 'sub.selected.test 198.51.100.2' "$test_dir/queries.log"
grep -qF 'ordinary.test 192.0.2.2' "$test_dir/queries.log"
ip netns exec "$ir" ipset test game-dns 198.18.0.9
# Save/restore learned IPs, as the DNS unit and player PostUp do on a clean restart.
ip netns exec "$ir" ipset save game-dns > "$DNS_CACHE_FILE"
ip netns exec "$ir" bash -e -c "${down//%i/awg-game}"
ip netns exec "$ir" ipset flush game-dns
ip netns exec "$ir" bash -e -c "${up//%i/awg-game}"
ip netns exec "$ir" ipset test game-dns 198.18.0.9
# A new domain is applied while the player/link interfaces stay up.
python3 "$ROUTE_SCRIPT" "$test_dir" add newtarget.test
python3 "$ROUTE_SCRIPT" "$test_dir" render 10.68.68 53001 1.1.1.1
ip netns exec "$ir" ipset -exist restore < "$IPSET_FILE"
kill "$dns_pid"
wait "$dns_pid" || true
ip netns exec "$ir" dnsmasq --keep-in-foreground --conf-file="$DNS_CONF" > "$test_dir/dns.log" 2>&1 & dns_pid=$!
for _ in {1..50}; do
  if ip netns exec "$ir" ss -Huln | grep -q ':53001 '; then break; fi
  sleep .1
done
ip netns exec "$client" python3 "$test_dir/client.py" added
ip -n "$ir" link set awg-link down
ip netns exec "$client" python3 "$test_dir/client.py" down
ip netns exec "$ir" bash -e -c "${down//%i/awg-game}"
[[ $(ip netns exec "$ir" sysctl -n net.ipv4.conf.eth0.rp_filter) == 1 ]]
if ip netns exec "$ir" iptables-save | grep -q game-setup; then echo 'firewall cleanup missed rules' >&2; exit 1; fi
echo 'game DNS, TCP/UDP routing and link-failure checks passed'
