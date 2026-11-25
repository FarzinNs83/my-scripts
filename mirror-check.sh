#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: bash mirror-check.sh [github|npm|pypi|docker|all] [--timeout SECONDS]

Probe the upstreams and mirrors used by these installers from this machine.
Shows HTTPS status and timing. Exits 1 if any selected service has no reachable
endpoint. Requires curl. Docker probes reach the registry API without pulling images.
EOF
}

scope=all
seconds=8
while (($#)); do
  case "$1" in
    github | npm | pypi | docker | all) scope=$1 ;;
    --timeout)
      [[ ${2-} =~ ^[1-9][0-9]*$ ]] || { printf 'Give --timeout a positive number of seconds.\n' >&2; exit 2; }
      seconds=$2
      shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
command -v curl > /dev/null || { printf 'curl is required.\n' >&2; exit 2; }

probe() {
  local kind=$1 label=$2 url=$3 headers status elapsed result
  if ! headers=$(curl --silent --location --connect-timeout "$seconds" --max-time "$seconds" \
    --dump-header - --output /dev/null --write-out '%{http_code} %{time_total}' "$url"); then
    printf '  %-24s  FAIL  connection error or timeout\n' "$label"
    return 1
  fi
  read -r status elapsed <<< "${headers##*$'\n'}"
  result=OK
  if [[ $kind == docker && $status == 401 ]] && grep -qi '^WWW-Authenticate:' <<< "$headers"; then
    result=AUTH
  elif [[ ! $status =~ ^2[0-9][0-9]$ ]]; then
    result=FAIL
  fi
  printf '  %-24s  %-4s  HTTP %s  %ss\n' "$label" "$result" "$status" "$elapsed"
  [[ $result != FAIL ]]
}

failed=0
check_group() {
  local name=$1 reached=0
  shift
  [[ $scope == all || $scope == "$name" ]] || return 0
  printf '\n%s\n' "$name"
  while (($#)); do
    if probe "$name" "$1" "$2"; then
      reached=1
      printf '    %s\n' "$2"
    fi
    shift 2
  done
  if ((reached == 0)); then
    printf '  No reachable endpoints.\n'
    failed=1
  fi
}

raw=https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/README.md
check_group github 'GitHub raw' "$raw" 'ghfast mirror' "https://ghfast.top/${raw}"
check_group npm 'npm' https://registry.npmjs.org/react/latest \
  'npmmirror' https://registry.npmmirror.com/react/latest \
  'Runflare' https://mirror-npm.runflare.com/react/latest
check_group pypi 'PyPI' https://pypi.org/simple/pip/ \
  'Aliyun' https://mirrors.aliyun.com/pypi/simple/pip/ \
  'Runflare' https://mirror-pypi.runflare.com/simple/pip/
check_group docker 'n8n registry' https://docker.n8n.io/v2/ \
  'Docker Hub' https://registry-1.docker.io/v2/ \
  'ArvanCloud' https://docker.arvancloud.ir/v2/ \
  'IranServer' https://docker.iranserver.com/v2/ \
  'Docker.ir' https://registry.docker.ir/v2/
exit "$failed"
