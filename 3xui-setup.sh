#!/usr/bin/env bash
# =============================================================================
#  3x-ui unattended installer + Let's Encrypt certificate + VLESS inbounds
#
#  What it does
#    1. answers every install.sh question automatically (unattended mode)
#    2. installs 3x-ui v3.10.2 with SQLite and a random panel port
#    3. obtains a Let's Encrypt certificate for the given subdomain and points
#       the panel at it (the same code path as: x-ui -> 20 -> 1)
#    4. creates VLESS inbounds through the panel API:
#         XHTTP 8080/TCP, WebSocket 8585/TCP, mKCP 8443/UDP
#    5. prints the panel URL, credentials, per-inbound links, and a subscription
#       link with its QR code; saves everything to a root-only file
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
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

PANEL_VERSION="${XUI_VERSION:-v3.10.2}"
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

# Default inbounds created after the panel is secured.
INBOUND_XHTTP_PORT="${INBOUND_XHTTP_PORT:-8080}"
INBOUND_WS_PORT="${INBOUND_WS_PORT:-8585}"
INBOUND_MKCP_PORT="${INBOUND_MKCP_PORT:-8443}"
INBOUND_TLS="${INBOUND_TLS:-0}"
SKIP_INBOUNDS="${SKIP_INBOUNDS:-0}"
SUB_PORT="${SUB_PORT:-2096}"
XHTTP_PATH="${XHTTP_PATH:-/ananas}"
WS_PATH="${WS_PATH:-/popcorn}"
XHTTP_HOST="${XHTTP_HOST:-}"
WS_HOST="${WS_HOST:-}"

API_ROOT=""
API_COOKIE=""
API_CSRF=""
INBOUND_LIST=""
INBOUND_SUBID=""
INBOUND_CREATED=0
CREATED_PORTS=""
INBOUND_LINKS=()
INBOUND_FAILED=0
CLIENT_NAME=""

SUB_ENABLED="true"
SUB_SCHEME="https"
SUB_HOST=""
SUB_PORT_ACTUAL=""
SUB_PATH="/sub/"
SUB_DOMAIN=""
SUB_CERT=""
SUB_KEY=""
SUB_URL=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
3x-ui unattended installer + SSL + VLESS inbounds.

Usage:
  sudo bash 3xui-setup.sh [options] <subdomain>

Options:
  -d, --domain <name>   Panel subdomain (prompted once when omitted)
      --skip-dns-check  Do not verify that the subdomain points to this server
      --force-install   Reinstall/update even if 3x-ui is already installed
      --open-firewall   Open panel, inbound and subscription ports in ufw/firewalld
      --no-inbounds     Do not create the default VLESS inbounds
      --inbounds-tls    Use the panel certificate for XHTTP/WS inbounds
  -h, --help            Show this help

Certificate:
  TCP/80 free       acme.sh (standalone, the x-ui default) in /root/cert/<domain>
  nginx on TCP/80   certbot through nginx (dns-setup.sh / n8n-setup.sh on the
                    same server) in /etc/letsencrypt/live/<domain>; use a
                    subdomain of its own, not the DNS or n8n one

Default inbounds (created through the panel API at the end):
  VLESS + XHTTP  TCP 8080  (path /ananas, host = subdomain)
  VLESS + WS     TCP 8585  (path /popcorn, host = subdomain)
  VLESS + mKCP   UDP 8443  (finalmask: mkcp-legacy)
A single subscription link (with QR code) is printed at the end.

