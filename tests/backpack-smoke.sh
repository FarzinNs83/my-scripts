#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source backpack-setup.sh
parse_args --ssh-host 127.0.0.1 --ssh-port 22222 --sub-port 2095 192.0.2.1
[[ $KH_IP == 192.0.2.1 && $SSH_HOST == 127.0.0.1 && $SSH_PORT == 22222 && $SUB_PORT == 2095 ]]
for option in --ssh-port --sub-port; do
  for bad in 0 65536 abc '22;id'; do
    if (parse_args "$option" "$bad" 192.0.2.1) 2>/dev/null; then
      echo "accepted invalid port: $bad" >&2; exit 1
    fi
  done
done
INFO_FILE=$(mktemp)
trap 'rm -f "$INFO_FILE"' EXIT
TOKEN_BASE=test
write_info
grep -q '^KH_IP=192.0.2.1$' "$INFO_FILE"

# xray transport: both configs are JSON, share id/shortId, and the kharej only reaches the panel's loopback ports
IRAN_IP=198.51.100.7 XR_SNI=www.example.com XR_PRIV=priv XR_PUB=pub TUN_xray=4111 SFW_xray=4211 KSUB_PORT=2096
XP_tcp=20443 XP_ws=20450 XP_xh=20457 PUB_tcp_xray=2101 PUB_ws_xray=2102 PUB_xh_xray=2103
python3 - <(render_xray server) <(render_xray client) <<'PY'
import json, sys
s, c = (json.load(open(p)) for p in sys.argv[1:])
user, out = s["inbounds"][0]["settings"]["clients"][0], c["outbounds"][2]["settings"]
assert user["id"] == out["id"] and user["reverse"]["tag"] == "bpt-rev" == out["reverse"]["tag"]
assert s["inbounds"][0]["streamSettings"]["realitySettings"]["shortIds"] == [c["outbounds"][2]["streamSettings"]["realitySettings"]["shortId"]]
assert {(i["port"], i["settings"]["port"]) for i in s["inbounds"][1:]} == {(2101, 20443), (2102, 20450), (2103, 20457), (4211, 2096)}
assert set(s["routing"]["rules"][0]["inboundTag"]) == {i["tag"] for i in s["inbounds"][1:]}
assert c["routing"]["rules"][0]["port"] == "20443,20450,20457,2096" and c["outbounds"][0]["protocol"] == "blackhole"
PY
echo 'Bash argument and empty-state checks passed'
