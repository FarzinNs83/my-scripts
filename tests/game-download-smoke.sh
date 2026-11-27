#!/usr/bin/env bash
# Offline certificate forwarding checks; no real firewall, services or certificate requests.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source game-setup.sh

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
GS_DIR=$test_dir DOWNLOAD_ENV=$test_dir/download.env DOWNLOAD_SCRIPT=$test_dir/download.py
DOWNLOAD_UNIT_FILE=$test_dir/game-download.service
export GS_TEST_RULES=$test_dir/rules
touch "$GS_TEST_RULES"
ENDPOINT=game.example.com PORT=41234
pick_count=0
pick_port() {
  ((pick_count += 1))
  if ((pick_count <= 2)); then PORT=50000; else PORT=50001; fi
}
openssl() { return 1; }
apt-get() { echo 'unexpected package installation' >&2; return 1; }
open_port() { printf '%s\n' "$1" >> "$test_dir/opened"; }
systemctl() { printf '%s\n' "$*" >> "$test_dir/services"; }

# Model iptables check/add/delete by exact table, chain and rule, across hook subprocesses.
iptables() {
  local table=filter action rule
  if [[ $1 == -t ]]; then table=$2; shift 2; fi
  action=$1; shift
  rule="$table $*"
  case $action in
    -C) grep -qxF -- "$rule" "$GS_TEST_RULES" ;;
    -I) printf '%s\n' "$rule" >> "$GS_TEST_RULES" ;;
    -D)
      grep -qxF -- "$rule" "$GS_TEST_RULES" || return 1
      grep -vxF -- "$rule" "$GS_TEST_RULES" > "${GS_TEST_RULES}.tmp" || true
      mv "${GS_TEST_RULES}.tmp" "$GS_TEST_RULES"
      ;;
    *) return 1 ;;
  esac
}
export -f iptables

certbot() {
  local pre="" post="" listener=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pre-hook) pre=$2; shift 2 ;;
      --post-hook) post=$2; shift 2 ;;
      --http-01-port) listener=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ $listener == 50001 ]] # Separate from downloads (50000), 80 and 443.
  bash -c "$pre"
  bash -c "$pre" # Repeated preparation must not leave duplicate forwards.
  [[ $(wc -l < "$GS_TEST_RULES") == 2 ]]
  grep -qF 'nat PREROUTING -p tcp --dport 80 ' "$GS_TEST_RULES"
  grep -qF -- '--to-ports 50001' "$GS_TEST_RULES"
  grep -qF -- '--ctorigdstport 80' "$GS_TEST_RULES"
  bash -c "$post"
  [[ ! -s $GS_TEST_RULES ]]
  [[ ${GS_TEST_CERT_FAIL:-0} == 0 ]]
}

setup_downloads
[[ $PORT == 41234 ]] # Download setup must not change the player's UDP port.
grep -qxF 'DOWNLOAD_PORT=50000' "$DOWNLOAD_ENV"
grep -qxF '50000/tcp' "$test_dir/opened"
[[ $(wc -l < "$test_dir/opened") == 1 ]]
grep -qF " ${GS_DIR} 50000 " "$DOWNLOAD_UNIT_FILE"
if grep -qE 'nginx|stop | (80|443)( |$)' "$test_dir/services"; then
  echo 'touched another service or a reserved port' >&2; exit 1
fi

# Certbot runs its post-hook on failure too; leave no traffic forwarded to a dead listener.
cp "$test_dir/services" "$test_dir/services.before"
pick_count=0
if (GS_TEST_CERT_FAIL=1; setup_downloads) 2> /dev/null; then echo 'ignored certificate failure' >&2; exit 1; fi
[[ ! -s $GS_TEST_RULES ]]
cmp "$test_dir/services.before" "$test_dir/services"
for reserved in 80 443 00080 00443; do
  printf 'DOWNLOAD_PORT=%s\n' "$reserved" > "$DOWNLOAD_ENV"
  if (setup_downloads) 2> /dev/null; then echo "reserved HTTPS listener: $reserved" >&2; exit 1; fi
done
echo 'game download forwarding checks passed'