Environment:
  XUI_VERSION          panel version to install      (default: v3.10.2)
  XUI_INSTALLER_URL    install.sh URL                (default: upstream master)
  XUI_INFO_FILE        panel info file               (default: /root/3xui-info.env)
  XUI_LOG_FILE         log file                      (default: /var/log/3xui-setup.log)
  XUI_ACME_EMAIL       certbot account email         (default: none; nginx mode only)
  INBOUND_XHTTP_PORT   XHTTP inbound port            (default: 8080)
  INBOUND_WS_PORT      WebSocket inbound port        (default: 8585)
  INBOUND_MKCP_PORT    mKCP UDP port                 (default: 8443)
  INBOUND_TLS          1 = TLS for XHTTP/WS          (default: 0)
  SKIP_INBOUNDS        1 = skip inbound creation     (default: 0)
  SUB_PORT             subscription port             (default: 2096)
  XUI_CLIENT_NAME      client name prefix            (default: random pineapple-XXXXXXXX)
  XHTTP_PATH           XHTTP path                    (default: /ananas)
  WS_PATH              WebSocket path                (default: /popcorn)
  XHTTP_HOST           XHTTP Host header             (default: the subdomain)
  WS_HOST              WebSocket Host header         (default: the subdomain)

Examples:
  sudo bash 3xui-setup.sh panel.example.com
  sudo bash 3xui-setup.sh --open-firewall --skip-dns-check panel.example.com
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
      --no-inbounds)
        SKIP_INBOUNDS=1
        shift
        ;;
      --inbounds-tls)
        INBOUND_TLS=1
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
  for cmd in curl openssl tar; do
    command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
  done
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
    if [[ $SKIP_INBOUNDS -eq 0 ]]; then
      ufw allow "${INBOUND_XHTTP_PORT}/tcp" > /dev/null 2>&1 || true
      ufw allow "${INBOUND_WS_PORT}/tcp" > /dev/null 2>&1 || true
      ufw allow "${INBOUND_MKCP_PORT}/udp" > /dev/null 2>&1 || true
      ufw allow "${SUB_PORT}/tcp" > /dev/null 2>&1 || true
    fi
    say "Opened ufw ports for the panel and inbounds."
  fi
  if firewalld_is_active; then
    firewall-cmd --permanent --add-port=80/tcp > /dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${port}/tcp" > /dev/null 2>&1 || true
    if [[ $SKIP_INBOUNDS -eq 0 ]]; then
      firewall-cmd --permanent --add-port="${INBOUND_XHTTP_PORT}/tcp" > /dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="${INBOUND_WS_PORT}/tcp" > /dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="${INBOUND_MKCP_PORT}/udp" > /dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="${SUB_PORT}/tcp" > /dev/null 2>&1 || true
    fi
    firewall-cmd --reload > /dev/null 2>&1 || true
    say "Opened firewalld ports for the panel and inbounds."
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

