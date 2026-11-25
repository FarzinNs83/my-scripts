#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: bash vps-check.sh [--cert-days DAYS]

Report the state of services set up by this repository, disk usage,
listening ports and certificates. Run as root to see all details.
Exit 1 indicates a failed check or an expiring certificate.
EOF
}

days=14
case "${1-}" in
  '') ;;
  -h | --help) usage; exit 0 ;;
  --cert-days)
    [[ $# == 2 && $2 =~ ^(0|[1-9][0-9]{0,3})$ ]] || { usage >&2; exit 2; }
    days=$2 ;;
  *) usage >&2; exit 2 ;;
esac

export LC_ALL=C
failed=0
if ((EUID != 0)); then
  printf 'Some checks may need root access.\n'
fi

unit_state() {
  local unit=$1 state
  state=$(systemctl is-active "$unit" 2> /dev/null) || true
  printf '  %-32s %s\n' "$unit" "${state:-unknown}"
  if [[ $state != active ]]; then
    failed=1
  fi
}

container_state() {
  local name=$1 state health
  if ! state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
    "$name" 2> /dev/null); then
    printf '  %-32s missing or Docker unavailable\n' "$name"
    failed=1
    return
  fi
  read -r state health <<< "$state"
  printf '  %-32s %s %s\n' "$name" "$state" "$health"
  if [[ $state != running || ( -n $health && $health != healthy ) ]]; then
    failed=1
  fi
}

setting() {
  local value
  value=$(sed -n "s/^$2=//p" "$1" 2> /dev/null | head -n 1)
  value=${value#\'}
  printf '%s' "${value%\'}"
}

http_state() {
  local url=$1 expected=$2 status
  shift 2
  status=$(curl --noproxy '*' -sS --max-time 5 -o /dev/null -w '%{http_code}' "$@" -- "$url" 2> /dev/null) || status=000
  printf '  %-32s HTTP %s\n' "$url" "$status"
  if [[ ! $status =~ $expected ]]; then
    failed=1
  fi
}

https_state() {
  local domain=$1 path=${2:-/} expected=${3:-'^[234][0-9][0-9]$'}
  if [[ $domain =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && $path == /* ]]; then
    http_state "https://${domain}${path}" "$expected" --resolve "${domain}:443:127.0.0.1"
  else
    printf '  Invalid or unreadable site configuration.\n'
    failed=1
  fi
}

printf 'Host\n'
uptime || failed=1
free -h || failed=1
printf '\nDisk usage\n'
if disk=$(df -hP -x tmpfs -x devtmpfs); then
  printf '%s\n' "$disk"
  if awk 'NR > 1 && $5 + 0 >= 90 { print "  WARN     " $6 " is " $5 " full"; warn = 1 } END { exit !warn }' <<< "$disk"; then
    failed=1
  fi
else
  failed=1
fi

printf '\nManaged services\n'
if command -v systemctl > /dev/null && [[ -d /run/systemd/system ]]; then
  for unit in nginx AdGuardHome x-ui; do
    if [[ $(systemctl show "$unit" --property=LoadState --value 2> /dev/null) == loaded ]]; then
      unit_state "$unit"
    fi
  done
fi
if [[ -f ${NS_DIR:-/opt/n8n}/docker-compose.yml ]]; then
  env_file="${NS_DIR:-/opt/n8n}/.env"
  container_state n8n
  if grep -q '^  postgres:' "${NS_DIR:-/opt/n8n}/docker-compose.yml"; then
    container_state n8n-postgres
  fi
  port=$(setting "$env_file" N8N_LOCAL_PORT)
  if [[ $port =~ ^[0-9]+$ ]]; then
    http_state "http://127.0.0.1:${port}/healthz" '^200$'
  else
    printf '  Missing or invalid n8n local port.\n'
    failed=1
  fi
  domain=$(setting "$env_file" N8N_DOMAIN)
  if [[ -n $domain ]]; then
    https_state "$domain" /healthz '^200$'
  fi
fi

dns_state="${DS_STATE_FILE:-${DS_DIR:-/etc/dns-setup}/state.env}"
if [[ -r $dns_state ]]; then
  printf '\nAdGuard Home HTTPS\n'
  https_state "$(setting "$dns_state" DS_DOMAIN)"
fi

shopt -s nullglob
sites=("${FD_ETC:-/etc/front-deploy}"/sites/*.conf "${BD_ETC:-/etc/back-deploy}"/apps/*.conf)
if ((${#sites[@]})); then
  printf '\nFrontend and backend HTTPS\n'
  for site in "${sites[@]}"; do
    domain=$(setting "$site" SITE_DOMAIN)
    path=$(setting "$site" SITE_PATH)
    if [[ -z $path ]]; then
      path=$(setting "$site" SITE_HEALTH_PATH)
    fi
    https_state "$domain" "$path"
  done
fi

printf '\nListening TCP and UDP ports\n'
if ! ss -lntup; then
  failed=1
fi

printf '\nTLS certificates (warning within %s days)\n' "$days"
certs=(/etc/letsencrypt/live/*/fullchain.pem /root/cert/*/fullchain.pem)
if ((${#certs[@]} == 0)); then
  printf '  No certificates found in the standard installer paths.\n'
fi
for cert in "${certs[@]}"; do
  if ! expiry=$(openssl x509 -in "$cert" -noout -enddate 2> /dev/null); then
    printf '  INVALID  %s\n' "$cert"
    failed=1
  elif openssl x509 -in "$cert" -noout -checkend "$((days * 86400))" > /dev/null 2>&1; then
    printf '  OK       %s  (%s)\n' "$cert" "${expiry#notAfter=}"
  else
    printf '  WARN     %s  (%s)\n' "$cert" "${expiry#notAfter=}"
    failed=1
  fi
done
exit "$failed"
