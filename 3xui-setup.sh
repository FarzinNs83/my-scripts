#!/usr/bin/env bash
# =============================================================================
#  3x-ui unattended installer + Let's Encrypt certificate + config set
#
#  What it does
#    1. answers every install.sh question automatically (unattended mode)
#    2. installs the latest 3x-ui release with SQLite and a random panel port
#    3. obtains a Let's Encrypt certificate for the given subdomain and points
#       the panel at it (the same code path as: x-ui -> 20 -> 1)
#    4. adds a config set through the panel API (one client, one subscription):
#         REALITY (Vision / XHTTP / XHTTP obfs / XHTTP packet-up / gRPC),
#         TLS (Vision / XHTTP / XHTTP over HTTP/3), Hysteria2, VLESS
#         Encryption (Sudoku / WS / XHTTP), Trojan (TLS / REALITY),
#         Shadowsocks-2022, and Cloudflare CDN (WS / HTTPUpgrade / gRPC /
#         XHTTP + clean IPs) when --cdn is given. Every config has a security
#         layer, which current Xray requires. Based on pdnczone/3x-ui-pro-configs.
#       Run it again later to add configs that are new since the last run:
#       the panel, the client and the existing inbounds are left alone.
#    5. tests every config, prints the panel URL, credentials and the
#       subscription links with a QR code; saves everything to a root-only file
#
#  It stops before touching the server when DNS or TCP/80 is not ready,
#  because Let's Encrypt cannot validate the domain in that case.
#
#  Sharing a server with dns-setup.sh / n8n-setup.sh: when nginx already owns
#  TCP/80, the certificate comes from certbot through a small nginx site for
#  the panel domain (no port 80 fight, renewals keep working). Without nginx,
#  acme.sh renews on TCP/80 and pauses nginx for those seconds if it shows up
#  later; re-running this script after the others moves it to certbot.
#
#  Usage:
#    bash 3xui-setup.sh panel.example.com
#    bash <(curl -Ls https://raw.githubusercontent.com/USER/REPO/main/3xui-setup.sh) panel.example.com
#    bash 3xui-setup.sh --open-firewall panel.example.com
#    bash 3xui-setup.sh --cdn cdn.example.com panel.example.com
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

PANEL_VERSION="${XUI_VERSION:-latest}" # "latest" or a tag such as v3.10.2
PANEL_REPO="${XUI_REPO:-MHSanaei/3x-ui}"
INSTALLER_URL="${XUI_INSTALLER_URL:-https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh}"
XUI_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
XUI_BIN="${XUI_DIR}/x-ui"
MENU_BIN="/usr/bin/x-ui"
INFO_FILE="${XUI_INFO_FILE:-/root/3xui-info.env}"
LOG_FILE="${XUI_LOG_FILE:-/var/log/3xui-setup.log}"
CERT_ROOT="/root/cert"

# Used only when nginx owns TCP/80 (dns-setup.sh / n8n-setup.sh on this server)
NGINX_CONF="${XUI_NGINX_CONF:-/etc/nginx/conf.d/3xui-setup.conf}"
ACME_ROOT="${XUI_ACME_ROOT:-/var/www/3xui-setup}"
LE_LIVE="/etc/letsencrypt/live"
LE_HOOK="/etc/letsencrypt/renewal-hooks/deploy/3xui-setup-restart.sh"
ACME_HOOK="/usr/local/sbin/3xui-acme-hook"
ACME_MODE="standalone" # standalone: acme.sh on TCP/80, nginx: certbot through nginx
ACME_PORT=""

DOMAIN=""
SKIP_DNS=0
FORCE_INSTALL=0
OPEN_FIREWALL=0

PANEL_USER=""
PANEL_PASS=""
PANEL_PORT=""
WEB_PATH=""
ACTUAL_PORT=""
ACTUAL_PATH=""
CERT_FILE=""
KEY_FILE=""

# Config set added after the panel is secured.
SKIP_INBOUNDS="${SKIP_INBOUNDS:-0}"
CDN_DOMAIN="${XUI_CDN_DOMAIN:-}"
CONFIG_LIST="${XUI_CONFIGS:-all}"
CLEAN_COUNT="${XUI_CLEAN_IPS:-20}"
CLEAN_IPS_URL="${XUI_CLEAN_IPS_URL:-https://raw.githubusercontent.com/pdnczone/3x-ui-pro-configs/main/clean-ips.txt}"
ADD_CONFIGS=0
NO_BBR=0
NO_TEST=0
INBOUND_FAILED=0
SUB_URL=""

# Filled in by the config step
PRO_EXISTING=0
PRO_SUB_URL=""
PRO_JSON_URL=""
PRO_SUB_ID=""
PRO_CLIENT=""
PRO_SUB_PORT=""
PRO_PORTS=""
PRO_COUNT=0
PRO_LINKS=0
PRO_TEST=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
3x-ui unattended installer + SSL + config set.

Usage:
  sudo bash 3xui-setup.sh [options] <subdomain>

Options:
  -d, --domain <name>   Panel subdomain (prompted once when omitted)
      --skip-dns-check  Do not verify that the subdomain points to this server
      --force-install   Reinstall/update to the newest release even if installed
      --open-firewall   Open panel, config and subscription ports in ufw/firewalld
      --acme-port <n>   Standalone certificate listener (default 80); other ports
                        use temporary TCP/80 forwarding, leaving 80/443 unbound
      --cdn <name>      Subdomain proxied by Cloudflare (orange cloud, SSL/TLS
                        Full) to this server; adds the CDN configs + clean IPs
      --configs <list>  "all" or a comma list of config keys (see below)
      --clean <n>       Cloudflare clean-IP links to add with --cdn (0-30)
      --add-configs     Create a second, separate set (new client) instead of
                        adding the missing configs to the existing client
      --no-inbounds     Do not add any configs
      --no-bbr          Do not enable BBR
      --no-test         Skip the end-to-end test of the new configs
  -h, --help            Show this help

Certificate:
  TCP/80 free       acme.sh (standalone, the x-ui default) in /root/cert/<domain>
  nginx on TCP/80   certbot through nginx (dns-setup.sh / n8n-setup.sh on the
                    same server) in /etc/letsencrypt/live/<domain>; use a
                    subdomain of its own, not the DNS or n8n one

Configs (added through the panel API at the end, one client for all):
  rv  REALITY Vision          TCP 443     main config
  rx  REALITY XHTTP           TCP 8443
  ro  REALITY XHTTP obfs      TCP 2443    XHTTP extra: obfuscated padding
  rp  REALITY XHTTP packet-up TCP 3443
  rg  REALITY gRPC            TCP 4443
  tv  TLS Vision              TCP 9443    + Fragment and IPv6 links
  tx  TLS XHTTP               TCP 2087    + Fragment link, CDN link with --cdn
  hy  Hysteria2 (Salamander)  UDP 443
  th  TLS XHTTP over HTTP/3   UDP 8443
  pq  VLESS Encryption+Sudoku TCP 10443   post-quantum
  ew  VLESS Encryption+WS     TCP 8880    no TLS; + Cloudflare HTTP link with --cdn
  ex  VLESS Encryption+XHTTP  TCP 2052    no TLS; + Cloudflare HTTP link with --cdn
  tt  Trojan TLS              TCP 14443
  tr  Trojan REALITY          TCP 14444
  ss  Shadowsocks-2022        TCP+UDP 8080
  ws  CDN WebSocket           TCP 2053    only with --cdn, + clean IPs
  hu  CDN HTTPUpgrade         TCP 2083    only with --cdn
  cg  CDN gRPC                TCP 2096    only with --cdn (gRPC on in Cloudflare)
  kc  VLESS Encryption+mKCP   UDP 9443    not in "all"; ask with --configs
A busy port moves the config to the next free one. Configs Xray rejects, and
ro/rp/cg/th/ew/ex/tt/tr/kc when they fail the end-to-end test, are removed
again. The subscription links (with a QR code) are printed at the end.

Re-running the script is the update path: it keeps the panel, the client and
every existing inbound, and adds only the configs the client does not have
yet, under the same subscription. --add-configs makes a second, separate set.

Environment:
  XUI_VERSION          panel version to install      (default: latest)
  XUI_INSTALLER_URL    install.sh URL                (default: upstream master)
  XUI_INFO_FILE        panel info file               (default: /root/3xui-info.env)
  XUI_LOG_FILE         log file                      (default: /var/log/3xui-setup.log)
  XUI_ACME_EMAIL       certbot account email         (default: none; nginx mode only)
  XUI_CDN_DOMAIN       same as --cdn
  XUI_CONFIGS          same as --configs             (default: all)
  XUI_CLEAN_IPS        same as --clean               (default: 20)
  XUI_CLEAN_IPS_URL    clean-IP list to test         (default: 3x-ui-pro-configs list)
  XUI_CLIENT_NAME      client name                   (default: random pineapple-XXXXXXXX)
  XUI_API_TOKEN        panel API token, used instead of the panel login
  SKIP_INBOUNDS        1 = skip config creation      (default: 0)

Examples:
  sudo bash 3xui-setup.sh panel.example.com
  sudo bash 3xui-setup.sh --open-firewall --cdn cdn.example.com panel.example.com
  sudo bash 3xui-setup.sh --configs rv,rx,tv,hy panel.example.com