install_panel() {
  local tmp rc
  local env_args=(
    XUI_NONINTERACTIVE=1
    XUI_DB_TYPE=sqlite
    XUI_PANEL_PORT="$PANEL_PORT"
    XUI_WEB_BASE_PATH="$WEB_PATH"
  )
  if [[ $ACME_MODE == nginx ]]; then
    # acme.sh standalone cannot bind TCP/80 next to nginx; certbot does it later
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
    die "This installer does not support unattended mode. Set XUI_INSTALLER_URL to the v3.10.2 install.sh."
  fi

  say "Installing 3x-ui ${PANEL_VERSION} (unattended; this can take a few minutes) ..."
  set +e
  env "${env_args[@]}" bash "$tmp" "$PANEL_VERSION"
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

  answers=$(printf '20\n1\n%s\n80\nn\ny\n0\n0\n' "$DOMAIN")
  say "Requesting a certificate for ${DOMAIN} (ACME HTTP-01, port 80) ..."

  set +e
  printf '%s\n' "$answers" | timeout 900 "$menu"
  rc=$?
  set -e
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

# acme.sh renews in standalone mode on TCP/80. If nginx arrives later
# (dns-setup.sh / n8n-setup.sh), these hooks stop it for the few seconds the
# renewal needs and start it again.
install_acme_hooks() {
  local f="" dir
  for dir in "/root/.acme.sh/${DOMAIN}_ecc" "/root/.acme.sh/${DOMAIN}"; do
    if [[ -f ${dir}/${DOMAIN}.conf ]]; then
      f="${dir}/${DOMAIN}.conf"
      break
    fi
  done
  if [[ -z $f ]]; then
    warn "No acme.sh config for ${DOMAIN}; renewals cannot pause nginx if it is installed later."
    return 0
  fi
  cat > "$ACME_HOOK" << 'EOF'
#!/bin/sh
# Added by 3xui-setup.sh: acme.sh renews the panel certificate on TCP/80
# (standalone). Free the port from nginx for the renewal, then bring it back.
flag=/run/3xui-acme-stopped-nginx
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
  chmod 755 "$ACME_HOOK"
  # acme.sh reads plain values as well as its base64-wrapped ones
  set_acme_conf "$f" Le_PreHook "${ACME_HOOK} pre"
  set_acme_conf "$f" Le_PostHook "${ACME_HOOK} post"
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
# Panel API helpers (used to create the default inbounds at the end)
# ---------------------------------------------------------------------------
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

is_success() {
  local body=${1//[[:space:]]/}
  [[ $body == *'"success":true'* ]]
}

new_uuid() {
  local h variant
  h=$(rand_hex 16)
  h="${h:0:12}4${h:13}"
  variant=$(((16#${h:16:1} & 3) | 8))
  h="${h:0:16}$(printf '%x' "$variant")${h:17}"
  printf '%s-%s-%s-%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

udp_port_in_use() {
  local p=$1
  if command -v ss > /dev/null 2>&1; then
    ss -lun 2> /dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
  elif command -v netstat > /dev/null 2>&1; then
    netstat -lun 2> /dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
  else
    return 1
  fi
}

api_root() {
  local scheme base
  for scheme in https http; do
    if [[ -n $ACTUAL_PATH ]]; then
      base="${scheme}://127.0.0.1:${ACTUAL_PORT}/${ACTUAL_PATH}"
    else
      base="${scheme}://127.0.0.1:${ACTUAL_PORT}"
    fi
    if curl -ks --max-time 4 -o /dev/null "${base}/csrf-token" 2> /dev/null; then
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}

api_login() {
  local resp body csrf
  local args=()
  API_COOKIE=$(mktemp)
  trap 'rm -f "${API_COOKIE:-}"' EXIT

  resp=$(curl -ks -c "$API_COOKIE" --max-time 10 "${API_ROOT}/csrf-token" 2> /dev/null) || true
  csrf=$(printf '%s' "$resp" | sed -n 's/.*"obj"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  args=(-ks -b "$API_COOKIE" -c "$API_COOKIE" -H 'Content-Type: application/json' --max-time 15)
  [[ -n $csrf ]] && args+=(-H "X-CSRF-Token: ${csrf}")

  body=$(printf '{"username":"%s","password":"%s"}' \
    "$(json_escape "$PANEL_USER")" "$(json_escape "$PANEL_PASS")")
  resp=$(curl "${args[@]}" --data-binary "$body" "${API_ROOT}/login") || {
    warn "Could not reach the panel login endpoint."
    return 1
  }
  if ! is_success "$resp"; then
    warn "Panel login failed: ${resp}"
    return 1
  fi

  API_CSRF="$csrf"
  return 0
}

api_get() {
  curl -ks -b "$API_COOKIE" --max-time 20 "${API_ROOT}$1"
}

api_post() {
  local args=(-ks -b "$API_COOKIE" -H 'Content-Type: application/json' --max-time 30 -X POST)
  [[ -n $API_CSRF ]] && args+=(-H "X-CSRF-Token: ${API_CSRF}")
  curl "${args[@]}" --data-binary "$1" "${API_ROOT}$2"
}

fetch_inbounds() {
  local resp
  resp=$(api_get "/panel/api/inbounds/list") || return 1
  if ! is_success "$resp"; then
    warn "Could not list inbounds: ${resp}"
    return 1
  fi
  printf '%s' "$resp"
}

inbound_port_exists() {
  local p=$1
  printf '%s' "$INBOUND_LIST" \
    | grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' \
    | grep -o '[0-9]*$' \
    | grep -qx "$p"
}

build_vless_payload() {
  local uuid=$1 email=$2 subid=$3 remark=$4 tag=$5 port=$6 stream=$7
  local settings sniffing
  settings=$(cat << JSON
{"clients":[{"id":"${uuid}","flow":"","email":"${email}","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":"","subId":"${subid}","reset":0}],"decryption":"none","encryption":"none","fallbacks":[]}
JSON
  )
  sniffing='{"enabled":false}'
  cat << JSON
{"up":0,"down":0,"total":0,"remark":"${remark}","enable":true,"expiryTime":0,"listen":"","port":${port},"protocol":"vless","settings":"$(json_escape "$settings")","streamSettings":"$(json_escape "$stream")","sniffing":"$(json_escape "$sniffing")","tag":"${tag}"}
JSON
}

stream_xhttp() {
  local host="${XHTTP_HOST:-$DOMAIN}"
  local xhttp
  xhttp=$(cat << JSON
{"path":"${XHTTP_PATH}","host":"${host}","mode":"auto","xPaddingBytes":"100-1000","xPaddingObfsMode":false,"xPaddingKey":"","xPaddingHeader":"","xPaddingPlacement":"","xPaddingMethod":"","sessionIDPlacement":"","sessionIDKey":"","sessionIDTable":"","sessionIDLength":"","seqPlacement":"","seqKey":"","uplinkDataPlacement":"","uplinkDataKey":"","scMaxEachPostBytes":"","noSSEHeader":false,"scMaxBufferedPosts":30,"scStreamUpServerSecs":"20-80","serverMaxHeaderBytes":0,"uplinkHTTPMethod":"","headers":{},"scMinPostsIntervalMs":"","uplinkChunkSize":0,"noGRPCHeader":false}
JSON
  )
  if [[ $INBOUND_TLS -eq 1 ]]; then
    cat << JSON
{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"${DOMAIN}","alpn":["h2"],"certificates":[{"certificateFile":"${CERT_FILE}","keyFile":"${KEY_FILE}"}]},"xhttpSettings":${xhttp}}
JSON
  else
    cat << JSON
{"network":"xhttp","security":"none","xhttpSettings":${xhttp}}
JSON
  fi
}

stream_ws() {
  local host="${WS_HOST:-$DOMAIN}"
  local ws
  ws=$(cat << JSON
{"acceptProxyProtocol":false,"path":"${WS_PATH}","host":"${host}","headers":{},"heartbeatPeriod":0}
JSON
  )
  if [[ $INBOUND_TLS -eq 1 ]]; then
    cat << JSON
{"network":"ws","security":"tls","tlsSettings":{"serverName":"${DOMAIN}","alpn":["http/1.1"],"certificates":[{"certificateFile":"${CERT_FILE}","keyFile":"${KEY_FILE}"}]},"wsSettings":${ws}}
JSON
  else
    cat << JSON
{"network":"ws","security":"none","wsSettings":${ws}}
JSON
  fi
}

stream_kcp() {
  cat <<'JSON'
{"network":"kcp","security":"none","kcpSettings":{"mtu":1350,"tti":20,"uplinkCapacity":5,"downlinkCapacity":20,"cwndMultiplier":1,"maxSendingWindow":2097152},"finalmask":{"udp":[{"type":"mkcp-legacy","settings":{"header":"","value":""}}]}}
JSON
}

encode_path() {
  printf '%s' "$1" | sed 's#/#%2F#g'
}

inbound_link() {
  local kind=$1 uuid=$2 remark=$3
  local addr="$DOMAIN"
  local xhttp_host="${XHTTP_HOST:-$DOMAIN}"
  local ws_host="${WS_HOST:-$DOMAIN}"
  local sec="none"
  if [[ $INBOUND_TLS -eq 1 && $kind != "kcp" ]]; then
    sec="tls"
  fi
  case $kind in
    xhttp)
      local query
      query="type=xhttp&security=${sec}&path=$(encode_path "$XHTTP_PATH")&host=${xhttp_host}&mode=auto"
      [[ $sec == "tls" ]] && query="${query}&sni=${addr}&alpn=h2"
      printf 'vless://%s@%s:%s?%s#%s\n' "$uuid" "$addr" "$INBOUND_XHTTP_PORT" "$query" "$remark"
      ;;
    ws)
      local query
      query="type=ws&security=${sec}&path=$(encode_path "$WS_PATH")&host=${ws_host}"
      [[ $sec == "tls" ]] && query="${query}&sni=${addr}"
      printf 'vless://%s@%s:%s?%s#%s\n' "$uuid" "$addr" "$INBOUND_WS_PORT" "$query" "$remark"
      ;;
    kcp)
      printf 'vless://%s@%s:%s?type=kcp&security=none&headerType=none#%s\n' \
        "$uuid" "$addr" "$INBOUND_MKCP_PORT" "$remark"
      ;;
    *)
      return 1
      ;;
  esac
}

create_inbound() {
  local kind=$1 port=$2 stream=$3
  local remark uuid email tag payload resp proto="tcp"

  case $kind in
    xhttp) remark="VLESS-XHTTP-${port}" ;;
    ws) remark="VLESS-WS-${port}" ;;
    kcp)
      remark="VLESS-mKCP-${port}"
      proto="udp"
      ;;
    *)
      warn "Unknown inbound type '${kind}'."
      return 1
      ;;
  esac

  if [[ " ${CREATED_PORTS} " == *" ${port} "* ]]; then
    warn "Port ${port} is used twice in the inbound configuration; skipping ${kind}."
    return 1
  fi
  if inbound_port_exists "$port"; then
    say "An inbound on port ${port} already exists; skipping ${kind}."
    return 0
  fi
  if [[ $kind == "kcp" ]]; then
    if udp_port_in_use "$port"; then
      warn "UDP/${port} is already in use; skipping ${kind}."
      return 1
    fi
  elif port_in_use "$port"; then
    warn "TCP/${port} is already in use; skipping ${kind}."
    return 1
  fi

  CREATED_PORTS+=" ${port}"
  uuid=$(new_uuid)
  email="${CLIENT_NAME:-client}-${kind}"
  tag="in-${port}-${proto}"
  payload=$(build_vless_payload "$uuid" "$email" "$INBOUND_SUBID" "$remark" "$tag" "$port" "$stream")

  resp=$(api_post "$payload" "/panel/api/inbounds/add") || {
    warn "POST /panel/api/inbounds/add failed for ${kind}."
    return 1
  }
  if ! is_success "$resp"; then
    warn "The panel rejected the ${kind} inbound: ${resp}"
    return 1
  fi

  INBOUND_CREATED=$((INBOUND_CREATED + 1))
  INBOUND_LINKS+=("$(inbound_link "$kind" "$uuid" "$remark")")
  say "Created ${remark}."
  return 0
}

