#!/usr/bin/env bash
# =============================================================================
#  dns-setup.sh -- self-hosted "anti-sanction" DNS with an SNI relay
#
#  What it does
#    1. installs AdGuard Home (web panel, DoH/DoT/DoQ, cache, stats) and puts
#       it behind a Let's Encrypt certificate for the given domain
#    2. puts nginx (stream + ssl_preread) on :443 and dispatches by SNI:
#         dns.example.com  -> AdGuard Home (panel + DoH, TLS terminated there)
#         relay list       -> the real server of that domain (plain TLS relay,
#                             no MITM: the client still validates the real
#                             certificate, the site only sees this server's IP)
#         anything else    -> dropped
#    3. adds the DNS rewrites that answer the relay list with this server's
#       address, so one domain + one certificate covers panel, DoH, DoT and
#       the relay
#    4. keeps :80 for ACME challenges only and redirects the relayed domains
#       from http:// to https://
#    5. installs `dnsctl` (a symlink to this script) to manage the relay list
#
#  This file is independent from 3xui-setup.sh: it owns its own paths, ports,
#  unit, log and state, and it never touches /usr/local/x-ui or its inbounds.
#
#  Usage:
#    bash dns-setup.sh dns.example.com
#    bash dns-setup.sh --open-firewall --email me@example.com dns.example.com
#    bash <(curl -Ls https://raw.githubusercontent.com/USER/REPO/main/dns-setup.sh) dns.example.com
#    dnsctl add registry.npmjs.org
#    dnsctl status
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Paths (all overridable from the environment for testing)
# ---------------------------------------------------------------------------
DS_DIR="${DS_DIR:-/etc/dns-setup}"
STATE_FILE="${DS_STATE_FILE:-${DS_DIR}/state.env}"
DOMAINS_FILE="${DS_DOMAINS_FILE:-${DS_DIR}/domains.txt}"
ALLOWED_FILE="${DS_ALLOWED_FILE:-${DS_DIR}/allowed-cidrs.txt}"
MANAGED_FILE="${DS_MANAGED_FILE:-${DS_DIR}/managed-rewrites.txt}"
INFO_FILE="${DS_INFO_FILE:-/root/dns-info.env}"
LOG_FILE="${DS_LOG_FILE:-/var/log/dns-setup.log}"
COOKIE_FILE="${DS_COOKIE_FILE:-/root/.dns-setup-cookie}"

AGH_DIR="${DS_AGH_DIR:-/opt/AdGuardHome}"
AGH_BIN="${AGH_DIR}/AdGuardHome"
AGH_UNIT="AdGuardHome.service"

NGINX_STREAM_DIR="${DS_NGINX_STREAM_DIR:-/etc/nginx/stream.d}"
NGINX_STREAM_CONF="${DS_NGINX_STREAM_CONF:-${NGINX_STREAM_DIR}/dns-setup-relay.conf}"
NGINX_HTTP_CONF="${DS_NGINX_HTTP_CONF:-/etc/nginx/conf.d/dns-setup-http.conf}"
NGINX_MAIN="${DS_NGINX_MAIN:-/etc/nginx/nginx.conf}"
NGINX_MARK="# dns-setup: stream configs"

ACME_ROOT="${DS_ACME_ROOT:-/var/www/dns-setup}"
RENEW_HOOK="${DS_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/dns-setup-reload.sh}"

DS_TLS_DIR="${DS_TLS_DIR:-/etc/letsencrypt/live}"   # certbot lineage directory

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
DOMAIN=""
EMAIL=""
LOOPBACK_PORT="${DS_LOOPBACK_PORT:-18443}"   # local HTTPS listener of AdGuard
PANEL_PORT="${DS_PANEL_PORT:-3000}"          # local plain-HTTP panel
DNS_PORT="${DS_DNS_PORT:-53}"
DOT_PORT="${DS_DOT_PORT:-853}"
RATELIMIT="${DS_RATELIMIT:-30}"
CACHE_SIZE="${DS_CACHE_SIZE:-4194304}"

SKIP_DNS=0
OPEN_FIREWALL=0
RELAY=1
STAGING=0
FORCE=0
DISABLE_AAAA="${DS_DISABLE_AAAA:-0}"
CUSTOM_LIST=""
ADMIN_USER=""
ADMIN_PASS=""
IR_UPSTREAM=""

UPSTREAMS=()
BOOTSTRAPS=()
ALLOWED_CIDRS=()
UPSTREAMS_SET=0

PUBLIC_IPV4=""
PUBLIC_IPV6=""
AGH_URL=""
WORK_DIR=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
dns-setup.sh -- self-hosted anti-sanction DNS: AdGuard Home + SNI relay.

Usage:
  sudo bash dns-setup.sh [options] <domain>
  dnsctl <command> [args]

Install options:
  -d, --domain <name>     public domain, e.g. dns.example.com (asked when omitted)
  -e, --email <address>   Let's Encrypt account email (default: admin@<domain>)
      --skip-dns-check    do not verify that the domain points to this server
      --open-firewall     open 53/tcp, 53/udp, 80, 443, 853/tcp, 853/udp (ufw, firewalld)
      --no-relay          DNS only: no SNI relay and no rewrite list
      --relay-list <file> seed the relay list from a file (one domain per line)
      --upstream <url>    AdGuard upstream (DoH/DoT/plain); repeatable, replaces the default
      --ir-upstream <ip>  resolve *.ir through this resolver instead
      --disable-aaaa      answer AAAA queries with an empty answer (no usable IPv6)
      --allow-cidr <net>  only serve these client networks; repeatable (default: everyone)
      --admin-user <name> panel user (default: admin)
      --admin-pass <pass> panel password (default: random)
      --loopback-port <n> local HTTPS port behind :443 (default: 18443)
      --staging           Let's Encrypt staging CA (testing only)
      --force             reinstall AdGuard Home / refresh everything
  -h, --help              show this help

Commands (same as dnsctl):
  add <domain>...     add domains to the relay list (DNS rewrite + TLS relay)
  remove <domain>...  remove domains from the relay list
  import <file|url>   bulk-add domains from a community list
                      (e.g. the sanctioned-domain lists on GitHub)
  list                show the relay list
  sync                re-apply list, rewrites and nginx after manual edits
  allow [<cidr>...]   show or set the client allowlist (no arguments = show)
  allow --clear       serve every client again
  status              services, ports, certificate and list status
  test                end-to-end checks: DoH, DoT, relay, rewrite
  info                client settings: DoH URL, DoT host, DNS stamps, QR code
  renew               force a certificate renewal and reload the services
  uninstall [--yes]   remove everything this script installed

How the relay works:
  A client that uses this DNS resolves a relay-list domain to THIS server.
  nginx reads the TLS SNI and forwards the bytes to the real server, so the
  site sees this server's IP (sanction bypass) while the client still checks
  the site's own certificate. Everything else is answered by AdGuard Home.

Ports: 53/udp+tcp (AdGuard), 80/tcp (ACME + redirect), 443/tcp (nginx),
       853/tcp (DoT) and 853/udp (DoQ).
EOF
}

# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------
_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] Setup failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}