EOF
}

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

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -d | --domain)
        (($# >= 2)) || die "Option $1 needs a value."
        DOMAIN="$2"
        shift 2
        ;;
      --skip-dns-check)
        SKIP_DNS=1
        shift
        ;;
      --force-install)
        FORCE_INSTALL=1
        shift
        ;;
      --open-firewall)
        OPEN_FIREWALL=1
        shift
        ;;
      --acme-port)
        ACME_PORT=${2:?Option --acme-port needs a value}
        shift 2
        ;;
      --no-inbounds)
        SKIP_INBOUNDS=1
        shift
        ;;
      --no-configs)
        SKIP_INBOUNDS=1
        shift
        ;;
      --cdn)
        (($# >= 2)) || die "Option $1 needs a value."
        CDN_DOMAIN="$2"
        shift 2
        ;;
      --configs)
        (($# >= 2)) || die "Option $1 needs a value."
        CONFIG_LIST="$2"
        shift 2
        ;;
      --clean)
        (($# >= 2)) || die "Option $1 needs a value."
        CLEAN_COUNT="$2"
        shift 2
        ;;
      --add-configs)
        ADD_CONFIGS=1
        shift
        ;;
      --no-bbr)
        NO_BBR=1
        shift
        ;;
      --no-test)
        NO_TEST=1
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
        [[ -z $DOMAIN ]] || die "Only one subdomain can be passed."
        DOMAIN="$1"
        shift
        ;;
    esac
  done
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

resolve_domain() {
  if [[ -z $DOMAIN ]]; then
    [[ -t 0 ]] || die "No subdomain given. Usage: bash $0 panel.example.com"
    printf 'Subdomain for the panel (e.g. panel.example.com): '
    read -r DOMAIN || die "No input."
  fi
  DOMAIN=$(normalize_domain "$DOMAIN")
  if [[ -z $DOMAIN ]] || ! is_domain "$DOMAIN"; then
    die "Invalid domain '${DOMAIN}'. Use a subdomain such as panel.example.com."
  fi
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

ensure_prereqs() {
  local missing=() cmd
  for cmd in curl openssl tar python3; do
    command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
  done
  command -v ss > /dev/null 2>&1 || missing+=(iproute2)
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  say "Installing required packages: ${missing[*]}"
  if ! command -v apt-get > /dev/null 2>&1; then
    die "Missing commands: ${missing[*]}. Install them and re-run."
  fi
  apt-get -o DPkg::Lock::Timeout=120 update -qq || die "apt-get update failed."
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq ca-certificates "${missing[@]}" \
    || die "Could not install: ${missing[*]}"
}

# os-release defines VERSION, NAME, ID, ... -- read it in a subshell so it
# cannot overwrite this script's variables.
load_os() {
  local f pretty
  for f in /etc/os-release /usr/lib/os-release; do
    [[ -r $f ]] || continue
    # shellcheck disable=SC1090
    pretty=$(. "$f" && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
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

port_in_use() {
  local p=$1
  if command -v ss > /dev/null 2>&1; then
    ss -ltn 2> /dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
  elif command -v netstat > /dev/null 2>&1; then
    netstat -ltn 2> /dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
  else
    return 1
  fi
}

pick_panel_port() {
  local p
  for _ in {1..100}; do
    p=$((20000 + (RANDOM % 20000)))
    if ! port_in_use "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

public_ipv4() {
  local url ip
  for url in \
    https://api4.ipify.org \
    https://ipv4.icanhazip.com \
    https://v4.api.ipinfo.io/ip \
    https://4.ident.me; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2> /dev/null | tr -d '[:space:]"') || true
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

resolve_ipv4() {
  local d=$1 ip=""
  if command -v getent > /dev/null 2>&1; then
    ip=$(getent ahostsv4 "$d" 2> /dev/null | awk 'NR == 1 {print $1}') || true
  fi
  if [[ -z $ip ]] && command -v dig > /dev/null 2>&1; then
    ip=$(dig +short A "$d" 2> /dev/null | awk 'NR == 1 {print $1}') || true
  fi
  printf '%s\n' "$ip"
}

precheck_dns() {
  if [[ $SKIP_DNS -eq 1 ]]; then
    warn "DNS verification skipped (--skip-dns-check)."
    return 0
  fi
  local server_ip resolved
  if ! server_ip=$(public_ipv4); then
    warn "Could not detect this server's public IPv4; skipping DNS verification."
    return 0
  fi
  resolved=$(resolve_ipv4 "$DOMAIN")
  if [[ -z $resolved ]]; then
    die "No A record found for ${DOMAIN}. Create '${DOMAIN} A ${server_ip}' (Cloudflare: DNS only / grey cloud), wait a minute, then re-run. Use --skip-dns-check to bypass."
  fi
  if [[ $resolved != "$server_ip" ]]; then
    cat >&2 << EOF
[x] DNS mismatch for ${DOMAIN}
      domain resolves to : ${resolved}
      this server's IPv4 : ${server_ip}
    Let's Encrypt checks port 80 on the address the domain points to.
    Fix the A record (turn OFF the Cloudflare proxy / use grey cloud) and re-run.
    To bypass this check: --skip-dns-check
EOF
    exit 1
  fi
  say "DNS OK: ${DOMAIN} -> ${server_ip}"
}

precheck_port80() {
  if [[ -z $ACME_PORT && -r $INFO_FILE ]]; then
    ACME_PORT=$(sed -n "s/^XUI_ACME_HTTP_PORT='\([0-9]*\)'$/\1/p" "$INFO_FILE")
  fi
  ACME_PORT=${ACME_PORT:-80}
  [[ $ACME_PORT =~ ^[0-9]{1,5}$ && $((10#$ACME_PORT)) -ge 1 && $((10#$ACME_PORT)) -le 65535 ]] || die "Invalid ACME port"
  ACME_PORT=$((10#$ACME_PORT))
  [[ $ACME_PORT != 443 ]] || die "Use an ACME listener other than TCP/443"
  if [[ $ACME_PORT != 80 ]]; then
    command -v iptables > /dev/null || die "Install iptables to forward the ACME challenge port"
    port_in_use "$ACME_PORT" && die "ACME listener TCP/$ACME_PORT is already in use"
    say "Certificate validation: temporary TCP/80 forwarding to TCP/$ACME_PORT; no listener on 80/443."
    return 0
  fi
  if ! port_in_use 80; then
    say "TCP/80 is free."
    return 0
  fi
  local who=""
  who=$(ss -ltnp 2> /dev/null | awk '$4 ~ /:80$/ {print; exit}') || true
  if [[ $who == *'"nginx"'* ]]; then
    ACME_MODE=nginx
    say "nginx owns TCP/80; the certificate will come from certbot through nginx."
    return 0
  fi
  if [[ -n $who ]]; then
    die "TCP/80 is already in use: ${who} -- stop that service (apache?) and re-run."
  fi
  die "TCP/80 is already in use -- stop the service using it and re-run."
}

# Every setup on the server needs its own subdomain: one certificate lineage
# and one nginx server per name.
precheck_domain_free() {
  local entry f key owner d re
  for entry in "/etc/dns-setup/state.env|DS_DOMAIN|dns-setup.sh" "/opt/n8n/.env|N8N_DOMAIN|n8n-setup.sh"; do
    IFS='|' read -r f key owner <<< "$entry"
    [[ -r $f ]] || continue
    d=$(sed -n -E "s/^${key}='?([^']*)'?$/\1/p" "$f" | sed -n '1p')
    if [[ $d == "$DOMAIN" ]]; then
      die "${DOMAIN} is already used by ${owner}. Give 3x-ui its own subdomain (e.g. panel.example.com)."
    fi
  done
  [[ $ACME_MODE == nginx ]] || return 0
  re="^[[:space:]]*server_name[^;]*[[:space:]]$(printf '%s' "$DOMAIN" | sed 's/[.]/\\./g')[[:space:];]"
  for f in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
    [[ -f $f && $f != "$NGINX_CONF" ]] || continue
    if grep -Eq "$re" "$f"; then
      die "${DOMAIN} is already served by ${f}. Give 3x-ui its own subdomain."
    fi
  done
}

precheck_disk() {
  local avail
  avail=$(df -Pk / 2> /dev/null | awk 'NR == 2 {print $4}') || true
  if [[ $avail =~ ^[0-9]+$ ]] && ((avail < 1048576)); then
    die "At least 1 GB of free disk space is required (found $((avail / 1024)) MB)."
  fi
}

ufw_is_active() {
  command -v ufw > /dev/null 2>&1 || return 1
  ufw status 2> /dev/null | grep -q '^Status: active'
}

firewalld_is_active() {
  command -v firewall-cmd > /dev/null 2>&1 || return 1
  firewall-cmd --state 2> /dev/null | grep -q '^running$'
}

firewall_allows_80() {
  if ufw_is_active; then
    ufw status 2> /dev/null | grep -Eq '(^|[[:space:]])80(/tcp)?[[:space:]]+ALLOW' && return 0
    return 1
  fi
  if firewalld_is_active; then
    firewall-cmd --query-port=80/tcp > /dev/null 2>&1 && return 0
    firewall-cmd --query-service=http > /dev/null 2>&1 && return 0
    return 1
  fi
  return 0
}

open_firewall_rules() {
  local port=$1
  if ufw_is_active; then
    ufw allow 80/tcp > /dev/null 2>&1 || true
    ufw allow "${port}/tcp" > /dev/null 2>&1 || true
    say "Opened ufw ports for the panel (config ports follow once they exist)."
  fi
  if firewalld_is_active; then
    firewall-cmd --permanent --add-port=80/tcp > /dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${port}/tcp" > /dev/null 2>&1 || true
    firewall-cmd --reload > /dev/null 2>&1 || true
    say "Opened firewalld ports for the panel (config ports follow once they exist)."
  fi
}

precheck_firewall() {
  local port=$1
  if [[ $OPEN_FIREWALL -eq 1 ]]; then
    open_firewall_rules "$port"
    firewall_allows_80 || die "Could not open TCP/80 in the local firewall."
    return 0
  fi
  if firewall_allows_80; then
    return 0
  fi
  if ufw_is_active; then
    die "ufw is active but TCP/80 is not allowed. Run 'ufw allow 80/tcp' (or re-run with --open-firewall)."
  fi
  die "The local firewall does not allow TCP/80. Open it (or re-run with --open-firewall)."
}

get_setting() {
  [[ -x $XUI_BIN ]] || return 1
  "$XUI_BIN" setting -show true 2> /dev/null \
    | awk -v k="$1" '$1 == k":" && !found {v=$2; found=1} END {if (found) print v; else exit 1}'
}

get_cert_setting() {
  [[ -x $XUI_BIN ]] || return 1
  "$XUI_BIN" setting -getCert true 2> /dev/null \
    | awk 'tolower($1) == "cert:" && !found {v=$2; found=1} END {print v}'
}

service_active() {
  if command -v systemctl > /dev/null 2>&1; then
    systemctl is-active --quiet x-ui 2> /dev/null
  elif command -v rc-service > /dev/null 2>&1; then
    rc-service x-ui status > /dev/null 2>&1
  else
    return 1
  fi
}

start_service() {
  if command -v systemctl > /dev/null 2>&1; then
    systemctl start x-ui
  else
    rc-service x-ui start
  fi
}

restart_service() {
  if command -v systemctl > /dev/null 2>&1; then
    systemctl restart x-ui
  else
    rc-service x-ui restart
  fi
}

wait_for_panel() {
  for _ in {1..30}; do
    if service_active; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# "latest" becomes the newest release tag. When GitHub cannot be asked, the
# version stays empty and install.sh picks the newest release by itself.
resolve_panel_version() {
  [[ $PANEL_VERSION == latest || -z $PANEL_VERSION ]] || return 0
  local tag=""
  tag=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${PANEL_REPO}/releases/latest" 2> /dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p') || true
  if [[ -z $tag ]]; then
    tag=$(curl -fsSLI --max-time 15 -o /dev/null -w '%{url_effective}' \
      "https://github.com/${PANEL_REPO}/releases/latest" 2> /dev/null | sed -n 's#.*/releases/tag/##p') || true
  fi
  if [[ $tag =~ ^v?[0-9]+(\.[0-9]+)+$ ]]; then
    PANEL_VERSION="$tag"
  else
    PANEL_VERSION=""
    warn "Could not ask GitHub for the newest 3x-ui release; install.sh will pick it."
  fi
}

installed_panel_version() {
  [[ -x $XUI_BIN ]] || return 1
  "$XUI_BIN" -v 2> /dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | sed -n '1p'
}

install_panel() {
  local tmp rc
  local env_args=(
    HOME=/root
    XUI_NONINTERACTIVE=1
    XUI_DB_TYPE=sqlite
    XUI_PANEL_PORT="$PANEL_PORT"
    XUI_WEB_BASE_PATH="$WEB_PATH"
  )
  if [[ $ACME_MODE == nginx || $ACME_PORT != 80 ]]; then
    # Issue later, after nginx routing or temporary port forwarding is ready.
    env_args+=(XUI_SSL_MODE=none)
  else
    env_args+=(XUI_SSL_MODE=domain XUI_DOMAIN="$DOMAIN" XUI_ACME_HTTP_PORT=80)
  fi
  [[ -n $PANEL_USER ]] && env_args+=(XUI_USERNAME="$PANEL_USER")
  [[ -n $PANEL_PASS ]] && env_args+=(XUI_PASSWORD="$PANEL_PASS")

  tmp=$(mktemp /tmp/3xui-installer.XXXXXX)
  say "Downloading the installer ..."
  if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 -o "$tmp" "$INSTALLER_URL"; then
    rm -f "$tmp"
    die "Failed to download ${INSTALLER_URL}"
  fi
  if [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    die "Downloaded installer is empty."
  fi
  if ! grep -q 'XUI_NONINTERACTIVE' "$tmp"; then
    rm -f "$tmp"
    die "This installer does not support unattended mode. Set XUI_INSTALLER_URL to a 3x-ui v3 install.sh."
  fi

  say "Installing 3x-ui ${PANEL_VERSION:-latest} (unattended; this can take a few minutes) ..."
  set +e
  if [[ -n $PANEL_VERSION ]]; then
    env "${env_args[@]}" bash "$tmp" "$PANEL_VERSION"
  else
    env "${env_args[@]}" bash "$tmp"
  fi
  rc=$?
  set -e
  rm -f "$tmp"
  if ((rc != 0)); then
    die "install.sh exited with code ${rc}. See ${LOG_FILE}"
  fi
  say "Installer completed."
}

run_ssl_menu() {
  local menu answers rc
  menu="$MENU_BIN"
  if [[ ! -x $menu ]]; then
    menu=$(command -v x-ui || true)
  fi
  [[ -n $menu ]] || die "The x-ui management script was not found."

  answers=$(printf '20\n1\n%s\n%s\nn\ny\n0\n0\n' "$DOMAIN" "$ACME_PORT")
  say "Requesting a certificate for ${DOMAIN} (ACME HTTP-01, listener $ACME_PORT) ..."
  install_acme_hooks
  if ! "$ACME_HOOK" pre; then
    "$ACME_HOOK" post
    die "Could not forward the ACME challenge port"
  fi

  set +e
  printf '%s\n' "$answers" | env HOME=/root timeout 900 "$menu"
  rc=$?
  set -e
  "$ACME_HOOK" post
  if ((rc == 124)); then
    warn "The SSL menu timed out after 15 minutes."
  elif ((rc != 0)); then
    warn "The SSL menu exited with code ${rc}."
  fi
}

acme_bin() {
  local bin="/root/.acme.sh/acme.sh"
  [[ -x $bin ]] && printf '%s\n' "$bin"
}

# Renew directly through acme.sh and copy the new files to /root/cert/<domain>.
# The panel's "Force Renew" menu entry renews the ACME state but does not
# refresh /root/cert, which would leave the panel on the expired files.
force_renew_cert() {
  local acme reload
  acme=$(acme_bin) || return 1
  if command -v systemctl > /dev/null 2>&1; then
    reload="systemctl restart x-ui"
  else
    reload="rc-service x-ui restart"
  fi
  "$acme" --renew -d "$DOMAIN" --force || return 1
  if ! "$acme" --installcert --force -d "$DOMAIN" \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd "$reload"; then
    # acme.sh reports failure when only the reload command fails; the files
    # are still copied, so trust the certificate itself in that case.
    cert_valid && return 0
    return 1
  fi
  return 0
}

cert_valid() {
  [[ -n $CERT_FILE && -s $CERT_FILE && -s $KEY_FILE ]] || return 1
  openssl x509 -in "$CERT_FILE" -noout -checkend 86400 > /dev/null 2>&1 || return 1
  local san
  san=$(openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2> /dev/null) || return 1
  [[ $san == *"DNS:${DOMAIN}"* ]]
}

ensure_ssl() {
  if [[ $ACME_MODE == nginx ]]; then
    ensure_ssl_nginx
    configure_panel_cert
    drop_acme_renewal
    verify_https
    return 0
  fi

  install_acme_hooks
  if cert_valid; then
    say "A valid certificate for ${DOMAIN} is already present."
  elif [[ -s $CERT_FILE && -s $KEY_FILE ]]; then
    warn "Certificate files exist but are expired or do not cover ${DOMAIN}; renewing."
    if ! force_renew_cert; then
      warn "Direct renewal failed; clearing the ACME state for ${DOMAIN} and re-issuing."
      rm -rf "/root/.acme.sh/${DOMAIN}" "/root/.acme.sh/${DOMAIN}_ecc"
      run_ssl_menu
    fi
  else
    warn "No certificate for ${DOMAIN} yet; issuing one through the panel SSL menu."
    run_ssl_menu
  fi

  if ! cert_valid; then
    die "Could not obtain a valid certificate for ${DOMAIN}. Check DNS, TCP/80 and /root/.acme.sh/acme.sh.log"
  fi

  install_acme_hooks
  configure_panel_cert
  verify_https
}

# ACME either forwards TCP/80 to its dedicated listener or briefly frees
# TCP/80 from nginx in the default standalone mode.
install_acme_hooks() {
  local f="" dir
  for dir in "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"; do
    if [[ -f ${dir}/${DOMAIN}.conf ]]; then
      f="${dir}/${DOMAIN}.conf"
      break
    fi
  done
  cat > "$ACME_HOOK" << 'EOF'
#!/bin/sh
# Added by 3xui-setup.sh: prepare HTTP-01 routing, then restore it.
flag=/run/3xui-acme-stopped-nginx
port=__ACME_PORT__
if [ "$port" != 80 ]; then
  for tool in iptables ip6tables; do
    command -v "$tool" >/dev/null 2>&1 || continue
    case "$1" in
      pre)
        "$tool" -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports "$port" 2>/dev/null ||
          "$tool" -t nat -I PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports "$port" || exit 1
        "$tool" -t filter -C INPUT -p tcp --dport "$port" -m conntrack --ctorigdstport 80 -j ACCEPT 2>/dev/null ||
          "$tool" -t filter -I INPUT -p tcp --dport "$port" -m conntrack --ctorigdstport 80 -j ACCEPT || exit 1
        ;;
      post)
        if "$tool" -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports "$port" 2>/dev/null; then
          "$tool" -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports "$port" || exit 1
        fi
        if "$tool" -t filter -C INPUT -p tcp --dport "$port" -m conntrack --ctorigdstport 80 -j ACCEPT 2>/dev/null; then
          "$tool" -t filter -D INPUT -p tcp --dport "$port" -m conntrack --ctorigdstport 80 -j ACCEPT || exit 1
        fi
        ;;
    esac
  done
  exit 0
fi
case "$1" in
  pre)
    if systemctl is-active --quiet nginx 2> /dev/null; then
      systemctl stop nginx && touch "$flag"
    fi
    ;;
  post)
    if [ -f "$flag" ]; then
      rm -f "$flag"
      systemctl start nginx
    fi
    ;;
esac
exit 0
EOF
  sed -i "s/__ACME_PORT__/$ACME_PORT/" "$ACME_HOOK"
  chmod 755 "$ACME_HOOK"
  [[ -n $f ]] || return 0
  # acme.sh reads plain values as well as its base64-wrapped ones
  set_acme_conf "$f" Le_PreHook "${ACME_HOOK} pre"
  set_acme_conf "$f" Le_PostHook "${ACME_HOOK} post"
  set_acme_conf "$f" Le_HTTPPort "$ACME_PORT"
}

set_acme_conf() { # file key value
  local f=$1 k=$2 v=$3
  if grep -q "^${k}=" "$f"; then
    sed -i "s|^${k}=.*|${k}='${v}'|" "$f"
  else
    printf "%s='%s'\n" "$k" "$v" >> "$f"
  fi
}

# ---------------------------------------------------------------------------
# Certificate through nginx (dns-setup.sh / n8n-setup.sh own TCP/80)
# ---------------------------------------------------------------------------
render_nginx_acme() {
  local out
  [[ -d /etc/nginx/conf.d ]] || die "/etc/nginx/conf.d is missing; unexpected nginx layout."
  grep -rqs 'conf\.d/\*\.conf' /etc/nginx/nginx.conf \
    || die "/etc/nginx/nginx.conf does not include conf.d/*.conf; add it and re-run."
  mkdir -p "${ACME_ROOT}/.well-known/acme-challenge"
  chmod 755 "$ACME_ROOT" "${ACME_ROOT}/.well-known" "${ACME_ROOT}/.well-known/acme-challenge"
  {
    printf '# Managed by 3xui-setup.sh -- ACME challenges for the 3x-ui panel domain\n'
    printf 'server {\n'
    printf '    listen 80;\n'
    if [[ -f /proc/net/if_inet6 ]]; then
      printf '    listen [::]:80;\n'
    fi
    printf '    server_name %s;\n\n' "$DOMAIN"
    printf '    location ^~ /.well-known/acme-challenge/ {\n'
    printf '        root %s;\n' "${ACME_ROOT%/}"
    printf '        default_type "text/plain";\n'
    printf '    }\n'
    printf '    location / {\n'
    printf '        return 444;\n'
    printf '    }\n'
    printf '}\n'
  } > "$NGINX_CONF"
  if ! out=$(nginx -t 2>&1); then
    printf '%s\n' "$out" >&2
    rm -f "$NGINX_CONF"
    die "nginx rejected ${NGINX_CONF} (see the output above)."
  fi
  systemctl reload nginx || die "Could not reload nginx."
}

ensure_ssl_nginx() {
  if ! command -v certbot > /dev/null 2>&1; then
    say "Installing certbot ..."
    apt-get -o DPkg::Lock::Timeout=180 install -y -qq certbot \
      || die "Could not install certbot."
  fi
  render_nginx_acme

  if cert_valid; then
    say "A valid certificate for ${DOMAIN} is already present."
  else
    local args=(
      certonly --webroot -w "$ACME_ROOT"
      -d "$DOMAIN" --cert-name "$DOMAIN"
      --agree-tos --no-eff-email
      --non-interactive --keep-until-expiring
    )
    if [[ -n ${XUI_ACME_EMAIL:-} ]]; then
      args+=(--email "$XUI_ACME_EMAIL")
    else
      args+=(--register-unsafely-without-email)
    fi
    say "Requesting a certificate for ${DOMAIN} (certbot, HTTP-01 through nginx) ..."
    certbot "${args[@]}" \
      || die "certbot failed for ${DOMAIN}. Check DNS (grey cloud), TCP/80 in the provider firewall and /var/log/letsencrypt/letsencrypt.log"
  fi
  cert_valid || die "Could not obtain a valid certificate for ${DOMAIN}."

  install -d -m 755 "$(dirname "$LE_HOOK")"
  cat > "$LE_HOOK" << EOF
#!/bin/sh
# Added by 3xui-setup.sh: restart x-ui after certbot renews ${DOMAIN}.
case " \$RENEWED_DOMAINS " in
  *" ${DOMAIN} "*) systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null || true ;;
esac
EOF
  chmod 755 "$LE_HOOK"
  systemctl enable --now certbot.timer > /dev/null 2>&1 || true
}

# The panel now uses the certbot files; stop acme.sh from renewing the old
# certificate on TCP/80 (it would fail, or pause nginx through the hook).
drop_acme_renewal() {
  local acme dir
  acme=$(acme_bin) || return 0
  for dir in "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"; do
    [[ -f ${dir}/${DOMAIN}.conf ]] || continue
    if [[ $dir == *_ecc ]]; then
      "$acme" --remove -d "$DOMAIN" --ecc > /dev/null 2>&1 || true
    else
      "$acme" --remove -d "$DOMAIN" > /dev/null 2>&1 || true
    fi
    say "acme.sh no longer renews ${DOMAIN}; certbot does."
  done
}

configure_panel_cert() {
  local current
  current=$(get_cert_setting || true)
  if [[ $current == "$CERT_FILE" ]]; then
    say "The panel already uses ${CERT_FILE}."
    return 0
  fi
  say "Pointing the panel to the certificate ..."
  "$XUI_BIN" cert -webCert "$CERT_FILE" -webCertKey "$KEY_FILE" \
    || die "Failed to set the panel certificate."
  restart_service || die "Failed to restart x-ui."
  wait_for_panel || die "x-ui did not come back after applying the certificate."
  sleep 2
}

verify_https() {
  local code="" url
  if [[ -n $ACTUAL_PATH ]]; then
    url="https://${DOMAIN}:${ACTUAL_PORT}/${ACTUAL_PATH}/"
  else
    url="https://${DOMAIN}:${ACTUAL_PORT}/"
  fi
  for _ in {1..10}; do
    code=$(curl -ksS --max-time 10 --resolve "${DOMAIN}:${ACTUAL_PORT}:127.0.0.1" \
      -o /dev/null -w '%{http_code}' "$url" 2> /dev/null || true)
    if [[ $code =~ ^[23][0-9][0-9]$ ]]; then
      say "Local HTTPS check OK (HTTP ${code})."
      return 0
    fi
    sleep 1
  done
  warn "Local HTTPS check did not succeed (last HTTP code: '${code:-none}')."
  warn "Check manually: curl -k -v ${url}"
}

# ---------------------------------------------------------------------------
# Config set (added through the panel API once the panel is secured)
#
# Adapted from 3x-ui-pro-configs (MIT) -- https://github.com/pdnczone/3x-ui-pro-configs
# Changes: fully unattended, panel/certificate facts come from this script,
# extra XHTTP / mKCP variants, re-runs do not add a second set.
#
# Xray refuses VLESS without a security layer, so every config here carries
# REALITY, TLS or VLESS Encryption (Shadowsocks-2022 encrypts by itself).
# ---------------------------------------------------------------------------
write_pro_py() {
  cat << 'PYEOF'
import atexit, base64, glob, ipaddress, json, os, re, secrets, shutil, socket, string, subprocess, sys, tempfile, time
import concurrent.futures as cfut

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def E(k, d=""):
    return os.environ.get(k, d).strip()

DOMAIN = E("PRO_DOMAIN").lower()
PPORT = E("PRO_PANEL_PORT")
PPATH = E("PRO_PANEL_PATH").strip("/")
CERT, KEY = E("PRO_CERT"), E("PRO_KEY")
CDN = E("PRO_CDN").lower()
WANT = E("PRO_CONFIGS", "all").lower()
EMAIL_WANT = re.sub(r"[^A-Za-z0-9_.@-]", "", E("PRO_EMAIL"))
SUBID_WANT = re.sub(r"[^A-Za-z0-9]", "", E("PRO_SUBID"))
FORCE = E("PRO_FORCE") == "1"
NO_BBR = E("PRO_NO_BBR") == "1"
NO_TEST = E("PRO_NO_TEST") == "1"
RESULT = E("PRO_RESULT")
CLEAN_URL = E("PRO_CLEAN_URL")
XUI_DIR = E("PRO_XUI_DIR", "/usr/local/x-ui")
MARK = "3xui-setup"
try:
    CLEAN_N = max(0, min(30, int(E("PRO_CLEAN", "20"))))
except ValueError:
    CLEAN_N = 20

def info(*a): print("[+]", *a, flush=True)
def warn(*a): print("[!]", *a, flush=True)
def die(*a): print("[x]", *a, flush=True); sys.exit(1)
def head(t): print("\n-- %s %s" % (t, "-" * max(2, 58 - len(t))), flush=True)
def sh(cmd, t=60):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, encoding="utf-8", errors="replace",
                              timeout=t, stdin=subprocess.DEVNULL).stdout.strip()
    except Exception:
        return ""
def curl(args, data=None, t=40):
    try:
        return subprocess.run(["curl", "-sk", "-m", str(t)] + args, input=data if data is not None else "",
                              capture_output=True, encoding="utf-8", errors="replace", timeout=t + 15).stdout
    except Exception:
        return ""
def write_result(**kv):
    if not RESULT:
        return
    with open(RESULT, "w", encoding="utf-8") as f:
        for k, v in kv.items():
            f.write("%s='%s'\n" % (k, str(v).replace("'", "")))

# =========================================================================== panel
if not (DOMAIN and PPORT):
    die("Panel domain/port were not passed to the config step.")
RESOLVE = ["--resolve", f"{DOMAIN}:{PPORT}:127.0.0.1"]
PANEL = ""
for scheme in ("https", "http"):
    u = f"{scheme}://{DOMAIN}:{PPORT}" + (f"/{PPATH}" if PPATH else "")
    if curl(RESOLVE + ["-o", "/dev/null", "-w", "%{http_code}", u + "/csrf-token"], t=6) not in ("", "000"):
        PANEL = u
        break
if not PANEL:
    die(f"The panel API is not reachable on 127.0.0.1:{PPORT}.")
TOKEN = E("PRO_TOKEN")
TEMP_TOKEN_ID = None

def api(path, body=None, post=False, timeout=40):
    a = RESOLVE + ["-H", f"Authorization: Bearer {TOKEN}"]
    data = None
    if body is not None:
        a += ["-H", "Content-Type: application/json", "-X", "POST", "--data-binary", "@-"]
        data = json.dumps(body)
    elif post:
        a += ["-X", "POST"]
    out = curl(a + [PANEL + path], data, timeout)
    try:
        r = json.loads(out)
        return r if isinstance(r, dict) else {"success": False, "msg": out[:200]}
    except Exception:
        return {"success": False, "msg": out[:200]}

def login_and_mint_token(u, pw):
    global TOKEN, TEMP_TOKEN_ID
    fd, cookie = tempfile.mkstemp(prefix=".3xui-pro.")
    os.close(fd)
    bc = RESOLVE + ["-c", cookie, "-b", cookie]
    def csrf():
        try:
            return json.loads(curl(bc + [PANEL + "/csrf-token"], t=20)).get("obj", "") or ""
        except Exception:
            return ""
    def post(path, body):
        return curl(bc + ["-H", f"X-CSRF-Token: {csrf()}", "-H", "Content-Type: application/json", "-X", "POST",
                          "--data-binary", "@-", PANEL + path], json.dumps(body), 20)
    try:
        out = post("/login", {"username": u, "password": pw})
        if '"success":true' not in re.sub(r"\s", "", out):
            die("Panel login failed:", out[:150])
        out = post("/panel/api/setting/apiTokens/create", {"name": f"3xui-setup-{int(time.time())}"})
        try:
            o = json.loads(out)["obj"]
            TOKEN, TEMP_TOKEN_ID = o["token"], o["id"]
        except Exception:
            die("Logged in, but could not create an API token (panel too old?):", out[:150])
    finally:
        try:
            os.remove(cookie)
        except Exception:
            pass

def drop_temp_token():
    if TEMP_TOKEN_ID is not None:
        api(f"/panel/api/setting/apiTokens/delete/{TEMP_TOKEN_ID}", post=True)
atexit.register(drop_temp_token)

if not TOKEN or not api("/panel/api/inbounds/list").get("success"):
    if not (E("PRO_USER") and E("PRO_PASS")):
        die("No working API token and no panel credentials.")
    login_and_mint_token(E("PRO_USER"), E("PRO_PASS"))
if not api("/panel/api/inbounds/list").get("success"):
    die("Cannot talk to the panel API at", PANEL)
for need in ("/panel/api/clients/list", "/panel/api/hosts/list"):
    if not api(need).get("success"):
        die("This 3x-ui is too old (no Clients/Hosts pages). Re-run with --force-install to update the panel.")
status = api("/panel/api/server/status").get("obj") or {}
XVER = str((status.get("xray") or {}).get("version", "?"))
info(f"panel {status.get('panelVersion', '?')} · xray {XVER}")
m = re.match(r"v?(\d+)", XVER)
if not m or int(m.group(1)) < 26:
    warn("Xray-core is older than 26.x; FinalMask, Hysteria2 and VLESS Encryption configs need it (Panel > Xray > update).")
XRAY = (glob.glob(os.path.join(XUI_DIR, "bin", "xray-linux-*")) or [""])[0]
DB = "/etc/x-ui/x-ui.db"
settings = api("/panel/api/setting/all", post=True).get("obj") or {}

def sub_urls(st, subid):
    port = int(st.get("subPort") or 2096)
    scheme = "https" if st.get("subCertFile") and st.get("subKeyFile") else "http"
    host = st.get("subDomain") or DOMAIN
    hp = host if (scheme, port) in (("https", 443), ("http", 80)) else f"{host}:{port}"
    def path(k, d):
        p = st.get(k) or d
        return "/" + p.strip("/") + "/" if p.strip("/") else "/"
    return (f"{scheme}://{hp}{path('subPath', '/sub/')}{subid}",
            f"{scheme}://{hp}{path('subJsonPath', '/json/')}{subid}", host, port)

# =========================================================================== already done?
clients = api("/panel/api/clients/list").get("obj") or []
clients = [c for c in clients if isinstance(c, dict)] if isinstance(clients, list) else []
# A client from an earlier run is reused: only the configs it does not have yet
# are added, under the same subscription. Nothing that exists is touched.
OLD = None
if not FORCE:
    OLD = next((c for c in clients if c.get("subId") and c.get("email") and
                (c.get("comment") == MARK or (SUBID_WANT and c.get("subId") == SUBID_WANT))), None)

# =========================================================================== server facts
if not (CERT and KEY and os.path.exists(CERT) and os.path.exists(KEY)):
    warn("No certificate; TLS, CDN and Hysteria2 configs will be skipped.")
    CERT = KEY = ""
pub = status.get("publicIP") if isinstance(status.get("publicIP"), dict) else {}
PUB4 = (pub or {}).get("ipv4") or sh("curl -4 -s -m6 https://api.ipify.org")
PUB6 = ""
for l in sh("ip -6 addr show scope global").splitlines():
    m = re.search(r"inet6 ([0-9a-f:]+)/\d+ .*scope global", l)
    if m and "temporary" not in l and "deprecated" not in l and not m.group(1).startswith(("fd", "fc")):
        PUB6 = m.group(1)
        break
if PUB6 and not sh("curl -6 -s -m6 https://api64.ipify.org"):
    PUB6 = ""
ADDR = DOMAIN
CF_NETS = [ipaddress.ip_network(n) for n in (
    "173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 "
    "188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 "
    "131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 "
    "2c0f:f248::/32").split()]
def ips_of(d):
    try:
        return sorted({a[4][0] for a in socket.getaddrinfo(d, None)})
    except Exception:
        return []
def is_cf(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in CF_NETS if a.version == n.version)

# =========================================================================== CDN domain
if CDN and not re.match(r"^[a-z0-9.-]+$", CDN):
    warn(f"'{CDN}' is not a valid CDN domain; CDN skipped."); CDN = ""
if CDN and not CERT:
    warn("CDN configs need the certificate; CDN skipped."); CDN = ""
if CDN:
    ips = ips_of(CDN)
    if not ips:
        warn(f"{CDN} does not resolve; CDN skipped."); CDN = ""
    elif not any(is_cf(i) for i in ips):
        warn(f"{CDN} is not proxied by Cloudflare (orange cloud is off); CDN skipped."); CDN = ""
    else:
        info(f"{CDN} is behind Cloudflare")

# =========================================================================== configs
CATALOG = [
    # key, name, needs, description
    ("rv", "⚡ Reality Vision", None, "fastest + stealthiest, main config"),
    ("rx", "🌀 Reality XHTTP", None, "REALITY over XHTTP, padding"),
    ("ro", "🎭 Reality XHTTP Obfs", None, "XHTTP extra: obfuscated padding (tokenish)"),
    ("rp", "📦 Reality XHTTP Packet-up", None, "XHTTP packet-up mode, for networks that break long uploads"),
    ("rg", "🔷 Reality gRPC", None, "REALITY over gRPC"),
    ("tv", "🔐 TLS Vision", "tls", "real certificate, + Fragment and IPv6 variants"),
    ("tx", "🛰 TLS XHTTP", "tls", "direct + CDN capable"),
    ("ws", "🌐 CDN WS", "cdn", "Cloudflare WebSocket + clean IPs"),
    ("hu", "🔗 CDN HTTPUpgrade", "cdn", "Cloudflare HTTPUpgrade"),
    ("cg", "📡 CDN gRPC", "cdn", "Cloudflare gRPC (enable gRPC in Cloudflare > Network)"),
    ("hy", "🚄 Hysteria2", "tls", "UDP/QUIC, Salamander FinalMask"),
    ("th", "🚀 TLS XHTTP H3", "tls", "XHTTP over HTTP/3 (QUIC, UDP)"),
    ("pq", "🧬 PQ Sudoku", None, "post-quantum VLESS Encryption + Sudoku FinalMask"),
    ("ew", "🔑 Enc WS", None, "VLESS Encryption over plain WebSocket, direct + Cloudflare HTTP port"),
    ("ex", "🔑 Enc XHTTP", None, "VLESS Encryption over plain XHTTP, direct + Cloudflare HTTP port"),
    ("tt", "🐴 Trojan TLS", "tls", "for clients without good VLESS support"),
    ("tr", "🐴 Trojan Reality", None, "Trojan over REALITY"),
    ("kc", "🧬 PQ mKCP", None, "VLESS Encryption over mKCP (UDP); only when asked for with --configs"),
    ("ss", "🛟 Shadowsocks-2022", None, "simple backup"),
]
REMARK = {"rv": "⚡ Reality Vision", "rx": "🌀 Reality XHTTP", "ro": "🎭 Reality XHTTP · Obfs",
          "rp": "📦 Reality XHTTP · Packet-up", "rg": "🔷 Reality gRPC", "tv": "🔐 TLS Vision",
          "tx": "🛰 TLS XHTTP", "ws": "🌐 TLS WS", "hu": "🔗 TLS HTTPUpgrade", "cg": "📡 TLS gRPC",
          "hy": "🚄 Hysteria2 · UDP", "th": "🚀 TLS XHTTP · H3", "pq": "🧬 PQ Sudoku", "ew": "🔑 Enc WS",
          "ex": "🔑 Enc XHTTP", "tt": "🐴 Trojan TLS", "tr": "🐴 Trojan Reality", "kc": "🧬 PQ mKCP · UDP",
          "ss": "🛟 Shadowsocks · Backup"}
# newer combos: dropped again if their self-test fails
EXTRA = {"ro", "rp", "kc", "cg", "th", "ew", "ex", "tt", "tr"}
OPT_IN = {"kc"}                  # not part of "all": mKCP is blocked on most networks now
avail = [c for c in CATALOG if c[2] is None or (c[2] == "tls" and CERT) or (c[2] == "cdn" and CDN)]
skipped = [c[1] for c in CATALOG if c not in avail]
if skipped:
    info("not available (no certificate / CDN domain):", ", ".join(skipped))
if WANT in ("", "all"):
    sel_keys = [c[0] for c in avail if c[0] not in OPT_IN]
else:
    sel_keys = [x.strip() for x in WANT.split(",") if x.strip()]
    unknown = [k for k in sel_keys if k not in {c[0] for c in CATALOG}]
    if unknown:
        warn("unknown config keys ignored:", ", ".join(unknown))
SEL = [c for c in avail if c[0] in sel_keys]
if not SEL:
    die("No config selected.")
if not (CDN and any(k in sel_keys for k in ("ws", "hu", "tx"))):
    CLEAN_N = 0

# =========================================================================== ports
inbs = api("/panel/api/inbounds/list").get("obj") or []
if OLD:
    have_remarks = {ib.get("remark") for ib in inbs}
    HAVE = {k for k, v in REMARK.items() if v in have_remarks}
    SEL = [c for c in SEL if c[0] not in HAVE]
    if HAVE & {"ws", "hu", "tx"}:
        CLEAN_N = 0              # the clean-IP links are already there
    if not SEL:
        sub, jsub, _, sport = sub_urls(settings, OLD["subId"])
        info(f"The config set is complete (client {OLD['email']}); nothing to add.")
        info("Use --add-configs to create a second, separate set.")
        write_result(PRO_EXISTING=1, PRO_SUB_URL=sub, PRO_JSON_URL=jsub, PRO_SUB_ID=OLD["subId"],
                     PRO_CLIENT=OLD["email"], PRO_SUB_PORT=sport)
        sys.exit(0)
    info(f"Existing client {OLD['email']} found; adding only what it does not have yet:",
         ", ".join(c[0] for c in SEL))
owner_tcp, owner_udp = {}, {}
for ib in inbs:
    st = ib.get("streamSettings")
    st = json.loads(st) if isinstance(st, str) and st else (st or {})
    label = f"inbound '{ib.get('remark') or ib['id']}'"
    if ib["protocol"] in ("hysteria", "wireguard", "amneziawg") or st.get("network") in ("kcp", "hysteria"):
        owner_udp[ib["port"]] = label
    else:
        owner_tcp[ib["port"]] = label
        if ib["protocol"] in ("shadowsocks", "mixed", "socks", "dokodemo-door", "tunnel"):
            owner_udp[ib["port"]] = label
for flag, dct in (("t", owner_tcp), ("u", owner_udp)):
    for l in sh(f"ss -H -{flag}lnp").splitlines():
        f = l.split()
        if len(f) < 5:
            continue
        m = re.search(r":(\d+)$", f[3])
        if m and int(m.group(1)) not in dct:
            pm = re.search(r'\(\("([^"]+)"', l)
            dct[int(m.group(1))] = f"process '{pm.group(1) if pm else '?'}'"
for k in ("subPort", "webPort"):
    if settings.get(k):
        owner_tcp.setdefault(int(settings[k]), "3x-ui panel/subscription")
owner_tcp.setdefault(int(PPORT), "3x-ui panel")

CF_HTTPS = [443, 2053, 2083, 2087, 2096, 8443]
PREF = {"rv": [443, 2443, 3443, 6443, 7443], "rx": [8443, 2443, 3443, 5443, 6443], "ro": [2443, 3443, 5443, 6443, 7443],
        "rp": [3443, 5443, 6443, 7443, 9445], "rg": [4443, 5443, 7443, 9444],
        "tv": [9443, 9444, 10444, 11444], "tx": [2087, 2053, 2083, 2096, 8443], "ws": [2053, 2083, 2087, 2096, 8443],
        "hu": [2083, 2053, 2087, 2096, 8443], "cg": [2096, 8443, 2087, 2053, 2083, 443],
        "hy": [443, 8443, 4443, 2053, 10443], "th": [8443, 4443, 2087, 10443], "pq": [10443, 11443, 12443, 13443],
        "ew": [8880, 2052, 2082, 2086, 2095], "ex": [2052, 2082, 2086, 2095, 8880],
        "tt": [14443, 15443, 16443], "tr": [14444, 15444, 16444],
        "kc": [9443, 10443, 11443], "ss": [8080, 8388, 18080, 28080]}
CF_HTTP = [80, 8080, 8880, 2052, 2082, 2086, 2095]     # Cloudflare ports without TLS
UDP_ONLY = {"hy", "kc", "th"}
BOTH = {"ss"}

def busy(pt, key):
    t = pt in owner_tcp if key not in UDP_ONLY else False
    u = pt in owner_udp if (key in UDP_ONLY or key in BOTH) else False
    return (owner_tcp.get(pt) if t else None) or (owner_udp.get(pt) if u else None)
def claim(pt, key):
    if key not in UDP_ONLY: owner_tcp[pt] = "new config"
    if key in UDP_ONLY or key in BOTH: owner_udp[pt] = "new config"
def free_port(key):
    for pt in PREF[key]:
        if not busy(pt, key):
            return pt
    # Cloudflare only proxies its own HTTPS ports, so CDN configs cannot move elsewhere
    if key in ("ws", "hu", "cg") or (key == "tx" and CDN):
        return None
    for pt in range(20000, 60000, 7):
        if not busy(pt, key):
            return pt
    return None

head("Ports")
PLAN = {}
for key, name, _, _ in SEL:
    pt = free_port(key)
    if pt is None:
        warn(f"{name}: no free port (Cloudflare ports {' '.join(map(str, CF_HTTPS))} are all busy); skipped")
        continue
    if pt != PREF[key][0]:
        print(f"  {name:26s} port {PREF[key][0]} is used by {busy(PREF[key][0], key)}")
    PLAN[key] = pt
    claim(pt, key)
    print(f"  {name:26s} port {pt}{'/udp' if key in UDP_ONLY else ''}", flush=True)
if not PLAN:
    die("No config could get a port.")

# =========================================================================== REALITY targets + clean IPs
def tls13_h2(sni):
    out = sh(f"echo | timeout 6 openssl s_client -connect {sni}:443 -servername {sni} -alpn h2 -tls1_3 2>/dev/null", 10)
    return "TLSv1.3" in out and "ALPN protocol: h2" in out
SNI_POOL = ["dl.google.com", "addons.mozilla.org", "www.samsung.com", "www.nvidia.com", "www.speedtest.net",
            "www.amd.com", "www.asus.com", "www.lovelive-anime.jp"]
if any(k in PLAN for k in ("rv", "rx", "ro", "rp", "rg", "tr")):
    with cfut.ThreadPoolExecutor(8) as ex:
        okmap = dict(zip(SNI_POOL, ex.map(tls13_h2, SNI_POOL)))
    GOOD_SNI = [s for s in SNI_POOL if okmap[s]] or SNI_POOL
else:
    GOOD_SNI = SNI_POOL
sni = lambda i: GOOD_SNI[i % len(GOOD_SNI)]

FALLBACK_CLEAN = """time.is creativecommons.org www.digitalocean.com www.canva.com www.npmjs.com www.udemy.com cdnjs.com
172.67.153.64 141.101.120.172 104.19.214.18 104.16.165.243 188.114.98.19 172.66.160.120 190.93.246.88 188.114.99.132
104.17.24.19 104.21.114.162 104.24.68.75 188.114.97.156 162.159.140.108 141.101.121.20 104.21.63.243 188.114.97.251
104.27.49.141 190.93.244.210 104.25.60.147 104.16.77.102 188.114.96.74 104.27.96.96 104.18.29.233 104.19.44.112""".split()
CLEAN = []
cdn_port = next((PLAN[k] for k in ("ws", "hu", "tx") if k in PLAN), None)
if CLEAN_N and CDN and cdn_port:
    lst = curl(["-fL", CLEAN_URL], t=10) if CLEAN_URL else ""
    cand = [l.split("#")[0].strip() for l in lst.splitlines()]
    cand = [c for c in cand if re.match(r"^[A-Za-z0-9.-]{3,253}$", c)] or FALLBACK_CLEAN
    def via_cf(a):
        ip = a if re.match(r"^[\d.]+$", a) else (next((x for x in ips_of(a) if ":" not in x), "") or "")
        if not ip or not is_cf(ip):
            return None
        r = curl(["-o", "/dev/null", "-w", "%{http_code} %{time_connect}", "--resolve", f"{CDN}:{cdn_port}:{ip}",
                  f"https://{CDN}:{cdn_port}/"], t=6)
        code, _, t = r.partition(" ")
        return a if code and code != "000" else None
    info(f"checking {len(cand)} Cloudflare clean IPs / domains against {CDN} ...")
    with cfut.ThreadPoolExecutor(16) as ex:
        CLEAN = [r for r in ex.map(via_cf, cand) if r][:CLEAN_N]
    info(f"{len(CLEAN)} clean addresses ready")

# =========================================================================== builders
hx = secrets.token_hex
def x25519():
    d = {}
    for l in sh(f"{XRAY} x25519").splitlines():
        k, _, v = l.partition(":"); d[k.strip()] = v.strip()
    priv = d.get("PrivateKey") or d.get("Private key")
    pub = d.get("Password (PublicKey)") or d.get("Password") or d.get("PublicKey") or d.get("Public key")
    if not (priv and pub):
        raise RuntimeError("could not generate a REALITY key pair")
    return priv, pub
def vlessenc():
    out = sh(f"{XRAY} vlessenc").splitlines()
    for n, l in enumerate(out):
        if "X25519" in l and n + 2 < len(out):
            return out[n + 1].split('"')[3], out[n + 2].split('"')[3]
    raise RuntimeError("this Xray has no 'vlessenc' (update Xray-core)")
def reality(network, target, extra):
    priv, pub = x25519()
    s = {"network": network, "security": "reality", "externalProxy": [],
         "realitySettings": {"show": False, "xver": 0, "target": f"{target}:443", "serverNames": [target],
                             "privateKey": priv, "minClientVer": "", "maxClientVer": "", "maxTimediff": 0,
                             "shortIds": [hx(4), hx(8)],
                             "settings": {"publicKey": pub, "fingerprint": "chrome", "serverName": "", "spiderX": "/"}}}
    s.update(extra); return s
def tls(alpn):
    return {"serverName": DOMAIN, "minVersion": "1.2", "maxVersion": "1.3", "cipherSuites": "", "rejectUnknownSni": False,
            "disableSystemRoot": False, "enableSessionResumption": False,
            "certificates": [{"certificateFile": CERT, "keyFile": KEY, "oneTimeLoading": False, "usage": "encipherment",
                              "buildChain": False}],
            "alpn": alpn, "settings": {"fingerprint": "chrome", "echConfigList": ""}}
def tls_stream(network, extra, alpn):
    s = {"network": network, "security": "tls", "externalProxy": [], "tlsSettings": tls(alpn)}; s.update(extra); return s
TCP = {"tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}}}
def XH(**over):
    x = {"path": "/" + hx(5), "host": "", "mode": "auto", "xPaddingBytes": "100-1000",
         "noSSEHeader": False, "scMaxEachPostBytes": "1000000", "scMaxBufferedPosts": 30}
    x.update(over); return x
# XHTTP "extra": the padding moves into the Referer query under a random key, written as tokens
XH_OBFS = lambda: XH(xPaddingObfsMode=True, xPaddingKey="x" + hx(3), xPaddingHeader="Referer",
                     xPaddingPlacement="queryInHeader", xPaddingMethod="tokenish")
VL = lambda: {"clients": [], "decryption": "none", "fallbacks": []}
def VLE():
    dec, enc = vlessenc()
    return {"clients": [], "decryption": dec, "encryption": enc}
FRAG = json.dumps({"tcp": [{"type": "fragment", "settings": {"packets": "tlshello", "lengths": ["10-30"], "delays": ["5-15"]}}]})
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"], "metadataOnly": False, "routeOnly": True}
def ws_stream():
    return tls_stream("ws", {"wsSettings": {"acceptProxyProtocol": False, "path": "/" + hx(5), "host": "", "headers": {},
                                            "heartbeatPeriod": 30}}, ["http/1.1"])
def hu_stream():
    return tls_stream("httpupgrade", {"httpupgradeSettings": {"acceptProxyProtocol": False, "path": "/" + hx(5), "host": "",
                                                              "headers": {}}}, ["http/1.1"])
def pq():
    return (VLE(), {"network": "tcp", "security": "none", "externalProxy": [], **TCP,
                    "finalmask": {"tcp": [{"type": "sudoku", "settings": {"password": hx(16), "ascii": "prefer_entropy",
                                                                           "paddingMin": 2, "paddingMax": 7}}]}})
def kc():
    return (VLE(), {"network": "kcp", "security": "none", "externalProxy": [],
                    "kcpSettings": {"mtu": 1350, "tti": 20, "uplinkCapacity": 5, "downlinkCapacity": 20,
                                    "cwndMultiplier": 1, "maxSendingWindow": 2097152},
                    "finalmask": {"udp": [{"type": "mkcp-legacy", "settings": {"header": "", "value": ""}}]}})
BUILD = {
    "rv": ("vless", lambda: (VL(), reality("tcp", sni(0), TCP))),
    "rx": ("vless", lambda: (VL(), reality("xhttp", sni(1), {"xhttpSettings": XH()}))),
    "ro": ("vless", lambda: (VL(), reality("xhttp", sni(3), {"xhttpSettings": XH_OBFS()}))),
    "rp": ("vless", lambda: (VL(), reality("xhttp", sni(4), {"xhttpSettings": XH(mode="packet-up")}))),
    "rg": ("vless", lambda: (VL(), reality("grpc", sni(2), {"grpcSettings": {"serviceName": hx(4), "authority": "",
                                                                             "multiMode": True}}))),
    "tv": ("vless", lambda: (VL(), tls_stream("tcp", TCP, ["h2", "http/1.1"]))),
    "tx": ("vless", lambda: (VL(), tls_stream("xhttp", {"xhttpSettings": XH()}, ["h2", "http/1.1"]))),
    "ws": ("vless", lambda: (VL(), ws_stream())),
    "hu": ("vless", lambda: (VL(), hu_stream())),
    "hy": ("hysteria", lambda: ({"version": 2, "clients": []},
                                {"network": "hysteria", "security": "tls", "externalProxy": [], "tlsSettings": tls(["h3"]),
                                 "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60,
                                                      "masquerade": {"type": "proxy", "url": "https://www.bing.com",
                                                                     "rewriteHost": True}},
                                 "finalmask": {"udp": [{"type": "salamander", "settings": {"password": hx(16)}}],
                                               "quicParams": {"congestion": "bbr"}}})),
    "cg": ("vless", lambda: (VL(), tls_stream("grpc", {"grpcSettings": {"serviceName": hx(4), "authority": "",
                                                                         "multiMode": False}}, ["h2"]))),
    "th": ("vless", lambda: (VL(), tls_stream("xhttp", {"xhttpSettings": XH()}, ["h3"]))),
    # no TLS here: VLESS Encryption is the security layer Xray asks for
    "ew": ("vless", lambda: (VLE(), {"network": "ws", "security": "none", "externalProxy": [],
                                     "wsSettings": {"acceptProxyProtocol": False, "path": "/" + hx(5), "host": "",
                                                    "headers": {}, "heartbeatPeriod": 30}})),
    "ex": ("vless", lambda: (VLE(), {"network": "xhttp", "security": "none", "externalProxy": [],
                                     "xhttpSettings": XH()})),
    "tt": ("trojan", lambda: ({"clients": [], "fallbacks": []}, tls_stream("tcp", TCP, ["h2", "http/1.1"]))),
    "tr": ("trojan", lambda: ({"clients": [], "fallbacks": []}, reality("tcp", sni(5), TCP))),
    "pq": ("vless", pq),
    "kc": ("vless", kc),
    "ss": ("shadowsocks", lambda: ({"method": "2022-blake3-aes-256-gcm", "password": base64.b64encode(secrets.token_bytes(32)).decode(),
                                    "network": "tcp,udp", "clients": [], "ivCheck": False},
                                   {"network": "tcp", "security": "none", "externalProxy": [], **TCP})),
}
def cdn_host(name, addr):
    return (name, addr, {"sni": CDN, "hostHeader": CDN, "finalMask": FRAG})
def plain(key, name):
    # direct link, plus one through Cloudflare when the port is one Cloudflare proxies without TLS
    h = [(f"🔑 {name}", ADDR, {})]
    if CDN and PLAN.get(key) in CF_HTTP:
        h.append((f"☁️ CDN {name} · HTTP", CDN, {"hostHeader": CDN}))
    return h
def HOSTS(key):
    v6 = lambda n, ex={}: [(f"6️⃣ {n} · IPv6", PUB6, ex)] if PUB6 else []
    if key == "rv": return [("⚡ Reality Vision · Main", ADDR, {})] + v6("Reality Vision")
    if key == "rx": return [("🌀 Reality XHTTP", ADDR, {})] + v6("Reality XHTTP")
    if key == "ro": return [("🎭 Reality XHTTP · Obfs", ADDR, {})]
    if key == "rp": return [("📦 Reality XHTTP · Packet-up", ADDR, {})]
    if key == "rg": return [("🔷 Reality gRPC", ADDR, {})]
    if key == "tv": return [("🔐 TLS Vision", ADDR, {"sni": DOMAIN}),
                            ("🧩 TLS Vision · Fragment", ADDR, {"sni": DOMAIN, "finalMask": FRAG})] + v6("TLS Vision", {"sni": DOMAIN})
    if key == "tx":
        d = {"sni": DOMAIN, "hostHeader": DOMAIN}
        return [("🛰 TLS XHTTP", ADDR, d), ("🧩 TLS XHTTP · Fragment", ADDR, {**d, "finalMask": FRAG})] \
            + v6("TLS XHTTP", d) + ([cdn_host("☁️ CDN XHTTP · Fragment", CDN)] if CDN else [])
    if key == "ws": return [cdn_host("☁️ CDN WS · Fragment", CDN)]
    if key == "hu": return [cdn_host("☁️ CDN HTTPUpgrade · Fragment", CDN)]
    if key == "hy": return [("🚄 Hysteria2 · UDP", ADDR, {"sni": DOMAIN})] + v6("Hysteria2", {"sni": DOMAIN})
    if key == "cg": return [cdn_host("☁️ CDN gRPC · Fragment", CDN)]
    if key == "th": return [("🚀 TLS XHTTP · H3", ADDR, {"sni": DOMAIN, "hostHeader": DOMAIN})]
    if key == "ew": return plain("ew", "Enc WS")
    if key == "ex": return plain("ex", "Enc XHTTP")
    if key == "tt": return [("🐴 Trojan TLS", ADDR, {"sni": DOMAIN})]
    if key == "tr": return [("🐴 Trojan Reality", ADDR, {})]
    if key == "pq": return [("🧬 PQ Sudoku", ADDR, {})]
    if key == "kc": return [("🧬 PQ mKCP · UDP", ADDR, {})]
    if key == "ss": return [("🛟 Shadowsocks · Backup", ADDR, {})]
    return []

# =========================================================================== apply
head("Adding")
bak = f"{DB}.bak-pro-{int(time.time())}"
if os.path.exists(DB):
    shutil.copy(DB, bak); info("database backup:", bak)
emails = {c.get("email") for c in clients}
if OLD:
    EMAIL, SUBID = OLD["email"], OLD["subId"]
else:
    EMAIL = EMAIL_WANT or f"pineapple-{hx(4)}"
    while EMAIL in emails:
        EMAIL = f"{EMAIL}-{hx(1)}"
    SUBID = SUBID_WANT if SUBID_WANT and not any(c.get("subId") == SUBID_WANT for c in clients) else \
        "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(16))
CLIENT = {"email": EMAIL, "subId": SUBID, "flow": "xtls-rprx-vision",
          "password": base64.b64encode(secrets.token_bytes(32)).decode(),   # also a valid SS-2022 key
          "totalGB": 0, "expiryTime": 0, "limitIp": 0, "limitHwid": 0, "enable": True, "tgId": 0, "comment": MARK}
def restart():
    api("/panel/api/server/restartXrayService", post=True)
def xray_ok(pt, udp):
    for _ in range(10):
        time.sleep(1.5)
        if ((api("/panel/api/server/status").get("obj") or {}).get("xray") or {}).get("state") == "running":
            if "xray" in sh(f"ss -H -{'u' if udp else 't'}lnp 'sport = :{pt}'"):
                return True
    return False
def remove(key, iid):
    api(f"/panel/api/clients/{EMAIL}/detach", {"inboundIds": [iid]})
    api(f"/panel/api/inbounds/del/{iid}", post=True); restart(); time.sleep(3)

added, made_client = [], bool(OLD)
for key, name, _, _ in SEL:
    if key not in PLAN:
        continue
    pt = PLAN[key]; proto, build = BUILD[key]
    try:
        st, stream = build()
    except Exception as e:
        warn(f"{name}: {e}; skipped"); continue
    r = api("/panel/api/inbounds/add", {"up": 0, "down": 0, "total": 0, "remark": REMARK[key], "enable": True, "expiryTime": 0,
                                        "listen": "", "port": pt, "protocol": proto, "settings": st,
                                        "streamSettings": stream, "sniffing": SNIFF})
    iid = (r.get("obj") or {}).get("id") if isinstance(r.get("obj"), dict) else None
    if not r.get("success") or not iid:
        warn(f"{name}: panel refused ({r.get('msg')}); skipped"); continue
    if not made_client:
        cr = api("/panel/api/clients/add", {"client": CLIENT, "inboundIds": [iid]})
        made_client = bool(cr.get("success"))
        if not made_client:
            api(f"/panel/api/inbounds/del/{iid}", post=True); die("could not create client:", cr.get("msg"))
    else:
        api(f"/panel/api/clients/{EMAIL}/attach", {"inboundIds": [iid]})
    restart()
    if xray_ok(pt, key in UDP_ONLY):
        added.append((key, iid)); info(f"added {name:26s} port {pt}")
    else:
        warn(f"{name}: Xray on this server rejected it; removed again")
        remove(key, iid)
if not added:
    die("No config could be added.")

# naming: every link gets its own name through Hosts + remarkTemplate {{HOST}};
# the subscription gets the panel certificate so the links are not served in clear text
settings = api("/panel/api/setting/all", post=True).get("obj") or settings
chg = False
if "{{HOST}}" not in (settings.get("remarkTemplate") or ""):
    settings["remarkTemplate"] = "{{HOST}}"; chg = True
if not settings.get("subJsonEnable"):
    settings["subJsonEnable"] = True; chg = True
if CERT and not (settings.get("subCertFile") and settings.get("subKeyFile")):
    settings["subCertFile"], settings["subKeyFile"] = CERT, KEY; chg = True
if chg:
    info("panel settings:", api("/panel/api/setting/update", settings).get("msg"))

clean_key = next((k for k in ("ws", "hu", "tx") if k in dict(added)), None)
n_links = 0
for order, (key, iid) in enumerate(added):
    api(f"/panel/api/inbounds/{iid}/subSortIndex", {"subSortIndex": 100 + order})
    hosts = HOSTS(key)
    if key == clean_key and CLEAN:
        hosts += [cdn_host(f"🧊 Clean {i:02d} · {a}", a) for i, a in enumerate(CLEAN, 1)]
    for i, (rem, addr, extra) in enumerate(hosts):
        if not addr:
            continue
        r = api("/panel/api/hosts/add", {"inboundIds": [iid], "remark": rem, "hosts": [addr], "port": 0,
                                         "security": "same", "sortOrder": i, **extra})
        n_links += bool(r.get("success"))
        if not r.get("success"):
            warn(f"host {rem}: {r.get('msg')}")

if not NO_BBR and "bbr" not in sh("sysctl -n net.ipv4.tcp_congestion_control"):
    with open("/etc/sysctl.d/99-bbr.conf", "w") as f:
        f.write("net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n")
    sh("modprobe tcp_bbr; sysctl --system")
    info("BBR:", sh("sysctl -n net.ipv4.tcp_congestion_control"))
info("restarting panel ...")
api("/panel/api/setting/restartPanel", post=True); time.sleep(8); restart(); time.sleep(4)

settings = api("/panel/api/setting/all", post=True).get("obj") or settings
SUB, JSUB, shost, sport = sub_urls(settings, SUBID)

# =========================================================================== test
passed = total = 0
results = []
if not NO_TEST and XRAY:
    head("Testing every config (client -> this server -> internet)")
    try:
        subs = json.loads(curl(["--resolve", f"{shost}:{sport}:127.0.0.1", JSUB], t=20))
        subs = subs if isinstance(subs, list) else [subs]
    except Exception:
        subs = []; warn("could not read the JSON subscription")
    ins, outs, rules, meta = [], [], [], []
    for n, cfg in enumerate(subs):
        o = next((x for x in cfg.get("outbounds", []) if x.get("tag") == "proxy"), None)
        if not o:
            continue
        s = o.get("settings", {})
        via_cdn = CDN and (o.get("streamSettings", {}).get("tlsSettings") or {}).get("serverName") == CDN
        def fix(a):
            if via_cdn or (CDN and a == CDN): return a              # really go through Cloudflare
            return "::1" if PUB6 and a == PUB6 else "127.0.0.1"
        for k in ("vnext", "servers"):
            for srv in s.get(k, []) or []: srv["address"] = fix(srv.get("address"))
        if "address" in s: s["address"] = fix(s["address"])
        o["tag"] = f"p{n}"; outs.append(o)
        ins.append({"tag": f"s{n}", "listen": "127.0.0.1", "port": 23000 + n, "protocol": "socks", "settings": {"udp": True}})
        rules.append({"type": "field", "inboundTag": [f"s{n}"], "outboundTag": f"p{n}"})
        meta.append((str(cfg.get("remarks", f"#{n}")), 23000 + n))
    if outs:
        fd, e2e = tempfile.mkstemp(prefix=".3xui-pro-e2e.", suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump({"log": {"loglevel": "none"}, "inbounds": ins, "outbounds": outs + [{"protocol": "freedom", "tag": "d"}],
                       "routing": {"rules": rules}}, f)
        pr = subprocess.Popen([XRAY, "run", "-c", e2e], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        time.sleep(3)
        def probe(m):
            name, pt = m
            for _ in range(2):
                if sh(f"curl -s -o /dev/null -m 15 -w '%{{http_code}}' --socks5-hostname 127.0.0.1:{pt} "
                      "https://www.google.com/generate_204", 20) == "204":
                    return name, True
            return name, False
        try:
            with cfut.ThreadPoolExecutor(6) as ex:
                for name, ok in ex.map(probe, meta):
                    results.append((name, ok)); total += 1; passed += ok
                    print(f"  {'OK  ' if ok else 'FAIL'} {name}", flush=True)
        finally:
            pr.terminate()
            try: os.remove(e2e)
            except Exception: pass
        # the newer combos stay only when they really work end to end
        if passed:
            for key, iid in list(added):
                if key not in EXTRA:
                    continue
                names = [h[0] for h in HOSTS(key)]
                res = [ok for name, ok in results if any(nm in name for nm in names)]
                if res and not any(res):
                    warn(f"{REMARK[key]} failed its self-test; removed again")
                    remove(key, iid); added.remove((key, iid))
                    total -= len(res); n_links -= len(res)
        info(f"{passed}/{total} configs work")

# =========================================================================== done
head("Configs")
for key, _ in added:
    print(f"  {REMARK[key]:30s} {PLAN[key]}/{'udp' if key in UDP_ONLY else ('tcp+udp' if key in BOTH else 'tcp')}")
if CDN:
    print(f"  Cloudflare: {CDN} = proxied (orange) · {DOMAIN} = DNS only (grey) · SSL/TLS = Full")
print(f"  database backup: {bak}", flush=True)
ports = []
for key, _ in added:
    if key not in UDP_ONLY: ports.append(f"{PLAN[key]}/tcp")
    if key in UDP_ONLY or key in BOTH: ports.append(f"{PLAN[key]}/udp")
write_result(PRO_EXISTING=0, PRO_SUB_URL=SUB, PRO_JSON_URL=JSUB, PRO_SUB_ID=SUBID, PRO_CLIENT=EMAIL, PRO_SUB_PORT=sport,
             PRO_PORTS=" ".join(ports), PRO_COUNT=len(added), PRO_LINKS=n_links,
             PRO_TEST=(f"{passed}/{total}" if total else ""))
PYEOF
}

create_pro_configs() {
  if [[ $SKIP_INBOUNDS -eq 1 ]]; then
    warn "Config creation skipped (--no-inbounds / SKIP_INBOUNDS=1)."
    return 0
  fi
  if [[ -z ${XUI_API_TOKEN:-} ]] && [[ -z $PANEL_USER || -z $PANEL_PASS ]]; then
    warn "Panel credentials are unknown; skipping config creation."
    warn "Pass XUI_USERNAME/XUI_PASSWORD (or XUI_API_TOKEN) and re-run."
    INBOUND_FAILED=1
    return 0
  fi

  local py result rc
  py=$(mktemp /tmp/3xui-pro.XXXXXX)
  result=$(mktemp /tmp/3xui-pro-result.XXXXXX)
  write_pro_py > "$py"

  say "Adding the config set through the panel API ..."
  set +e
  env \
    PRO_DOMAIN="$DOMAIN" PRO_PANEL_PORT="$ACTUAL_PORT" PRO_PANEL_PATH="$ACTUAL_PATH" \
    PRO_USER="$PANEL_USER" PRO_PASS="$PANEL_PASS" PRO_TOKEN="${XUI_API_TOKEN:-}" \
    PRO_CERT="$CERT_FILE" PRO_KEY="$KEY_FILE" \
    PRO_CDN="$CDN_DOMAIN" PRO_CONFIGS="$CONFIG_LIST" PRO_CLEAN="$CLEAN_COUNT" \
    PRO_EMAIL="${XUI_CLIENT_NAME:-}" PRO_SUBID="${XUI_SUB_ID:-}" \
    PRO_FORCE="$ADD_CONFIGS" PRO_NO_BBR="$NO_BBR" PRO_NO_TEST="$NO_TEST" \
    PRO_RESULT="$result" PRO_CLEAN_URL="$CLEAN_IPS_URL" PRO_XUI_DIR="$XUI_DIR" \
    python3 -I "$py"
  rc=$?
  set -e

  if [[ -s $result ]]; then
    # shellcheck disable=SC1090
    . "$result"
  fi
  rm -f "$py" "$result"

  if ((rc != 0)); then
    warn "The config step failed (exit ${rc}); see the messages above."
    INBOUND_FAILED=1
  fi
  SUB_URL="$PRO_SUB_URL"
  open_config_ports
  return 0
}

# Ports are only known once the configs exist, so they are opened afterwards.
open_config_ports() {
  [[ $OPEN_FIREWALL -eq 1 ]] || return 0
  local e opened=0
  for e in $PRO_PORTS ${PRO_SUB_PORT:+${PRO_SUB_PORT}/tcp}; do
    [[ $e =~ ^[0-9]+/(tcp|udp)$ ]] || continue
    if ufw_is_active; then
      ufw allow "$e" > /dev/null 2>&1 || true
      opened=1
    fi
    if firewalld_is_active; then
      firewall-cmd --permanent --add-port="$e" > /dev/null 2>&1 || true
      opened=1
    fi
  done
  if firewalld_is_active; then
    firewall-cmd --reload > /dev/null 2>&1 || true
  fi
  if [[ $opened -eq 1 ]]; then
    say "Opened the config and subscription ports in the local firewall."
  fi
}

ensure_qrencode() {
  command -v qrencode > /dev/null 2>&1 && return 0
  if command -v apt-get > /dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=120 install -y -qq qrencode > /dev/null 2>&1 || true
  fi
  command -v qrencode > /dev/null 2>&1
}

print_subscription() {
  [[ $SKIP_INBOUNDS -eq 1 ]] && return 0
  [[ -n $SUB_URL ]] || return 0

  printf '\n'
  printf '==============================================================\n'
  printf ' Subscription\n'
  printf '==============================================================\n'
  if ensure_qrencode; then
    if ! qrencode -t UTF8 -m 2 -l M "$SUB_URL"; then
      warn "Could not render the QR code."
    fi
  else
    warn "qrencode is not installed; skipping the QR code (the link is below)."
  fi
  printf '\n Subscription link:\n   %s\n' "$SUB_URL"
  if [[ -n $PRO_JSON_URL ]]; then
    printf '\n JSON subscription (use this one for Fragment / FinalMask configs,\n'
    printf ' needs a client with Xray-core 26+ such as a recent v2rayNG / v2rayN):\n   %s\n' "$PRO_JSON_URL"
  fi
  if [[ $SUB_URL == http://* ]]; then
    warn "The subscription is served over HTTP (no subscription certificate)."
  fi
  printf '==============================================================\n'
}

load_saved_info() {
  local f
  for f in "$INFO_FILE" /etc/x-ui/install-result.env; do
    [[ -r $f ]] || continue
    set +u
    # shellcheck disable=SC1090
    . "$f"
    set -u
    if [[ -n ${XUI_USERNAME:-} && -n ${XUI_PASSWORD:-} ]]; then
      return 0
    fi
  done
  return 1
}

write_info() {
  local tmp url
  if [[ -n $ACTUAL_PATH ]]; then
    url="https://${DOMAIN}:${ACTUAL_PORT}/${ACTUAL_PATH}/"
  else
    url="https://${DOMAIN}:${ACTUAL_PORT}/"
  fi
  tmp=$(mktemp)
  {
    printf '# 3x-ui panel info, generated %s\n' "$(date -Is)"
    printf "XUI_DOMAIN='%s'\n" "$DOMAIN"
    printf "XUI_ACME_HTTP_PORT='%s'\n" "$ACME_PORT"
    printf "XUI_PANEL_PORT='%s'\n" "$ACTUAL_PORT"
    printf "XUI_WEB_BASE_PATH='%s'\n" "$ACTUAL_PATH"
    printf "XUI_USERNAME='%s'\n" "$PANEL_USER"
    printf "XUI_PASSWORD='%s'\n" "$PANEL_PASS"
    printf "XUI_ACCESS_URL='%s'\n" "$url"
    printf "XUI_CERT_FILE='%s'\n" "$CERT_FILE"
    printf "XUI_KEY_FILE='%s'\n" "$KEY_FILE"
    printf "XUI_SUB_ID='%s'\n" "${PRO_SUB_ID:-${XUI_SUB_ID:-}}"
    printf "XUI_SUB_URL='%s'\n" "$PRO_SUB_URL"
    printf "XUI_JSON_SUB_URL='%s'\n" "$PRO_JSON_URL"
    printf "XUI_CLIENT='%s'\n" "$PRO_CLIENT"
  } > "$tmp"
  install -m 600 "$tmp" "$INFO_FILE"
  rm -f "$tmp"
}

print_summary() {
  local url expires
  if [[ -n $ACTUAL_PATH ]]; then
    url="https://${DOMAIN}:${ACTUAL_PORT}/${ACTUAL_PATH}/"
  else
    url="https://${DOMAIN}:${ACTUAL_PORT}/"
  fi
  expires=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires="unknown"

  printf '\n'
  printf '==============================================================\n'
  printf ' 3x-ui is ready\n'
  printf '==============================================================\n'
  printf ' Panel URL   : %s\n' "$url"
  if [[ -n $PANEL_USER && -n $PANEL_PASS ]]; then
    printf ' Username    : %s\n' "$PANEL_USER"
    printf ' Password    : %s\n' "$PANEL_PASS"
  else
    printf ' Credentials : unchanged / unknown (existing installation)\n'
  fi
  printf ' Certificate : %s\n' "$CERT_FILE"
  if [[ $ACME_MODE == nginx ]]; then
    printf ' Expires     : %s (certbot renews it through nginx)\n' "${expires:-unknown}"
  else
    printf ' Expires     : %s (acme.sh listener TCP/%s)\n' "${expires:-unknown}" "$ACME_PORT"
  fi
  printf ' Info file   : %s\n' "$INFO_FILE"
  printf '%s\n' '--------------------------------------------------------------'
  if [[ $SKIP_INBOUNDS -eq 1 ]]; then
    printf ' Configs     : skipped (--no-inbounds)\n'
  elif [[ $PRO_EXISTING == 1 ]]; then
    printf ' Configs     : complete, nothing to add (client %s)\n' "${PRO_CLIENT:-?}"
  elif [[ -n $PRO_SUB_URL ]]; then
    printf ' Configs     : %s inbounds, %s links added (client %s)\n' "$PRO_COUNT" "$PRO_LINKS" "$PRO_CLIENT"
    if [[ -n $PRO_TEST ]]; then
      printf ' Self-test   : %s links work\n' "$PRO_TEST"
    fi
    printf ' Ports       : %s\n' "${PRO_PORTS:-none}"
  else
    printf ' Configs     : none added\n'
  fi
  if [[ $INBOUND_FAILED -eq 1 ]]; then
    printf '\n [!] The config step did not finish cleanly; see the messages above.\n'
  fi
  printf '\n'
  printf ' Next step: run "x-ui" for the management menu.\n'
  printf ' Open in your provider firewall / security group (IPv4 + IPv6):\n'
  printf '   %s/tcp (panel)\n' "$ACTUAL_PORT"
  if [[ -n $PRO_SUB_PORT ]]; then
    printf '   %s/tcp (subscription)\n' "$PRO_SUB_PORT"
  fi
  if [[ -n $PRO_PORTS ]]; then
    printf '   %s\n' "$PRO_PORTS"
  fi
  printf '==============================================================\n'
}

main() {
  require_root "$@"
  parse_args "$@"
  resolve_domain
  setup_logging
  trap '_on_err $LINENO' ERR

  say "=== 3x-ui unattended setup ==="
  say "domain  : ${DOMAIN}"

  ensure_prereqs
  resolve_panel_version
  say "version : ${PANEL_VERSION:-latest}"
  load_os
  precheck_dns
  precheck_port80
  precheck_domain_free
  precheck_disk

  local installed=0
  if [[ -x $XUI_BIN ]]; then
    installed=1
  fi

  if [[ $installed -eq 1 ]]; then
    load_saved_info || true
    PANEL_USER="${XUI_USERNAME:-${PANEL_USER:-}}"
    PANEL_PASS="${XUI_PASSWORD:-${PANEL_PASS:-}}"
    PANEL_PORT="$(get_setting port || true)"
    WEB_PATH="$(get_setting webBasePath || true)"
    WEB_PATH="${WEB_PATH#/}"
    WEB_PATH="${WEB_PATH%/}"

    if [[ $FORCE_INSTALL -eq 0 ]]; then
      warn "3x-ui is already installed at ${XUI_DIR}; skipping the install step."
      local have
      have=$(installed_panel_version || true)
      if [[ -n $have && -n $PANEL_VERSION && $have != "${PANEL_VERSION#v}" ]]; then
        warn "Installed: v${have}, newest: ${PANEL_VERSION}. Use --force-install to update."
      else
        warn "Use --force-install to reinstall ${PANEL_VERSION:-the newest release}."
      fi
      precheck_firewall "${PANEL_PORT:-80}"
      if ! service_active; then
        warn "The panel service is not running; starting it."
        start_service || die "Could not start x-ui."
      fi
      wait_for_panel || die "x-ui did not become active."
    else
      if [[ -z $PANEL_PORT ]]; then
        PANEL_PORT="$(pick_panel_port)" || die "Could not find a free TCP port for the panel."
      fi
      [[ -n $WEB_PATH ]] || WEB_PATH="$(rand_hex 8)"
      precheck_firewall "$PANEL_PORT"
      install_panel
      wait_for_panel || die "x-ui did not start after installation."
    fi
  else
    PANEL_PORT="$(pick_panel_port)" || die "Could not find a free TCP port for the panel."
    PANEL_USER="xui$(rand_hex 3)"
    PANEL_PASS="$(rand_hex 16)"
    WEB_PATH="$(rand_hex 8)"
    precheck_firewall "$PANEL_PORT"
    install_panel
    wait_for_panel || die "x-ui did not start after installation."
  fi

  if ACTUAL_PORT=$(get_setting port); then
    ACTUAL_PORT="${ACTUAL_PORT:-$PANEL_PORT}"
  else
    ACTUAL_PORT="$PANEL_PORT"
  fi
  if ACTUAL_PATH=$(get_setting webBasePath); then
    ACTUAL_PATH="${ACTUAL_PATH#/}"
    ACTUAL_PATH="${ACTUAL_PATH%/}"
  else
    ACTUAL_PATH="$WEB_PATH"
  fi
  [[ -n $ACTUAL_PORT ]] || die "Could not read the panel port from ${XUI_BIN} setting -show."

  if [[ $ACME_MODE == nginx ]]; then
    CERT_FILE="${LE_LIVE}/${DOMAIN}/fullchain.pem"
    KEY_FILE="${LE_LIVE}/${DOMAIN}/privkey.pem"
  else
    CERT_FILE="${CERT_ROOT}/${DOMAIN}/fullchain.pem"
    KEY_FILE="${CERT_ROOT}/${DOMAIN}/privkey.pem"
  fi

  ensure_ssl

  # Add the configs first so their subId can be saved in the info file.
  create_pro_configs

  if [[ -n $PANEL_USER && -n $PANEL_PASS ]]; then
    write_info
    say "Panel info saved to ${INFO_FILE} (mode 600)."
  else
    warn "Panel credentials are not known to this script (existing installation)."
    warn "Reset them from the 'x-ui' menu (option 7) or pass XUI_USERNAME/XUI_PASSWORD."
  fi

  print_summary
  print_subscription

  if [[ $INBOUND_FAILED -eq 1 ]]; then
    exit 1
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