create_default_inbounds() {
  if [[ $SKIP_INBOUNDS -eq 1 ]]; then
    warn "Inbound creation skipped (--no-inbounds / SKIP_INBOUNDS=1)."
    return 0
  fi
  if [[ -z $PANEL_USER || -z $PANEL_PASS ]]; then
    warn "Panel credentials are unknown; skipping inbound creation."
    warn "Set XUI_USERNAME/XUI_PASSWORD and re-run, or create the inbounds in the panel UI."
    INBOUND_FAILED=1
    return 0
  fi
  if [[ $INBOUND_TLS -eq 1 ]] && ! cert_valid; then
    warn "INBOUND_TLS=1 but the certificate is not valid; creating the inbounds without TLS."
    INBOUND_TLS=0
  fi

  INBOUND_SUBID="${XUI_SUB_ID:-}"
  INBOUND_CREATED=0
  [[ -n $INBOUND_SUBID ]] || INBOUND_SUBID=$(rand_hex 8)
  CLIENT_NAME="${XUI_CLIENT_NAME:-pineapple-$(rand_hex 4)}"

  API_ROOT=$(api_root) || {
    warn "Panel API is not reachable at 127.0.0.1:${ACTUAL_PORT}."
    INBOUND_FAILED=1
    return 0
  }
  if ! api_login; then
    INBOUND_FAILED=1
    return 0
  fi
  INBOUND_LIST=$(fetch_inbounds) || {
    INBOUND_FAILED=1
    return 0
  }

  say "Creating the default VLESS inbounds (client: ${CLIENT_NAME}) ..."
  create_inbound xhttp "$INBOUND_XHTTP_PORT" "$(stream_xhttp)" || INBOUND_FAILED=1
  create_inbound ws "$INBOUND_WS_PORT" "$(stream_ws)" || INBOUND_FAILED=1
  create_inbound kcp "$INBOUND_MKCP_PORT" "$(stream_kcp)" || INBOUND_FAILED=1

  if ((INBOUND_CREATED > 0)); then
    say "Restarting Xray ..."
    api_post '{}' "/panel/api/server/restartXrayService" > /dev/null 2>&1 || true
    for _ in {1..10}; do
      if port_in_use "$INBOUND_XHTTP_PORT" && port_in_use "$INBOUND_WS_PORT" && udp_port_in_use "$INBOUND_MKCP_PORT"; then
        break
      fi
      sleep 1
    done
  fi

  if ((INBOUND_CREATED == 0)) && [[ -z ${XUI_SUB_ID:-} ]]; then
    warn "Inbounds already existed; the subscription link could not be reconstructed."
    SUB_URL=""
  else
    if ! load_subscription_settings; then
      warn "Could not read subscription settings; using the defaults (port ${SUB_PORT})."
    fi
    if ! build_subscription_url; then
      warn "Subscription is disabled or no subId is available; skipping the subscription link."
      SUB_URL=""
    else
      local code
      code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve "${SUB_HOST}:${SUB_PORT_ACTUAL}:127.0.0.1" \
        "${SUB_SCHEME}://${SUB_HOST}:${SUB_PORT_ACTUAL}${SUB_PATH}${INBOUND_SUBID}" 2> /dev/null || true)
      if [[ $code != "200" ]]; then
        warn "Subscription endpoint returned '${code:-no response}'; check TCP ${SUB_PORT_ACTUAL} and the panel Subscription settings."
      fi
    fi
  fi
  return 0
}