require_root() {
  if [[ ${EUID} -eq 0 ]]; then
    return 0
  fi
  if command -v sudo > /dev/null 2>&1; then
    if [[ ! -f $0 ]]; then
      die "This one-liner must run as root. Run 'sudo -i' first, then re-run it."
    fi
    local self
    self=$(readlink -f "$0" 2> /dev/null || printf '%s' "$0")
    exec sudo -E bash "$self" "$@"
  fi
  die "This script must be run as root."
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

work_dir() {
  if [[ -z $WORK_DIR ]]; then
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "${WORK_DIR:-}"' EXIT
  fi
  printf '%s\n' "$WORK_DIR"
}

load_os() {
  local f pretty
  for f in /etc/os-release /usr/lib/os-release; do
    [[ -r $f ]] || continue
    # shellcheck disable=SC1090
    pretty=$(. "$f" && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
    if [[ ${pretty,,} != *ubuntu* && ${pretty,,} != *debian* ]]; then
      warn "This script targets Ubuntu/Debian; '${pretty}' is untested."
    fi
    say "OS: ${pretty}"
    return 0
  done
  die "Cannot read /etc/os-release; unsupported OS."
}

rand_hex() {
  local bytes=$1
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

normalize_domain() {
  local d=$1
  d=${d#*://}
  d=${d%%/*}
  d=${d%%:*}
  d=${d%.}
  d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  printf '%s\n' "$d"
}

is_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# Relay-list entry: "example.com" or "*.example.com".
normalize_list_domain() {
  local d=$1 base
  d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  d=${d#*://}
  d=${d%%/*}
  d=${d%.}
  if [[ $d == '*.'* ]]; then
    base=${d#\*.}
    is_domain "$base" || return 1
    printf '*.%s\n' "$base"
    return 0
  fi
  is_domain "$d" || return 1
  printf '%s\n' "$d"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

port_in_use() {
  local p=$1 proto=${2:-tcp}
  if [[ $proto == udp ]]; then
    ss -lun 2> /dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
  else
    ss -ltn 2> /dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
  fi
}

port_holder() {
  local p=$1 proto=${2:-tcp}
  if [[ $proto == udp ]]; then
    ss -lunp 2> /dev/null | awk -v p=":${p}$" '$4 ~ p && !found {print; found=1}'
  else
    ss -ltnp 2> /dev/null | awk -v p=":${p}$" '$4 ~ p && !found {print; found=1}'
  fi
}

ipv6_enabled() {
  [[ -f /proc/net/if_inet6 ]]
}

public_ipv4() {
  local url ip
  for url in \
    https://api4.ipify.org \
    https://ipv4.icanhazip.com \
    https://4.ident.me; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2> /dev/null | tr -d '[:space:]"') || true
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

detect_ipv6() {
  ipv6_enabled || return 1
  ip -6 route get 2606:4700:4700::1111 > /dev/null 2>&1 || return 1
  local ext=""
  ext=$(curl -6 -fsS --max-time 6 https://api6.ipify.org 2> /dev/null | tr -d '[:space:]"') || true
  [[ $ext == *:* ]] || return 1
  printf '%s\n' "$ext"
}

resolve_ipv4() {
  local d=$1 ip=""
  ip=$(getent ahostsv4 "$d" 2> /dev/null | awk 'NR == 1 {print $1}') || true
  if [[ -z $ip ]] && command -v dig > /dev/null 2>&1; then
    ip=$(dig +short A "$d" 2> /dev/null | awk 'NR == 1 {print $1}') || true
  fi
  printf '%s\n' "$ip"
}

svc_active() {
  systemctl is-active --quiet "$1" 2> /dev/null
}

wait_port() {
  local p=$1 proto=${2:-tcp} tries=${3:-60} i
  for ((i = 0; i < tries; i++)); do
    if port_in_use "$p" "$proto"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
ensure_packages() {
  local pkgs=(curl ca-certificates openssl nginx certbot python3)
  local missing=() p
  for p in "${pkgs[@]}"; do
    case "$p" in
      curl) command -v curl > /dev/null 2>&1 || missing+=("$p") ;;
      openssl) command -v openssl > /dev/null 2>&1 || missing+=("$p") ;;
      nginx) command -v nginx > /dev/null 2>&1 || missing+=("$p") ;;
      certbot) command -v certbot > /dev/null 2>&1 || missing+=("$p") ;;
      python3) command -v python3 > /dev/null 2>&1 || missing+=("$p") ;;
      ca-certificates) [[ -d /etc/ssl/certs ]] || missing+=("$p") ;;
    esac
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  command -v apt-get > /dev/null 2>&1 || die "apt-get is required to install: ${missing[*]}"
  say "Installing packages: ${missing[*]}"
  apt-get -o DPkg::Lock::Timeout=180 update -qq || die "apt-get update failed."
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq "${missing[@]}" || die "Could not install: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
precheck_dns() {
  if [[ $SKIP_DNS -eq 1 ]]; then
    warn "DNS verification skipped (--skip-dns-check)."
    return 0
  fi
  local resolved
  if ! PUBLIC_IPV4=$(public_ipv4); then
    warn "Could not detect this server's public IPv4; skipping the DNS check."
    return 0
  fi
  resolved=$(resolve_ipv4 "$DOMAIN")
  if [[ -z $resolved ]]; then
    die "No A record for ${DOMAIN}. Create '${DOMAIN} A ${PUBLIC_IPV4}' (Cloudflare: DNS only / grey cloud) and re-run, or add --skip-dns-check."
  fi
  if [[ $resolved != "$PUBLIC_IPV4" ]]; then
    cat >&2 << EOF
[x] DNS mismatch for ${DOMAIN}
      domain resolves to : ${resolved}
      this server's IPv4 : ${PUBLIC_IPV4}
    Let's Encrypt validates the domain on port 80 of the address it points to.
    Fix the A record (Cloudflare: proxy OFF / grey cloud) and re-run,
    or bypass this check with --skip-dns-check.
EOF
    exit 1
  fi
  say "DNS OK: ${DOMAIN} -> ${PUBLIC_IPV4}"
}

precheck_ports() {
  if port_in_use 53 udp || port_in_use 53 tcp; then
    if [[ -x $AGH_BIN ]]; then
      say "TCP/UDP 53 is already served by AdGuard Home; reusing it."
    else
      die "Port 53 is in use: $(port_holder 53 udp || true) $(port_holder 53 tcp || true). Stop that resolver and re-run."
    fi
  fi

  if port_in_use 853 tcp && [[ ! -x $AGH_BIN ]]; then
    die "TCP/853 is in use: $(port_holder 853 tcp || true). Stop that service and re-run."
  fi

  if port_in_use 443 tcp; then
    if [[ -f $NGINX_STREAM_CONF ]]; then
      say "TCP/443 is already served by this setup; continuing (idempotent re-run)."
    else
      die "TCP/443 is in use: $(port_holder 443 tcp || true). Free it (another web server?) and re-run."
    fi
  fi

  if [[ $PANEL_PORT -eq 80 || $LOOPBACK_PORT -eq 80 ]]; then
    die "Port 80 must stay free for ACME; choose another --loopback-port."
  fi
}

precheck_disk() {
  local avail
  avail=$(df -Pk / 2> /dev/null | awk 'NR == 2 {print $4}') || true
  if [[ $avail =~ ^[0-9]+$ ]] && ((avail < 524288)); then
    die "At least 512 MB of free disk space is required (found $((avail / 1024)) MB)."
  fi
}

precheck_3xui() {
  if [[ -x /usr/local/x-ui/x-ui ]]; then
    say "3x-ui detected; this script does not touch /usr/local/x-ui or its inbounds."
  fi
  local p holder
  for p in 53 80 443 853; do
    holder=$(port_holder "$p" tcp) || true
    if [[ $holder == *x-ui* ]]; then
      warn "x-ui is listening on TCP/${p}; that would conflict with this setup."
    fi
  done
}

# ---------------------------------------------------------------------------
# systemd-resolved (it squats on 127.0.0.53:53)
# ---------------------------------------------------------------------------
fix_systemd_resolved() {
  command -v systemctl > /dev/null 2>&1 || return 0
  if ! systemctl cat systemd-resolved.service > /dev/null 2>&1; then
    return 0
  fi
  local running=0
  svc_active systemd-resolved && running=1
  if ((running == 0)) && ! grep -qs '127.0.0.53' /etc/resolv.conf; then
    return 0
  fi
  say "Disabling the systemd-resolved stub listener on 127.0.0.53:53 ..."
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-dns-setup.conf <<'EOF'
# Added by dns-setup.sh: AdGuard Home needs port 53 on all interfaces.
[Resolve]
DNSStubListener=no
EOF
  systemctl restart systemd-resolved 2> /dev/null || true
  sleep 1

  if grep -qs '127.0.0.53' /etc/resolv.conf; then
    [[ -f /etc/resolv.conf.dns-setup.bak ]] || cp -P /etc/resolv.conf /etc/resolv.conf.dns-setup.bak 2> /dev/null || true
    if [[ -s /run/systemd/resolve/resolv.conf ]]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
  fi

  if ! getent hosts deb.debian.org > /dev/null 2>&1 && ! getent hosts archive.ubuntu.com > /dev/null 2>&1; then
    warn "The system resolver looks broken; writing 9.9.9.9/1.1.1.1 to /etc/resolv.conf."
    [[ -f /etc/resolv.conf.dns-setup.bak ]] || cp -P /etc/resolv.conf /etc/resolv.conf.dns-setup.bak 2> /dev/null || true
    printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\n' > /etc/resolv.conf
  fi
}

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
ensure_nginx_stream() {
  local v
  v=$(nginx -V 2>&1) || true
  if [[ $v == *--with-stream* ]]; then
    return 0
  fi
  if ls /etc/nginx/modules-enabled/*stream* > /dev/null 2>&1; then
    return 0
  fi
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq libnginx-mod-stream > /dev/null 2>&1 || true
  if ls /etc/nginx/modules-enabled/*stream* > /dev/null 2>&1; then
    return 0
  fi
  if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
    if [[ -f /etc/nginx/modules-available/50-mod-stream.conf ]]; then
      ln -sf /etc/nginx/modules-available/50-mod-stream.conf /etc/nginx/modules-enabled/50-mod-stream.conf
    else
      printf 'load_module /usr/lib/nginx/modules/ngx_stream_module.so;\n' \
        > /etc/nginx/modules-enabled/00-dns-setup-stream.conf
    fi
  fi
}

ensure_nginx_include() {
  if grep -qF "$NGINX_MARK" "$NGINX_MAIN" 2> /dev/null; then
    return 0
  fi
  install -d -m 755 "$NGINX_STREAM_DIR"
  [[ -s $NGINX_MAIN ]] || die "Cannot read ${NGINX_MAIN}."
  if [[ -n $(tail -c 1 "$NGINX_MAIN") ]]; then
    printf '\n' >> "$NGINX_MAIN"
  fi
  printf '%s\ninclude %s/*.conf;\n' "$NGINX_MARK" "$NGINX_STREAM_DIR" >> "$NGINX_MAIN"
}

disable_stock_site() {
  local f=/etc/nginx/sites-enabled/default
  [[ -e $f ]] || return 0
  if grep -q 'root /var/www/html' "$f" 2> /dev/null && grep -q 'server_name _;' "$f" 2> /dev/null; then
    rm -f "$f"
    say "Disabled the stock nginx default site (still in /etc/nginx/sites-available/default)."
    return 0
  fi
  die "A custom site lives in ${f}. Move it away so this script can own port 80, then re-run."
}

# example.com -> (sub.)?domain ; *.example.com -> sub.domain
relay_regex() {
  local e=$1 base
  if [[ $e == '*.'* ]]; then
    base=$(printf '%s' "${e#\*.}" | sed 's/[.]/\\./g')
    printf '(?:.+\\.)%s' "$base"
  else
    base=$(printf '%s' "$e" | sed 's/[.]/\\./g')
    printf '(?:.+\\.)?%s' "$base"
  fi
}

relay_domains() {
  [[ -r $DOMAINS_FILE ]] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$DOMAINS_FILE" \
    | grep -v '^$' \
    | sort -u
}

render_nginx_stream() {
  local e line count
  count=$(relay_domains | wc -l)
  install -d -m 755 "$(dirname "$NGINX_STREAM_CONF")"
  {
    printf '# Managed by dns-setup.sh -- do not edit, use: dnsctl add|remove <domain>\n'
    printf '# %s domains in %s\n' "$count" "$DOMAINS_FILE"
    printf 'map $ssl_preread_server_name $dns_setup_backend {\n'
    printf '    "%s"   127.0.0.1:%s;\n' "$DOMAIN" "$LOOPBACK_PORT"
    while IFS= read -r e; do
      [[ -n $e ]] || continue
      line='    "~*^'"$(relay_regex "$e")"'\.?$"   $ssl_preread_server_name:443;'
      printf '%s\n' "$line"
    done < <(relay_domains)
    printf '    default   127.0.0.1:1;\n'
    printf '}\n\n'
    printf 'server {\n'
    printf '    listen      443;\n'
    if ipv6_enabled; then
      printf '    listen      [::]:443;\n'
    fi
    printf '    ssl_preread on;\n'
    printf '    preread_buffer_size 16k;\n'
    printf '    resolver    9.9.9.9 1.1.1.1 8.8.8.8 valid=300s ipv6=off;\n'
    printf '    resolver_timeout 5s;\n'
    printf '    proxy_connect_timeout 5s;\n'
    printf '    proxy_timeout 1h;\n'
    printf '    proxy_pass  $dns_setup_backend;\n'
    printf '}\n'
  } > "$NGINX_STREAM_CONF"
}

render_nginx_http() {
  local e line
  install -d -m 755 "$(dirname "$NGINX_HTTP_CONF")"
  {
    printf '# Managed by dns-setup.sh -- ACME challenges + http -> https for the relay list\n'
    printf 'map $host $dns_setup_https_redirect {\n'
    printf '    default 0;\n'
    printf '    "%s" 1;\n' "$DOMAIN"
    while IFS= read -r e; do
      [[ -n $e ]] || continue
      line='    "~*^'"$(relay_regex "$e")"'\.?$" 1;'
      printf '%s\n' "$line"
    done < <(relay_domains)
    printf '}\n\n'
    printf 'server {\n'
    printf '    listen      80 default_server;\n'
    if ipv6_enabled; then
      printf '    listen      [::]:80 default_server;\n'
    fi
    printf '    server_name _;\n'
    printf '    location ^~ /.well-known/acme-challenge/ {\n'
    printf '        root %s;\n' "${ACME_ROOT%/}"
    printf '        default_type "text/plain";\n'
    printf '    }\n'
    printf '    location / {\n'
    printf '        if ($dns_setup_https_redirect) {\n'
    printf '            return 301 https://$host$request_uri;\n'
    printf '        }\n'
    printf '        return 444;\n'
    printf '    }\n'
    printf '}\n'
  } > "$NGINX_HTTP_CONF"
}

nginx_config_ok() {
  local out
  if ! out=$(nginx -t 2>&1); then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

apply_nginx() {
  nginx_config_ok || die "nginx configuration test failed (see the output above)."
  systemctl enable nginx > /dev/null 2>&1 || true
  if svc_active nginx; then
    systemctl reload nginx || die "Could not reload nginx."
  else
    systemctl start nginx || die "Could not start nginx."
  fi
}

# ---------------------------------------------------------------------------
# Certificates
# ---------------------------------------------------------------------------
CERT_DIR=""
CERT_FULLCHAIN=""
CERT_PRIVKEY=""

set_cert_paths() {
  CERT_DIR="${DS_TLS_DIR}/${DOMAIN}"
  CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
  CERT_PRIVKEY="${CERT_DIR}/privkey.pem"
}

cert_valid() {
  [[ -s $CERT_FULLCHAIN && -s $CERT_PRIVKEY ]] || return 1
  openssl x509 -in "$CERT_FULLCHAIN" -noout -checkend 86400 > /dev/null 2>&1 || return 1
  local san
  san=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -ext subjectAltName 2> /dev/null) || return 1
  [[ $san == *"DNS:${DOMAIN}"* ]]
}

obtain_certificate() {
  mkdir -p "${ACME_ROOT}/.well-known/acme-challenge"
  chmod 755 "$ACME_ROOT" "${ACME_ROOT}/.well-known" "${ACME_ROOT}/.well-known/acme-challenge"

  if cert_valid; then
    say "A valid certificate for ${DOMAIN} is already present."
    return 0
  fi

  local args=(
    certonly --webroot -w "$ACME_ROOT"
    -d "$DOMAIN" --cert-name "$DOMAIN"
    --email "$EMAIL" --agree-tos --no-eff-email
    --non-interactive --keep-until-expiring
  )
  [[ $STAGING -eq 1 ]] && args+=(--staging)

  say "Requesting a Let's Encrypt certificate for ${DOMAIN} (HTTP-01, webroot) ..."
  if ! certbot "${args[@]}"; then
    warn "certbot failed. Common causes: DNS not pointing here, TCP/80 blocked, a proxy on :80."
    return 1
  fi
  cert_valid || die "certbot reported success but ${CERT_FULLCHAIN} is not usable."
  say "Certificate issued."
}

install_renew_hook() {
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  cat > "$RENEW_HOOK" <<EOF
#!/bin/sh
# Added by dns-setup.sh: reload the services that use the Let's Encrypt cert.
systemctl reload nginx 2>/dev/null || true
systemctl reload ${AGH_UNIT} 2>/dev/null || systemctl restart ${AGH_UNIT} 2>/dev/null || true
EOF
  chmod 755 "$RENEW_HOOK"
  systemctl enable --now certbot.timer > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# AdGuard Home: install
# ---------------------------------------------------------------------------
agh_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    armv7l | armv7) printf 'armv7\n' ;;
    i386 | i686) printf '386\n' ;;
    *) return 1 ;;
  esac
}

agh_latest_tag() {
  curl -fsS --max-time 25 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
}

install_adguard() {
  if [[ -x $AGH_BIN ]] && [[ $FORCE -eq 0 ]]; then
    say "AdGuard Home is already installed at ${AGH_DIR}."
  else
    local arch tag tmp url
    arch=$(agh_arch) || die "Unsupported CPU architecture: $(uname -m)"
    tag=$(agh_latest_tag) || die "Could not read the latest AdGuard Home release."
    [[ -n $tag ]] || die "Could not parse the AdGuard Home release tag."
    say "Installing AdGuard Home ${tag} (${arch}) ..."
    tmp=$(mktemp -d)
    url="https://github.com/AdguardTeam/AdGuardHome/releases/download/${tag}/AdGuardHome_linux_${arch}.tar.gz"
    curl -fsSL --retry 3 --max-time 300 -o "$tmp/agh.tar.gz" "$url" || die "Download failed: ${url}"
    tar -xzf "$tmp/agh.tar.gz" -C "$tmp" || die "Could not extract the AdGuard Home archive."
    install -d -m 755 "$AGH_DIR"
    install -m 755 "$tmp/AdGuardHome/AdGuardHome" "$AGH_BIN"
    if [[ -d $tmp/AdGuardHome/static ]]; then
      rm -rf "$AGH_DIR/static"
      cp -a "$tmp/AdGuardHome/static" "$AGH_DIR/"
    fi
    rm -rf "$tmp"
    say "AdGuard Home binary installed at ${AGH_BIN}."
  fi

  if ! systemctl cat "$AGH_UNIT" > /dev/null 2>&1; then
    (cd "$AGH_DIR" && "$AGH_BIN" -s install) || die "Could not install the AdGuard Home systemd unit."
    systemctl daemon-reload
  fi
  systemctl enable "$AGH_UNIT" > /dev/null 2>&1 || true
}

start_adguard() {
  if svc_active "$AGH_UNIT"; then
    systemctl restart "$AGH_UNIT" || die "Could not restart AdGuard Home."
  else
    systemctl start "$AGH_UNIT" || die "Could not start AdGuard Home."
  fi
  wait_port "$PANEL_PORT" tcp 60 || die "AdGuard Home did not start listening on 127.0.0.1:${PANEL_PORT}."
}

# ---------------------------------------------------------------------------
# AdGuard Home: HTTP API
# ---------------------------------------------------------------------------
AGH_BODY=""

agh_need_work_dir() {
  work_dir > /dev/null
  AGH_BODY="${WORK_DIR}/agh-body.json"
}

agh_request() { # method path [json] -> http code, body in $AGH_BODY
  local method=$1 path=$2 data=${3-}
  agh_need_work_dir
  : > "$AGH_BODY"
  if [[ -n $data ]]; then
    curl -sS --max-time 30 -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
      -o "$AGH_BODY" -w '%{http_code}' \
      -X "$method" -H 'Content-Type: application/json' \
      --data-binary "$data" "${AGH_URL}${path}" || true
  else
    curl -sS --max-time 30 -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
      -o "$AGH_BODY" -w '%{http_code}' \
      -X "$method" "${AGH_URL}${path}" || true
  fi
}

agh_get_json() { # path
  local code
  code=$(agh_request GET "$1")
  if [[ $code != 200 ]]; then
    warn "GET $1 returned HTTP $code: $(head -c 200 "$AGH_BODY" 2> /dev/null)"
    return 1
  fi
  cat "$AGH_BODY"
}

agh_post_json() { # path json
  local code
  code=$(agh_request POST "$1" "$2")
  if [[ $code != 200 ]]; then
    warn "POST $1 returned HTTP $code: $(head -c 300 "$AGH_BODY" 2> /dev/null)"
    return 1
  fi
  cat "$AGH_BODY"
}

agh_needs_setup() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "${AGH_URL}/control/install/get_addresses" 2> /dev/null || true)
  [[ $code == 200 ]]
}

agh_login() {
  local body code
  [[ -n $ADMIN_USER && -n $ADMIN_PASS ]] || return 1
  body=$(printf '{"name":"%s","password":"%s"}' \
    "$(json_escape "$ADMIN_USER")" "$(json_escape "$ADMIN_PASS")")
  code=$(agh_request POST /control/login "$body")
  [[ $code == 200 ]]
}

agh_setup_wizard() {
  local body code
  say "Configuring AdGuard Home (panel on 127.0.0.1:${PANEL_PORT}, DNS on 0.0.0.0:${DNS_PORT}) ..."
  body=$(printf '{"web":{"ip":"127.0.0.1","port":%s},"dns":{"ip":"0.0.0.0","port":%s},"username":"%s","password":"%s"}' \
    "$PANEL_PORT" "$DNS_PORT" "$(json_escape "$ADMIN_USER")" "$(json_escape "$ADMIN_PASS")")
  code=$(agh_request POST /control/install/configure "$body")
  if [[ $code != 200 ]]; then
    die "AdGuard Home rejected the initial setup (HTTP $code): $(head -c 300 "$AGH_BODY" 2> /dev/null)"
  fi
  sleep 2
  for _ in {1..30}; do
    if agh_login; then
      return 0
    fi
    sleep 1
  done
  die "AdGuard Home did not accept the new credentials."
}

# Merge the wanted DNS settings into the current config and POST it back.
agh_apply_dns() {
  local cur merged
  work_dir > /dev/null
  cur="${WORK_DIR}/dns-info.json"
  merged="${WORK_DIR}/dns-config.json"
  agh_get_json /control/dns_info > "$cur" || return 1

  DS_UPSTREAM_DNS=$(printf '%s\n' "${UPSTREAMS[@]}")
  DS_BOOTSTRAP=$(printf '%s\n' "${BOOTSTRAPS[@]}")
  DS_ALLOWED=$(printf '%s\n' "${ALLOWED_CIDRS[@]}")
  export DS_UPSTREAM_DNS DS_BOOTSTRAP DS_ALLOWED
  export DS_DNS_PORT="$DNS_PORT" DS_RATELIMIT="$RATELIMIT" DS_CACHE="$CACHE_SIZE"
  export DS_DISABLE_AAAA="$DISABLE_AAAA"

  python3 - "$cur" > "$merged" <<'PY'
import json, os, sys

cur = json.load(open(sys.argv[1]))

def env_list(name):
    return [x for x in os.environ.get(name, "").split("\n") if x.strip()]

cur["upstream_dns"] = env_list("DS_UPSTREAM_DNS")
cur["bootstrap_dns"] = env_list("DS_BOOTSTRAP")
cur["fallback_dns"] = ["https://dns.google/dns-query"]
cur["upstream_mode"] = "load_balance"
cur["bind_hosts"] = ["0.0.0.0"]
cur["port"] = int(os.environ["DS_DNS_PORT"])
cur["ratelimit"] = int(os.environ["DS_RATELIMIT"])
cur["refuse_any"] = True
cur["cache_size"] = int(os.environ["DS_CACHE"])
cur["cache_ttl_min"] = 60
cur["cache_optimistic"] = True
cur["enable_dnssec"] = True
cur["serve_plain_dns"] = True
cur["allowed_clients"] = env_list("DS_ALLOWED")
cur["aaaa_disabled"] = os.environ.get("DS_DISABLE_AAAA") == "1"
cur["hostsfile_enabled"] = False

json.dump(cur, sys.stdout)
PY

  agh_post_json /control/dns_config "$(cat "$merged")" > /dev/null \
    || die "AdGuard Home rejected the DNS settings."
  say "DNS upstream, cache and access settings applied."
}

# Push only the client allowlist, leaving upstreams and the rest untouched.
agh_apply_allowlist() {
  local cur merged
  work_dir > /dev/null
  cur="${WORK_DIR}/dns-info.json"
  merged="${WORK_DIR}/dns-allow.json"
  agh_get_json /control/dns_info > "$cur" || return 1
  DS_ALLOWED=$(printf '%s\n' "${ALLOWED_CIDRS[@]}")
  export DS_ALLOWED
  python3 - "$cur" > "$merged" <<'PY'
import json, os, sys

cur = json.load(open(sys.argv[1]))
cur["allowed_clients"] = [x for x in os.environ.get("DS_ALLOWED", "").split("\n") if x.strip()]
json.dump(cur, sys.stdout)
PY
  agh_post_json /control/dns_config "$(cat "$merged")" > /dev/null \
    || die "AdGuard Home rejected the allowlist."
  say "Client allowlist updated."
}

agh_apply_tls() {
  local body resp
  body=$(printf '{"enabled":true,"server_name":"%s","force_https":false,"port_https":%s,"port_dns_over_tls":%s,"port_dns_over_quic":%s,"port_dnscrypt":0,"certificate_path":"%s","private_key_path":"%s","certificate_chain":"","private_key":"","dnscrypt_config_file":"","strict_sni_check":false,"override_tls_ciphers":[]}' \
    "$DOMAIN" "$LOOPBACK_PORT" "$DOT_PORT" "$DOT_PORT" \
    "$(json_escape "$CERT_FULLCHAIN")" "$(json_escape "$CERT_PRIVKEY")")
  resp=$(agh_post_json /control/tls/configure "$body") || die "AdGuard Home rejected the TLS settings."
  if [[ $resp == *'"valid_cert":false'* || $resp == *'"valid_key":false'* ]]; then
    die "AdGuard Home could not load the certificate: ${CERT_FULLCHAIN}"
  fi
  say "TLS enabled: DoH + panel on 127.0.0.1:${LOOPBACK_PORT}, DoT/DoQ on ${DOT_PORT}."
}

# Port the HTTPS listener actually ended up on (loopback), used by the relay.
detect_https_port() {
  local p i
  for ((i = 0; i < 10; i++)); do
    for p in "$LOOPBACK_PORT" "$PANEL_PORT" 443; do
      if curl -sk --max-time 5 -o /dev/null "https://127.0.0.1:${p}/" 2> /dev/null; then
        printf '%s\n' "$p"
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# AdGuard Home: DNS rewrites (the relay list)
# ---------------------------------------------------------------------------
agh_rewrite_current() {
  agh_get_json /control/rewrite/list | python3 -c '
import json, sys
try:
    rules = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for r in rules:
    print("{}|{}".format(r.get("domain", ""), r.get("answer", "")))
'
}

agh_rewrite_add() {
  local d=$1 a=$2
  agh_post_json /control/rewrite/add \
    "$(printf '{"domain":"%s","answer":"%s"}' "$(json_escape "$d")" "$(json_escape "$a")")" \
    > /dev/null || warn "Could not add rewrite ${d} -> ${a}"
}

agh_rewrite_del() {
  local d=$1 a=$2
  agh_post_json /control/rewrite/delete \
    "$(printf '{"domain":"%s","answer":"%s"}' "$(json_escape "$d")" "$(json_escape "$a")")" \
    > /dev/null || warn "Could not delete rewrite ${d} -> ${a}"
}

rewrite_answer() { # 4 or 6
  if [[ $1 == 4 ]]; then
    printf '%s\n' "$PUBLIC_IPV4"
  elif [[ -n $PUBLIC_IPV6 ]]; then
    printf '%s\n' "$PUBLIC_IPV6"
  else
    printf '::\n'
  fi
}

sync_rewrites() {
  local desired cur d a e ans
  work_dir > /dev/null
  desired="${WORK_DIR}/desired-rewrites.txt"
  cur="${WORK_DIR}/current-rewrites.txt"
  : > "$desired"

  if [[ $RELAY -eq 0 ]]; then
    say "Relay disabled (--no-relay); skipping DNS rewrites."
    return 0
  fi

  while IFS= read -r e; do
    [[ -n $e ]] || continue
    for ans in "$(rewrite_answer 4)" "$(rewrite_answer 6)"; do
      if [[ $e == '*.'* ]]; then
        printf '%s|%s\n' "$e" "$ans" >> "$desired"
      else
        printf '%s|%s\n' "$e" "$ans" >> "$desired"
        printf '*.%s|%s\n' "$e" "$ans" >> "$desired"
      fi
    done
  done < <(relay_domains)
  sort -u -o "$desired" "$desired"

  : > "$cur"
  agh_rewrite_current | sort -u > "$cur" || true
  touch "$MANAGED_FILE"

  # add what is missing (new entries and anything created outside this script)
  while IFS='|' read -r d a; do
    [[ -n $d && -n $a ]] || continue
    if ! grep -qxF "${d}|${a}" "$cur"; then
      agh_rewrite_add "$d" "$a"
    fi
  done < "$desired"

  # drop the entries this script added earlier that are no longer wanted
  while IFS='|' read -r d a; do
    [[ -n $d && -n $a ]] || continue
    if ! grep -qxF "${d}|${a}" "$desired"; then
      agh_rewrite_del "$d" "$a"
    fi
  done < "$MANAGED_FILE"

  cp "$desired" "$MANAGED_FILE"
  chmod 600 "$MANAGED_FILE"
  say "DNS rewrites applied: $(wc -l < "$desired") entries for $(relay_domains | wc -l) domains."
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
ufw_is_active() {
  command -v ufw > /dev/null 2>&1 || return 1
  local s
  s=$(ufw status 2> /dev/null) || return 1
  [[ $s == *'Status: active'* ]]
}

firewalld_is_active() {
  command -v firewall-cmd > /dev/null 2>&1 || return 1
  [[ $(firewall-cmd --state 2> /dev/null) == running ]]
}

open_firewall_rules() {
  local p
  if ufw_is_active; then
    for p in 53/tcp 53/udp 80/tcp 443/tcp 853/tcp 853/udp; do
      ufw allow "$p" > /dev/null 2>&1 || true
    done
    say "Opened 53/tcp+udp, 80, 443, 853/tcp+udp in ufw."
  fi
  if firewalld_is_active; then
    for p in 53/tcp 53/udp 80/tcp 443/tcp 853/tcp 853/udp; do
      firewall-cmd --permanent --add-port="$p" > /dev/null 2>&1 || true
    done
    firewall-cmd --reload > /dev/null 2>&1 || true
    say "Opened 53/tcp+udp, 80, 443, 853/tcp+udp in firewalld."
  fi
}

# ---------------------------------------------------------------------------
# State and info files
# ---------------------------------------------------------------------------
save_state() {
  install -d -m 700 "$DS_DIR"
  local tmp
  tmp=$(mktemp)
  {
    printf '# dns-setup state, generated %s\n' "$(date -Is)"
    printf "DS_DOMAIN='%s'\n" "$DOMAIN"
    printf "DS_PUBLIC_IPV4='%s'\n" "$PUBLIC_IPV4"
    printf "DS_PUBLIC_IPV6='%s'\n" "$PUBLIC_IPV6"
    printf "DS_LOOPBACK_PORT='%s'\n" "$LOOPBACK_PORT"
    printf "DS_PANEL_PORT='%s'\n" "$PANEL_PORT"
    printf "DS_RELAY='%s'\n" "$RELAY"
    printf "DS_DISABLE_AAAA='%s'\n" "$DISABLE_AAAA"
    printf "DS_STAGING='%s'\n" "$STAGING"
    printf "DS_EMAIL='%s'\n" "$EMAIL"
  } > "$tmp"
  install -m 600 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

load_state() {
  if [[ ! -r $STATE_FILE ]]; then
    warn "No state file at ${STATE_FILE}; run the installer first."
    return 1
  fi
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  DOMAIN="${DS_DOMAIN:-}"
  PUBLIC_IPV4="${DS_PUBLIC_IPV4:-}"
  PUBLIC_IPV6="${DS_PUBLIC_IPV6:-}"
  LOOPBACK_PORT="${DS_LOOPBACK_PORT:-$LOOPBACK_PORT}"
  PANEL_PORT="${DS_PANEL_PORT:-$PANEL_PORT}"
  RELAY="${DS_RELAY:-1}"
  DISABLE_AAAA="${DS_DISABLE_AAAA:-0}"
  STAGING="${DS_STAGING:-0}"
  EMAIL="${DS_EMAIL:-$EMAIL}"
  set_cert_paths
  ALLOWED_CIDRS=()
  if [[ -r $ALLOWED_FILE ]]; then
    while IFS= read -r c; do
      [[ -n $c ]] && ALLOWED_CIDRS+=("$c")
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOWED_FILE" | grep -v '^$')
  fi
  if [[ -r $INFO_FILE ]]; then
    # shellcheck disable=SC1090
    . "$INFO_FILE" || true
    ADMIN_USER="${DNS_AGH_USER:-${ADMIN_USER:-}}"
    ADMIN_PASS="${DNS_AGH_PASS:-${ADMIN_PASS:-}}"
  fi
  AGH_URL="http://127.0.0.1:${PANEL_PORT}"
  return 0
}

save_info() {
  local tmp panel doh dot
  panel="https://${DOMAIN}/"
  doh="https://${DOMAIN}/dns-query"
  dot="${DOMAIN}"
  tmp=$(mktemp)
  {
    printf '# dns-setup client info, generated %s\n' "$(date -Is)"
    printf "DNS_DOMAIN='%s'\n" "$DOMAIN"
    printf "DNS_PANEL_URL='%s'\n" "$panel"
    printf "DNS_AGH_USER='%s'\n" "$ADMIN_USER"
    printf "DNS_AGH_PASS='%s'\n" "$ADMIN_PASS"
    printf "DNS_DOH_URL='%s'\n" "$doh"
    printf "DNS_DOT_HOST='%s'\n" "$dot"
    printf "DNS_PLAIN_IP='%s'\n" "$PUBLIC_IPV4"
    printf "DNS_STAMP_DOH='%s'\n" "$(dns_stamp doh)"
    printf "DNS_STAMP_DOT='%s'\n" "$(dns_stamp dot)"
    printf "DNS_STAMP_PLAIN='%s'\n" "$(dns_stamp plain)"
    printf "DNS_CERT='%s'\n" "$CERT_FULLCHAIN"
  } > "$tmp"
  install -m 600 "$tmp" "$INFO_FILE"
  rm -f "$tmp"
}

# DNS stamps (sdns://) for Android/iOS clients and routers.
dns_stamp() { # doh|dot|plain
  DOMAIN="$DOMAIN" PUBLIC_IPV4="$PUBLIC_IPV4" DS_STAMP_KIND="$1" DNS_PORT="$DNS_PORT" python3 - <<'PY'
import base64, os, struct, sys

kind = os.environ["DS_STAMP_KIND"]
domain = os.environ["DOMAIN"]
ip = os.environ.get("PUBLIC_IPV4", "")
port = os.environ.get("DNS_PORT", "53")
path = "/dns-query"

def lp(data):
    if isinstance(data, str):
        data = data.encode()
    return bytes([len(data)]) + data

props = struct.pack("<Q", 0)

if kind == "doh":
    body = b"\x02" + props + lp("") + lp("") + lp(domain) + lp(path)
elif kind == "dot":
    body = b"\x03" + props + lp("") + lp("") + lp(domain)
else:
    body = b"\x00" + props + lp("{}:{}".format(ip, port)) + lp("")

sys.stdout.write("sdns://" + base64.urlsafe_b64encode(body).decode().rstrip("="))
PY
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify_doh() {
  local body
  body=$(curl -sS --max-time 12 --resolve "${DOMAIN}:443:127.0.0.1" \
    -H 'accept: application/dns-json' \
    "https://${DOMAIN}/dns-query?name=example.com&type=A" 2> /dev/null || true)
  [[ $body == *'"Answer"'* ]]
}

verify_dot() {
  local out
  out=$(timeout 6 openssl s_client -connect "127.0.0.1:${DOT_PORT}" -servername "$DOMAIN" \
    < /dev/null 2> /dev/null) || true
  [[ $out == *'Verify return code: 0'* ]]
}

verify_relay() {
  local d=$1 code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    --resolve "${d}:443:127.0.0.1" "https://${d}/" 2> /dev/null || true)
  [[ $code =~ ^[23][0-9][0-9]$ ]]
}

verify_rewrite() {
  local d=$1 body
  body=$(curl -sS --max-time 12 --resolve "${DOMAIN}:443:127.0.0.1" \
    -H 'accept: application/dns-json' \
    "https://${DOMAIN}/dns-query?name=${d}&type=A" 2> /dev/null || true)
  body=${body//[[:space:]]/}
  [[ $body == *"\"data\":\"${PUBLIC_IPV4}\""* ]]
}

# Does any relay entry cover this hostname?
relay_matches_host() {
  local h=$1 e
  while IFS= read -r e; do
    if [[ $e == '*.'* ]]; then
      [[ $h == *".${e#\*.}" ]] && return 0
    else
      [[ $h == "$e" || $h == *".${e}" ]] && return 0
    fi
  done < <(relay_domains)
  return 1
}

run_checks() {
  local failures=0 probe="" c
  local candidates=(registry.npmjs.org pypi.org huggingface.co github.com docker.io steampowered.com)

  if verify_doh; then
    say "DoH through nginx ..... OK"
  else
    warn "DoH through nginx ..... FAILED"
    failures=$((failures + 1))
  fi

  if verify_dot; then
    say "DoT (853) ............. OK"
  else
    warn "DoT (853) ............. FAILED"
    failures=$((failures + 1))
  fi

  if [[ $RELAY -eq 1 ]]; then
    for c in "${candidates[@]}"; do
      relay_matches_host "$c" || continue
      if verify_relay "$c"; then
        probe=$c
        break
      fi
    done
    if [[ -n $probe ]]; then
      say "TLS relay ............. OK (${probe})"
      if verify_rewrite "$probe"; then
        say "DNS rewrite ........... OK (${probe} -> ${PUBLIC_IPV4})"
      else
        warn "DNS rewrite ........... FAILED (${probe} -> ${PUBLIC_IPV4})"
        failures=$((failures + 1))
      fi
    else
      warn "TLS relay ............. FAILED (no relayed host answered)"
      failures=$((failures + 1))
    fi
  fi

  return "$failures"
}

# ---------------------------------------------------------------------------
# Relay list seeding
# ---------------------------------------------------------------------------
seed_default_list() {
  install -d -m 700 "$DS_DIR"
  [[ -s $DOMAINS_FILE ]] && return 0
  cat > "$DOMAINS_FILE" <<'EOF'
# dns-setup relay list
#
# Every domain here is answered with THIS server's address and then relayed by
# TLS SNI, so services that geo-block Iranian IPs (or are blocked by IP in
# Iran) keep working. A bare domain also covers its subdomains; "*.example.com"
# covers subdomains only.
#
#   dnsctl add    example.com      add one or more domains
#   dnsctl remove example.com      remove them
#   dnsctl import <file|url>       bulk-add a community list
#   dnsctl sync                    re-apply after editing this file by hand
#
# The list is also visible and editable in the panel's DNS rewrites page.
# The relay does not hide the TLS SNI, so sites filtered inside Iran by SNI
# still need a proxy; here we fix geo-blocks and IP-based blocks.
# Delete the categories you do not use.

# ---- package registries / build tooling --------------------------------
npmjs.org
npmjs.com
yarnpkg.com
nodejs.org
nodesource.com
pypi.org
pythonhosted.org
python.org
anaconda.org
anaconda.com
crates.io
rust-lang.org
rustup.rs
golang.org
go.dev
gopkg.in
rubygems.org
packagist.org
getcomposer.org
nuget.org
maven.org
mvnrepository.com
repo.maven.apache.org
gradle.org
jitpack.io
bazel.build
hex.pm
pub.dev
dart.dev
flutter.dev
deno.land

# ---- AI / machine learning ---------------------------------------------
huggingface.co
hf.co
pytorch.org
tensorflow.org
kaggle.com
kaggleusercontent.com
wandb.ai
storage.googleapis.com
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
anthropic.com
claude.ai
perplexity.ai
deepmind.com
aistudio.google.com
generativelanguage.googleapis.com
colab.research.google.com

# ---- source hosts, CI and hosting --------------------------------------
github.com
githubusercontent.com
githubassets.com
github.io
ghcr.io
gitlab.com
gitlab.io
bitbucket.org
atlassian.com
atlassian.net
travis-ci.com
heroku.com
vercel.com
firebase.com
firebase.google.com
firebaseio.com
expo.dev

# ---- containers / cloud / devops ---------------------------------------
docker.com
docker.io
dockerhub.com
quay.io
gcr.io
k8s.io
kubernetes.io
registry.k8s.io
helm.sh
terraform.io
hashicorp.com
releases.hashicorp.com
aws.amazon.com
amazonaws.com
cloud.google.com
dl.google.com
maven.google.com
play.google.com
azure.com
visualstudio.com
digitalocean.com
linode.com
vultr.com
hetzner.com
hetzner.cloud
paperspace.com
namecheap.com
godaddy.com
grafana.com
grafana.net
elastic.co
sentry.io
mongodb.com
redis.io
mysql.com
mariadb.com

# ---- games, stores and launchers ---------------------------------------
steampowered.com
steamcommunity.com
steamstatic.com
steamcontent.com
steamusercontent.com
s.team
epicgames.com
epicgames.dev
epicgamescdn.com
unrealengine.com
fortnite.com
easyanticheat.net
ea.com
origin.com
ubi.com
ubisoft.com
uplay.com
ubisoftconnect.com
battle.net
blizzard.com
riotgames.com
leagueoflegends.com
riotcdn.net
valorant.com
rockstargames.com
rockstar.com
bungie.net
bungie.com
playstation.com
playstation.net
xbox.com
xboxlive.com
nintendo.com
nintendo.net
roblox.com
rbxcdn.com
minecraft.net
mojang.com
gog.com
gog-statics.com
warframe.com
digitalextremes.com
rocketleague.com
psyonix.com
activision.com
callofduty.com
respawn.com
garena.com
garenanow.com
supercell.com
geforce.com
nvidia.com
amd.com
intel.com

# ---- microsoft / adobe / mathworks --------------------------------------
microsoft.com
office.com
live.com
skype.com
adobe.com
adobelogin.com
adobeexchange.com
unity.com
unity3d.com
jetbrains.com
mathworks.com

# ---- design and productivity -------------------------------------------
figma.com
miro.com
notion.so
trello.com
slack.com
zoom.us
webex.com
grammarly.com
quillbot.com
wordtune.com
zeplin.io
invisionapp.com
remove.bg
tinypng.com
ilovepdf.com
convertio.co
freepik.com
envato.com
themeforest.net
graphicriver.net
flaticon.com
canva.com
medium.com
dev.to
wakatime.com
gitkraken.com
postman.com
tabnine.com
codepen.io
codesandbox.io
replit.com
gitpod.io
godbolt.org
overleaf.com

# ---- learning -----------------------------------------------------------
coursera.org
udemy.com
edx.org
khanacademy.org
datacamp.com
freecodecamp.org
teamtreehouse.com
pluralsight.com
packtpub.com
oreilly.com

# ---- payments and accounts ---------------------------------------------
paypal.com
paypalobjects.com
stripe.com
binance.com
coinbase.com
EOF
  chmod 600 "$DOMAINS_FILE"
  say "Seeded the relay list ($(relay_domains | wc -l) domains) at ${DOMAINS_FILE}."
}

seed_custom_list() {
  local src=$1 d
  [[ -r $src ]] || die "Cannot read the relay list: ${src}"
  install -d -m 700 "$DS_DIR"
  : > "${DOMAINS_FILE}.tmp"
  while IFS= read -r d; do
    d=${d%%#*}
    [[ -n ${d// /} ]] || continue
    d=$(normalize_list_domain "$d") || {
      warn "Skipping invalid entry: ${d}"
      continue
    }
    printf '%s\n' "$d" >> "${DOMAINS_FILE}.tmp"
  done < "$src"
  sort -u -o "${DOMAINS_FILE}.tmp" "${DOMAINS_FILE}.tmp"
  install -m 600 "${DOMAINS_FILE}.tmp" "$DOMAINS_FILE"
  rm -f "${DOMAINS_FILE}.tmp"
  say "Loaded $(relay_domains | wc -l) domains from ${src}."
}

# ---------------------------------------------------------------------------
# Summary / client info
# ---------------------------------------------------------------------------
ensure_qrencode() {
  command -v qrencode > /dev/null 2>&1 && return 0
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq qrencode > /dev/null 2>&1 || true
  command -v qrencode > /dev/null 2>&1
}

print_qr() {
  local data=$1
  if ensure_qrencode; then
    if ! qrencode -t UTF8 -m 2 -l M "$data"; then
      warn "Could not render the QR code; the value is printed above."
    fi
  else
    warn "qrencode is not installed; skipping the QR code."
  fi
}

print_client_info() {
  local stamp_doh stamp_dot stamp_plain expires
  stamp_doh=$(dns_stamp doh)
  stamp_dot=$(dns_stamp dot)
  stamp_plain=$(dns_stamp plain)
  expires=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires="unknown"

  printf '\n'
  printf '==============================================================\n'
  printf ' Client settings\n'
  printf '==============================================================\n'
  printf ' Android (Private DNS) : %s\n' "$DOMAIN"
  printf ' DoH URL               : https://%s/dns-query\n' "$DOMAIN"
  printf ' DoT host              : %s (port %s)\n' "$DOMAIN" "$DOT_PORT"
  printf ' Plain DNS             : %s (port %s)\n' "${PUBLIC_IPV4:-this server}" "$DNS_PORT"
  printf '%s\n' '--------------------------------------------------------------'
  printf ' DNS stamp (DoH)       : %s\n' "$stamp_doh"
  printf ' DNS stamp (DoT)       : %s\n' "$stamp_dot"
  printf ' DNS stamp (plain)     : %s\n' "$stamp_plain"
  printf ' Certificate expires   : %s\n' "${expires:-unknown}"
  printf '%s\n' '--------------------------------------------------------------'
  printf ' Clients: Intra / RethinkDNS / AdGuard (stamps), Nebulo, DNSCloak,\n'
  printf ' YogaDNS, or the system resolver (Android Private DNS = DoT above).\n'
  printf '\n QR: DoH stamp\n'
  print_qr "$stamp_doh"
  printf '==============================================================\n'
}

print_summary() {
  local expires count
  expires=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires="unknown"
  count=$(relay_domains | wc -l)

  printf '\n'
  printf '==============================================================\n'
  printf ' Anti-sanction DNS is ready\n'
  printf '==============================================================\n'
  printf ' Panel URL   : https://%s/\n' "$DOMAIN"
  printf ' Username    : %s\n' "$ADMIN_USER"
  printf ' Password    : %s\n' "$ADMIN_PASS"
  printf ' DoH URL     : https://%s/dns-query\n' "$DOMAIN"
  printf ' DoT host    : %s:%s\n' "$DOMAIN" "$DOT_PORT"
  printf ' Plain DNS   : %s:%s\n' "${PUBLIC_IPV4:-?}" "$DNS_PORT"
  printf ' Certificate : %s\n' "$CERT_FULLCHAIN"
  printf ' Expires     : %s\n' "${expires:-unknown}"
  printf ' Relay list  : %s domains (%s)\n' "$count" "$DOMAINS_FILE"
  printf ' In panel    : DNS rewrites page (one entry per domain)\n'
  printf ' Info file   : %s\n' "$INFO_FILE"
  printf '%s\n' '--------------------------------------------------------------'
  if [[ $RELAY -eq 1 ]]; then
    printf ' Traffic for the relayed domains leaves this server; everything\n'
    printf ' else keeps going straight from the client.\n'
  else
    printf ' Relay disabled (--no-relay): this is a plain encrypted DNS server.\n'
  fi
  printf '\n Open in your provider firewall: TCP 53, 80, 443, 853 + UDP 53, 853.\n'
  printf ' Manage the list with: dnsctl add|remove <domain>, dnsctl status\n'
  printf '==============================================================\n'
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
parse_args() {
  while (($# > 0)); do
    case "$1" in
      -d | --domain)
        (($# >= 2)) || die "Option $1 needs a value."
        DOMAIN="$2"
        shift 2
        ;;
      -e | --email)
        (($# >= 2)) || die "Option $1 needs a value."
        EMAIL="$2"
        shift 2
        ;;
      --skip-dns-check)
        SKIP_DNS=1
        shift
        ;;
      --open-firewall)
        OPEN_FIREWALL=1
        shift
        ;;
      --no-relay)
        RELAY=0
        shift
        ;;
      --relay-list)
        (($# >= 2)) || die "Option $1 needs a value."
        CUSTOM_LIST="$2"
        shift 2
        ;;
      --upstream)
        (($# >= 2)) || die "Option $1 needs a value."
        if ((UPSTREAMS_SET == 0)); then
          UPSTREAMS=()
          UPSTREAMS_SET=1
        fi
        UPSTREAMS+=("$2")
        shift 2
        ;;
      --ir-upstream)
        (($# >= 2)) || die "Option $1 needs a value."
        IR_UPSTREAM="$2"
        shift 2
        ;;
      --disable-aaaa)
        DISABLE_AAAA=1
        shift
        ;;
      --allow-cidr)
        (($# >= 2)) || die "Option $1 needs a value."
        ALLOWED_CIDRS+=("$2")
        shift 2
        ;;
      --admin-user)
        (($# >= 2)) || die "Option $1 needs a value."
        ADMIN_USER="$2"
        shift 2
        ;;
      --admin-pass)
        (($# >= 2)) || die "Option $1 needs a value."
        ADMIN_PASS="$2"
        shift 2
        ;;
      --loopback-port)
        (($# >= 2)) || die "Option $1 needs a value."
        LOOPBACK_PORT="$2"
        shift 2
        ;;
      --staging)
        STAGING=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1 (try --help)."
        ;;
      *)
        [[ -z $DOMAIN ]] || die "Only one domain can be passed."
        DOMAIN="$1"
        shift
        ;;
    esac
  done
}

resolve_domain() {
  if [[ -z $DOMAIN ]]; then
    [[ -t 0 ]] || die "No domain given. Usage: bash $0 dns.example.com"
    printf 'Domain for DNS/DoH/panel (e.g. dns.example.com): '
    read -r DOMAIN || die "No input."
  fi
  DOMAIN=$(normalize_domain "$DOMAIN")
  if [[ -z $DOMAIN ]] || ! is_domain "$DOMAIN"; then
    die "Invalid domain '${DOMAIN}'. Use something like dns.example.com."
  fi
}

prepare_credentials() {
  if [[ -r $INFO_FILE ]]; then
    # shellcheck disable=SC1090
    . "$INFO_FILE" || true
    [[ -n ${DNS_AGH_USER:-} && -z $ADMIN_USER ]] && ADMIN_USER="$DNS_AGH_USER"
    [[ -n ${DNS_AGH_PASS:-} && -z $ADMIN_PASS ]] && ADMIN_PASS="$DNS_AGH_PASS"
  fi
  [[ -n $ADMIN_USER ]] || ADMIN_USER="admin"
  [[ -n $ADMIN_PASS ]] || ADMIN_PASS=$(rand_hex 12)
}

install_adguard_and_configure() {
  install_adguard
  start_adguard
  AGH_URL="http://127.0.0.1:${PANEL_PORT}"

  if agh_needs_setup; then
    agh_setup_wizard
  elif [[ $FORCE -eq 1 && -f ${AGH_DIR}/AdGuardHome.yaml ]]; then
    say "Re-running the AdGuard Home setup wizard (--force) ..."
    mv "${AGH_DIR}/AdGuardHome.yaml" "${AGH_DIR}/AdGuardHome.yaml.bak.$(date +%s)"
    systemctl restart "$AGH_UNIT" || die "Could not restart AdGuard Home."
    wait_port "$PANEL_PORT" tcp 60 || die "AdGuard Home did not come back."
    agh_setup_wizard
  elif ! agh_login; then
    die "AdGuard Home is already configured but the stored credentials do not work.
     Fix the user in ${AGH_DIR}/AdGuardHome.yaml, or delete that file and re-run with --force."
  else
    say "AdGuard Home is already configured; reusing the existing admin account."
  fi
}

install_all() {
  parse_args "$@"
  resolve_domain
  EMAIL="${EMAIL:-admin@${DOMAIN}}"
  setup_logging
  trap '_on_err $LINENO' ERR

  say "=== dns-setup ${SCRIPT_VERSION}: AdGuard Home + SNI relay ==="
  say "domain : ${DOMAIN}"
  if [[ $RELAY -eq 1 ]]; then
    say "relay  : enabled"
  else
    say "relay  : disabled"
  fi

  load_os
  ensure_packages
  precheck_disk
  precheck_dns
  precheck_3xui
  fix_systemd_resolved
  precheck_ports

  PUBLIC_IPV6=$(detect_ipv6) || PUBLIC_IPV6=""
  if [[ -n $PUBLIC_IPV6 ]]; then
    say "IPv6 detected: ${PUBLIC_IPV6}"
  else
    warn "No usable IPv6 here: relayed domains answer AAAA with '::' so dual-stack
     clients fall back to IPv4. Use --disable-aaaa for an empty AAAA answer."
  fi

  if [[ -z $PUBLIC_IPV4 ]]; then
    PUBLIC_IPV4=$(ip -4 route get 1.1.1.1 2> /dev/null \
      | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}') || true
  fi
  [[ -n $PUBLIC_IPV4 ]] || die "Could not determine this server's public IPv4."

  set_cert_paths
  prepare_credentials

  # --- nginx first: port 80 is needed for the ACME challenge --------------
  ensure_nginx_stream
  disable_stock_site
  ensure_nginx_include
  render_nginx_http
  apply_nginx

  # --- certificate --------------------------------------------------------
  obtain_certificate || die "Could not obtain a certificate for ${DOMAIN}."
  install_renew_hook

  # --- AdGuard Home -------------------------------------------------------
  install_adguard_and_configure
  AGH_URL="http://127.0.0.1:${PANEL_PORT}"
  agh_login || die "Cannot log in to the AdGuard Home API."

  if ((${#UPSTREAMS[@]} == 0)); then
    UPSTREAMS=("https://cloudflare-dns.com/dns-query" "https://dns.quad9.net/dns-query")
  fi
  [[ -n $IR_UPSTREAM ]] && UPSTREAMS+=("[/ir/]${IR_UPSTREAM}")
  BOOTSTRAPS=("9.9.9.9" "1.1.1.1" "8.8.8.8")

  if ((${#ALLOWED_CIDRS[@]} > 0)); then
    install -d -m 700 "$DS_DIR"
    printf '%s\n' "${ALLOWED_CIDRS[@]}" > "$ALLOWED_FILE"
    chmod 600 "$ALLOWED_FILE"
  fi
  ALLOWED_CIDRS=("127.0.0.1" "::1")
  if [[ -r $ALLOWED_FILE ]]; then
    while IFS= read -r c; do
      [[ -n $c ]] && ALLOWED_CIDRS+=("$c")
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOWED_FILE" | grep -v '^$')
  fi
  if ((${#ALLOWED_CIDRS[@]} > 2)); then
    say "Client allowlist is active (${ALLOWED_FILE})."
  else
    ALLOWED_CIDRS=()
  fi

  agh_apply_dns
  agh_apply_tls

  # --- relay: follow the port AdGuard really listens on -------------------
  local real_port
  if real_port=$(detect_https_port); then
    if [[ -n $real_port && $real_port != "$LOOPBACK_PORT" ]]; then
      warn "AdGuard Home serves HTTPS on ${real_port}, not ${LOOPBACK_PORT}; pointing nginx there."
      LOOPBACK_PORT="$real_port"
    fi
  else
    warn "Could not reach the AdGuard Home HTTPS listener on loopback; keeping port ${LOOPBACK_PORT}."
  fi

  seed_default_list
  [[ -n $CUSTOM_LIST ]] && seed_custom_list "$CUSTOM_LIST"
  if [[ $RELAY -eq 1 ]]; then
    sync_rewrites
    render_nginx_stream
    render_nginx_http
    apply_nginx
  fi

  if [[ $OPEN_FIREWALL -eq 1 ]]; then
    open_firewall_rules
  else
    warn "Firewall not touched. Open TCP 53/80/443/853 and UDP 53/853 (or use --open-firewall)."
  fi

  install_self
  save_state
  save_info
  chmod 600 "$COOKIE_FILE" 2> /dev/null || true

  print_summary
  print_client_info

  if ! run_checks; then
    warn "Some checks failed; see the messages above and ${LOG_FILE}."
  fi
}

install_self() {
  local src
  src=$(readlink -f "$0" 2> /dev/null || printf '%s' "$0")
  case "$src" in
    /dev/fd/* | /proc/* | /dev/stdin)
      warn "Running from a pipe; skipping the dnsctl installation."
      return 0
      ;;
  esac
  [[ -f $src ]] || return 0
  install -m 755 "$src" /usr/local/sbin/dns-setup
  ln -sf /usr/local/sbin/dns-setup /usr/local/bin/dnsctl
  say "Installed /usr/local/bin/dnsctl."
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_add() {
  (($# > 0)) || die "Usage: dnsctl add <domain>..."
  local d
  load_state || exit 1
  if [[ $RELAY -eq 0 ]]; then
    die "The relay is disabled (installed with --no-relay). Re-run the installer without it."
  fi
  install -d -m 700 "$DS_DIR"
  for d in "$@"; do
    d=$(normalize_list_domain "$d") || die "Invalid domain: ${d}"
    if grep -qxF "$d" "$DOMAINS_FILE" 2> /dev/null; then
      say "${d} is already in the list."
      continue
    fi
    printf '%s\n' "$d" >> "$DOMAINS_FILE"
    say "Added ${d}."
  done
  sync_all
}

cmd_remove() {
  (($# > 0)) || die "Usage: dnsctl remove <domain>..."
  local d
  load_state || exit 1
  for d in "$@"; do
    d=$(normalize_list_domain "$d") || die "Invalid domain: ${d}"
    if grep -qxF "$d" "$DOMAINS_FILE" 2> /dev/null; then
      awk -v d="$d" '$0 != d' "$DOMAINS_FILE" > "${DOMAINS_FILE}.tmp"
      mv "${DOMAINS_FILE}.tmp" "$DOMAINS_FILE"
      say "Removed ${d}."
    else
      warn "${d} is not in the list."
    fi
  done
  sync_all
}

cmd_import() {
  local force=0 src tmp d seen=0 added=0 total
  local srcs=()
  if (($# == 0)); then
    die "Usage: dnsctl import [--force] <file-or-url>..."
  fi
  load_state || exit 1
  if [[ $RELAY -eq 0 ]]; then
    die "The relay is disabled (installed with --no-relay)."
  fi
  for src in "$@"; do
    if [[ $src == --force ]]; then
      force=1
      continue
    fi
    srcs+=("$src")
  done
  ((${#srcs[@]} > 0)) || die "Usage: dnsctl import [--force] <file-or-url>..."

  install -d -m 700 "$DS_DIR"
  tmp=$(mktemp)
  for src in "${srcs[@]}"; do
    if [[ $src =~ ^https?:// ]]; then
      say "Downloading ${src} ..."
      curl -fsSL --max-time 180 "$src" > "$tmp" || die "Could not download ${src}."
    else
      [[ -r $src ]] || die "Cannot read ${src}."
      cat "$src" > "$tmp"
    fi
    while IFS= read -r d; do
      d=${d%%#*}
      d=$(printf '%s' "$d" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
        -e 's/^\|\|//' -e 's/\^.*//' -e 's/^[0-9.]+[[:space:]]+//')
      [[ -n $d ]] || continue
      d=$(normalize_list_domain "$d" 2> /dev/null) || continue
      seen=$((seen + 1))
      if grep -qxF "$d" "$DOMAINS_FILE" 2> /dev/null; then
        continue
      fi
      printf '%s\n' "$d" >> "$DOMAINS_FILE"
      added=$((added + 1))
    done < "$tmp"
  done
  rm -f "$tmp"

  total=$(relay_domains | wc -l)
  if ((total > 600)) && ((force == 0)); then
    warn "The list now holds ${total} domains. Each one adds up to four DNS"
    warn "rewrites and sends that traffic through this server."
    die "Re-run with --force if that is really what you want."
  fi
  say "Imported ${added} new domain(s) from ${seen} line(s); list size: ${total}."
  sync_all
}

cmd_list() {
  load_state || exit 1
  local count
  count=$(relay_domains | wc -l)
  printf 'Relay list (%s domains) from %s:\n' "$count" "$DOMAINS_FILE"
  relay_domains | sed 's/^/  /'
}

cmd_sync() {
  load_state || exit 1
  sync_all
}

sync_all() {
  AGH_URL="http://127.0.0.1:${PANEL_PORT}"
  agh_login || die "Cannot log in to the AdGuard Home API (see ${INFO_FILE})."
  sync_rewrites
  render_nginx_stream
  render_nginx_http
  apply_nginx
  say "Done."
}

cmd_allow() {
  load_state || exit 1
  local c
  install -d -m 700 "$DS_DIR"
  if (($# == 0)); then
    if [[ -r $ALLOWED_FILE ]] && [[ -s $ALLOWED_FILE ]]; then
      printf 'Allowed client networks (%s):\n' "$ALLOWED_FILE"
      sed 's/^/  /' "$ALLOWED_FILE"
    else
      printf 'No allowlist: every client on the internet may query this DNS.\n'
      printf 'Restrict it with: dnsctl allow 203.0.113.0/24\n'
    fi
    return 0
  fi
  if [[ ${1-} == "--clear" ]]; then
    rm -f "$ALLOWED_FILE"
    say "Allowlist cleared: the resolver is public again."
  else
    for c in "$@"; do
      [[ $c =~ ^[0-9a-fA-F:./]+$ ]] || die "Invalid network: ${c}"
      grep -qxF "$c" "$ALLOWED_FILE" 2> /dev/null || printf '%s\n' "$c" >> "$ALLOWED_FILE"
    done
    chmod 600 "$ALLOWED_FILE"
    say "Allowlisted: $*"
  fi

  agh_login || die "Cannot log in to the AdGuard Home API."
  ALLOWED_CIDRS=()
  if [[ -r $ALLOWED_FILE ]]; then
    while IFS= read -r c; do
      [[ -n $c ]] && ALLOWED_CIDRS+=("$c")
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOWED_FILE" | grep -v '^$')
  fi
  if ((${#ALLOWED_CIDRS[@]} > 0)); then
    ALLOWED_CIDRS=("127.0.0.1" "::1" "${ALLOWED_CIDRS[@]}")
  fi
  agh_apply_allowlist
}

cmd_status() {
  load_state || exit 1
  AGH_URL="http://127.0.0.1:${PANEL_PORT}"
  local ok="no" ver="?"
  if agh_login 2> /dev/null; then
    ok="yes"
    ver=$(agh_get_json /control/status 2> /dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version","?"))' 2> /dev/null || printf '?')
  fi

  printf 'Domain      : %s\n' "$DOMAIN"
  printf 'AdGuard     : %s (v%s, API login: %s)\n' \
    "$(svc_active "$AGH_UNIT" && printf active || printf inactive)" "$ver" "$ok"
  printf 'nginx       : %s\n' "$(svc_active nginx && printf active || printf inactive)"
  printf 'Ports       : 53 %s | 80 %s | 443 %s | 853 %s\n' \
    "$(port_in_use 53 udp && printf up || printf down)" \
    "$(port_in_use 80 tcp && printf up || printf down)" \
    "$(port_in_use 443 tcp && printf up || printf down)" \
    "$(port_in_use "$DOT_PORT" tcp && printf up || printf down)"
  printf 'Relay       : %s domains\n' "$(relay_domains | wc -l)"
  if cert_valid; then
    printf 'Certificate : valid until %s\n' \
      "$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate | sed 's/^notAfter=//')"
  else
    printf 'Certificate : missing or invalid (%s)\n' "$CERT_FULLCHAIN"
  fi
  printf 'Panel       : https://%s/\n' "$DOMAIN"
  printf 'DoH         : https://%s/dns-query\n' "$DOMAIN"
  printf 'Log         : %s\n' "$LOG_FILE"
}

cmd_test() {
  load_state || exit 1
  if run_checks; then
    say "All checks passed."
    return 0
  fi
  warn "Some checks failed. Look at 'journalctl -u AdGuardHome -n 50' and ${LOG_FILE}."
  return 1
}

cmd_info() {
  load_state || exit 1
  if [[ -r $INFO_FILE ]]; then
    # shellcheck disable=SC1090
    . "$INFO_FILE"
  fi
  ADMIN_USER="${DNS_AGH_USER:-$ADMIN_USER}"
  ADMIN_PASS="${DNS_AGH_PASS:-$ADMIN_PASS}"
  print_client_info
}

cmd_renew() {
  load_state || exit 1
  certbot renew --cert-name "$DOMAIN" --force-renewal || die "certbot renew failed."
  systemctl reload nginx 2> /dev/null || true
  systemctl reload "$AGH_UNIT" 2> /dev/null || systemctl restart "$AGH_UNIT" 2> /dev/null || true
  say "Certificate renewed and services reloaded."
}

cmd_uninstall() {
  local ans=""
  if [[ ${1-} != "--yes" ]]; then
    printf 'This removes AdGuard Home, the nginx relay config and %s. Type "yes": ' "$DS_DIR"
    read -r ans || true
    [[ $ans == yes ]] || die "Aborted."
  fi

  say "Stopping AdGuard Home ..."
  systemctl disable --now "$AGH_UNIT" > /dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${AGH_UNIT}" "/lib/systemd/system/${AGH_UNIT}"
  systemctl daemon-reload 2> /dev/null || true
  rm -rf "$AGH_DIR"

  say "Removing the nginx configuration ..."
  rm -f "$NGINX_STREAM_CONF" "$NGINX_HTTP_CONF"
  if grep -qF "$NGINX_MARK" "$NGINX_MAIN" 2> /dev/null; then
    sed -i '/dns-setup: stream configs/,+1d' "$NGINX_MAIN"
  fi
  rm -f "$RENEW_HOOK"
  if nginx -t 2> /dev/null; then
    systemctl reload nginx > /dev/null 2>&1 || true
  fi

  say "Removing state ..."
  rm -f /usr/local/sbin/dns-setup /usr/local/bin/dnsctl
  rm -rf "$DS_DIR" "$INFO_FILE" "$COOKIE_FILE"
  if [[ -f /etc/resolv.conf.dns-setup.bak ]]; then
    cp -P /etc/resolv.conf.dns-setup.bak /etc/resolv.conf 2> /dev/null || true
    rm -f /etc/resolv.conf.dns-setup.bak
  fi
  rm -f /etc/systemd/resolved.conf.d/99-dns-setup.conf
  systemctl restart systemd-resolved > /dev/null 2>&1 || true

  say "Uninstalled. Certificates stay in ${DS_TLS_DIR}/${DOMAIN}; remove them with:"
  say "  certbot delete --cert-name ${DOMAIN}"
}

main() {
  case "${1-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac
  require_root "$@"
  local cmd=${1-}
  case "$cmd" in
    add | remove | import | list | sync | allow | status | test | info | renew | uninstall)
      shift
      "cmd_${cmd}" "$@"
      ;;
    *)
      install_all "$@"
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
