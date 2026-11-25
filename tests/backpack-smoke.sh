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
echo 'Bash argument and empty-state checks passed'