load_subscription_settings() {
  SUB_HOST="$DOMAIN"
  SUB_PATH="/sub/"
  SUB_SCHEME="https"
  SUB_ENABLED="true"
  SUB_PORT_ACTUAL="$SUB_PORT"
  SUB_DOMAIN=""
  SUB_CERT=""
  SUB_KEY=""

  local resp v
  resp=$(api_post '{}' "/panel/api/setting/all") || return 1
  is_success "$resp" || {
    warn "Panel settings request failed: ${resp}"
    return 1
  }

  v=$(printf '%s' "$resp" | sed -n 's/.*"subEnable"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p')
  if [[ -n $v ]]; then SUB_ENABLED="$v"; fi

  v=$(printf '%s' "$resp" | sed -n 's/.*"subPort"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
  if [[ -n $v ]]; then SUB_PORT_ACTUAL="$v"; fi

  v=$(printf '%s' "$resp" | sed -n 's/.*"subPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [[ -n $v ]]; then SUB_PATH="$v"; fi

  v=$(printf '%s' "$resp" | sed -n 's/.*"subDomain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  SUB_DOMAIN="$v"

  SUB_CERT=$(printf '%s' "$resp" | sed -n 's/.*"subCertFile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  SUB_KEY=$(printf '%s' "$resp" | sed -n 's/.*"subKeyFile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  SUB_HOST="${SUB_DOMAIN:-$DOMAIN}"
  if [[ -n $SUB_CERT && -n $SUB_KEY ]]; then
    SUB_SCHEME="https"
  else
    SUB_SCHEME="http"
  fi

  [[ $SUB_PATH == /* ]] || SUB_PATH="/${SUB_PATH}"
  [[ $SUB_PATH == */ ]] || SUB_PATH="${SUB_PATH}/"
  return 0
}

build_subscription_url() {
  [[ $SUB_ENABLED == "true" ]] || return 1
  [[ -n $INBOUND_SUBID ]] || return 1
  [[ -n $SUB_HOST ]] || return 1
  [[ -n $SUB_PORT_ACTUAL ]] || SUB_PORT_ACTUAL="$SUB_PORT"

  local hostport="$SUB_HOST"
  if ! { [[ $SUB_SCHEME == "https" && $SUB_PORT_ACTUAL -eq 443 ]] || [[ $SUB_SCHEME == "http" && $SUB_PORT_ACTUAL -eq 80 ]]; }; then
    hostport="${SUB_HOST}:${SUB_PORT_ACTUAL}"
  fi
  SUB_URL="${SUB_SCHEME}://${hostport}${SUB_PATH}${INBOUND_SUBID}"
  return 0
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
  if [[ $SUB_SCHEME == "http" ]]; then
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
    printf "XUI_PANEL_PORT='%s'\n" "$ACTUAL_PORT"
    printf "XUI_WEB_BASE_PATH='%s'\n" "$ACTUAL_PATH"
    printf "XUI_USERNAME='%s'\n" "$PANEL_USER"
    printf "XUI_PASSWORD='%s'\n" "$PANEL_PASS"
    printf "XUI_ACCESS_URL='%s'\n" "$url"
    printf "XUI_CERT_FILE='%s'\n" "$CERT_FILE"
    printf "XUI_KEY_FILE='%s'\n" "$KEY_FILE"
    printf "XUI_SUB_ID='%s'\n" "${INBOUND_SUBID:-${XUI_SUB_ID:-}}"
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
    printf ' Expires     : %s (acme.sh renews it on TCP/80)\n' "${expires:-unknown}"
  fi
  printf ' Info file   : %s\n' "$INFO_FILE"
  printf '%s\n' '--------------------------------------------------------------'
  if [[ $SKIP_INBOUNDS -eq 0 ]]; then
    printf ' Inbounds:\n'
    printf '   VLESS XHTTP : TCP %s  (path %s)\n' "$INBOUND_XHTTP_PORT" "$XHTTP_PATH"
    printf '   VLESS WS    : TCP %s  (path %s)\n' "$INBOUND_WS_PORT" "$WS_PATH"
    printf '   VLESS mKCP  : UDP %s\n' "$INBOUND_MKCP_PORT"
    if ((${#INBOUND_LINKS[@]} > 0)); then
      local link
      printf '\n Connection links:\n'
      for link in "${INBOUND_LINKS[@]}"; do
        printf '   %s\n' "$link"
      done
    fi
    if [[ $INBOUND_FAILED -eq 1 ]]; then
      printf '\n [!] Some inbounds could not be created; see the messages above.\n'
    fi
  else
    printf ' Inbounds    : skipped (--no-inbounds)\n'
  fi
  printf '\n'
  printf ' Next step: run "x-ui" for the management menu.\n'
  if [[ $SKIP_INBOUNDS -eq 0 ]]; then
    printf ' Open TCP %s (panel), TCP %s, TCP %s, TCP %s and UDP %s in your\n' \
      "$ACTUAL_PORT" "$INBOUND_XHTTP_PORT" "$INBOUND_WS_PORT" "${SUB_PORT_ACTUAL:-$SUB_PORT}" "$INBOUND_MKCP_PORT"
    printf ' provider firewall / security group.\n'
  else
    printf ' Open TCP %s (panel) in your provider firewall / security group.\n' "$ACTUAL_PORT"
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
  say "version : ${PANEL_VERSION}"
  say "domain  : ${DOMAIN}"

  ensure_prereqs
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
      warn "Use --force-install to reinstall version ${PANEL_VERSION}."
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

  # Create the inbounds first so their subId can be saved in the info file.
  create_default_inbounds

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
