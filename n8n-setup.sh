#!/usr/bin/env bash
# =============================================================================
#  n8n-setup.sh -- n8n in Docker behind nginx with a Let's Encrypt certificate
#
#  What it does
#    1. takes the domain (argument or prompt) and checks that it points here
#    2. installs Docker + the compose plugin (download.docker.com, falling back
#       to the distro packages when that repo is unreachable)
#    3. runs n8n with docker compose in /opt/n8n (SQLite by default, Postgres
#       with --postgres), bound to 127.0.0.1 only
#    4. installs nginx and proxies https://<domain>/ to n8n (websockets, long
#       timeouts, large uploads)
#    5. gets a Let's Encrypt certificate (HTTP-01, webroot) with auto-renewal
#    6. installs `n8nctl` (a symlink to this script) for status, logs, update,
#       backup and uninstall, then prints the login link
#
#  This file is independent from dns-setup.sh and 3xui-setup.sh: it owns its
#  own paths, nginx file, renew hook and log. It serves TCP 80 and 443 through
#  nginx. When dns-setup.sh owns 443 (nginx stream SNI relay), n8n listens on
#  127.0.0.1:10443 instead and the relay forwards its domain there; dns-setup.sh
#  switches it back and forth with `n8nctl nginx`.
#
#  Usage:
#    bash n8n-setup.sh n8n.example.com
#    bash n8n-setup.sh --postgres --open-firewall n8n.example.com
#    bash <(curl -Ls https://raw.githubusercontent.com/USER/REPO/main/n8n-setup.sh) n8n.example.com
#    n8nctl status
#    n8nctl update
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_VERSION="1.1.0"

# ---------------------------------------------------------------------------
# Paths (all overridable from the environment for testing)
# ---------------------------------------------------------------------------
N8N_DIR="${NS_DIR:-/opt/n8n}"
ENV_FILE="${N8N_DIR}/.env"
COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"
LOG_FILE="${NS_LOG_FILE:-/var/log/n8n-setup.log}"
BACKUP_DIR="${NS_BACKUP_DIR:-/root/n8n-backups}"
BACKUP_KEEP="${NS_BACKUP_KEEP:-10}"

NGINX_CONF="${NS_NGINX_CONF:-/etc/nginx/conf.d/n8n-setup.conf}"
ACME_ROOT="${NS_ACME_ROOT:-/var/www/n8n-setup}"
RENEW_HOOK="${NS_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/n8n-setup-reload.sh}"
TLS_DIR="${NS_TLS_DIR:-/etc/letsencrypt/live}"
DS_STREAM_CONF="/etc/nginx/stream.d/dns-setup-relay.conf"   # dns-setup.sh owns :443
SNI_ROUTES_DIR="${NS_SNI_ROUTES_DIR:-/etc/nginx/sni-routes.d}" # included by its SNI map
SNI_MAP="${SNI_ROUTES_DIR}/n8n-setup.map"

COMPOSE_PROJECT="n8n"
DEFAULT_IMAGE="docker.n8n.io/n8nio/n8n"
HUB_IMAGE="n8nio/n8n"
POSTGRES_IMAGE="postgres:16-alpine"

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
DOMAIN=""
EMAIL=""
IMAGE_TAG=""
IMAGE_REF=""
TIMEZONE=""
LOCAL_PORT=""
TLS_PORT=""
MAX_BODY=""
REGISTRY_MIRROR=""
OWNER_EMAIL=""
OWNER_PASS=""
DB_TYPE=""

SKIP_DNS=0
OPEN_FIREWALL=0
SWAP=1
STAGING=0
WANT_POSTGRES=0

ENCRYPTION_KEY=""
POSTGRES_PASSWORD=""
PUBLIC_IPV4=""
COMPOSE_BIN=()
NGINX_RESTART=0

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
n8n-setup.sh -- n8n in Docker behind nginx with a Let's Encrypt certificate.

Usage:
  sudo bash n8n-setup.sh [options] <domain>
  n8nctl <command> [args]

Install options:
  -d, --domain <name>       public domain, e.g. n8n.example.com (asked when omitted)
  -e, --email <address>     Let's Encrypt account email (default: none)
      --postgres            use Postgres instead of SQLite (recommended for heavy use)
      --tag <tag>           n8n image tag (default: latest)
      --image <ref>         n8n image without tag (default: docker.n8n.io/n8nio/n8n)
      --registry-mirror <url>
                            Docker Hub mirror, e.g. https://docker.arvancloud.ir
                            (switches the default image to n8nio/n8n)
      --timezone <tz>       GENERIC_TIMEZONE, e.g. Asia/Tehran (default: server zone)
      --port <n>            local port n8n listens on behind nginx (default: 5678)
      --tls-port <n>        loopback HTTPS port when dns-setup.sh owns :443
                            (default: 10443)
      --max-body <MB>       nginx upload limit in MB (default: 100)
      --owner-email <addr>  create the owner account now instead of in the browser
      --owner-pass <pass>   owner password (default: random; needs --owner-email)
      --skip-dns-check      do not verify that the domain points to this server
      --open-firewall       open 80 and 443 in ufw / firewalld
      --no-swap             do not add a 2 GB swap file on small servers
      --staging             Let's Encrypt staging CA (testing only)
  -h, --help                show this help

Commands (same as n8nctl):
  status              containers, health, nginx and certificate
  info                login link, owner account, paths
  logs [-f]           last 200 lines of the n8n log (-f to follow)
  restart             restart the containers
  update [<tag>]      back up, pull the image (optionally a new tag) and restart
  backup              archive data, .env and the database to /root/n8n-backups
  renew               force a certificate renewal and reload nginx
  nginx               re-render the nginx site (:443, or behind the dns-setup.sh
                      relay when it is installed); dns-setup.sh calls this
  uninstall [--yes] [--purge]
                      remove containers, nginx config and n8nctl
                      (--purge also deletes /opt/n8n with all workflows)

Keep N8N_ENCRYPTION_KEY from /opt/n8n/.env safe: without it the saved
credentials of a restored backup cannot be decrypted.
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

OS_ID=""
OS_CODENAME=""

load_os() {
  local f pretty id like codename ubuntu_codename
  for f in /etc/os-release /usr/lib/os-release; do
    [[ -r $f ]] || continue
    # shellcheck disable=SC1090
    pretty=$(. "$f" && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
    # shellcheck disable=SC1090
    id=$(. "$f" && printf '%s' "${ID:-}")
    # shellcheck disable=SC1090
    like=$(. "$f" && printf '%s' "${ID_LIKE:-}")
    # shellcheck disable=SC1090
    codename=$(. "$f" && printf '%s' "${VERSION_CODENAME:-}")
    # shellcheck disable=SC1090
    ubuntu_codename=$(. "$f" && printf '%s' "${UBUNTU_CODENAME:-}")
    if [[ $id == ubuntu || $id == debian ]]; then
      OS_ID=$id
      OS_CODENAME=$codename
    elif [[ $like == *ubuntu* && -n $ubuntu_codename ]]; then
      OS_ID=ubuntu
      OS_CODENAME=$ubuntu_codename
    elif [[ $like == *debian* ]]; then
      OS_ID=debian
      OS_CODENAME=$codename
    fi
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

is_email() {
  [[ $1 =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]
}

is_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535))
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

port_in_use() {
  local p=$1
  ss -ltn 2> /dev/null | awk -v p=":${p}" '$4 ~ p"$" {found=1} END {exit !found}'
}

port_holder() {
  local p=$1
  ss -ltnp 2> /dev/null | awk -v p=":${p}$" '$4 ~ p && !found {print; found=1}'
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

apt_install() {
  command -v apt-get > /dev/null 2>&1 || die "apt-get is required to install: $*"
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$@"
}

apt_update() {
  apt-get -o DPkg::Lock::Timeout=180 update -qq
}

apt_has() {
  apt-cache show "$1" > /dev/null 2>&1
}

detect_timezone() {
  local tz=""
  if command -v timedatectl > /dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value 2> /dev/null) || tz=""
  fi
  if [[ -z $tz && -r /etc/timezone ]]; then
    tz=$(tr -d '[:space:]' < /etc/timezone)
  fi
  if [[ -z $tz && -L /etc/localtime ]]; then
    tz=$(readlink -f /etc/localtime | sed -n 's|.*/zoneinfo/||p')
  fi
  printf '%s\n' "${tz:-UTC}"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
ensure_base_packages() {
  local missing=() p
  for p in curl openssl python3; do
    command -v "$p" > /dev/null 2>&1 || missing+=("$p")
  done
  [[ -d /etc/ssl/certs ]] || missing+=(ca-certificates)
  command -v ss > /dev/null 2>&1 || missing+=(iproute2)
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  say "Installing packages: ${missing[*]}"
  apt_update || die "apt-get update failed."
  apt_install "${missing[@]}" || die "Could not install: ${missing[*]}"
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

relay_active() {
  [[ -f $DS_STREAM_CONF ]]
}

# Every setup on the server needs its own subdomain: one certificate lineage
# and one nginx server per name.
precheck_domain_free() {
  local entry f key owner d
  for entry in "/etc/dns-setup/state.env|DS_DOMAIN|dns-setup.sh" "/root/3xui-info.env|XUI_DOMAIN|3xui-setup.sh"; do
    IFS='|' read -r f key owner <<< "$entry"
    [[ -r $f ]] || continue
    d=$(sed -n -E "s/^${key}='?([^']*)'?$/\1/p" "$f" | sed -n '1p')
    if [[ $d == "$DOMAIN" ]]; then
      die "${DOMAIN} is already used by ${owner}. Give n8n its own subdomain (e.g. n8n.example.com)."
    fi
  done
}

precheck_ports() {
  local p holder
  if relay_active; then
    if ! grep -qF "$SNI_ROUTES_DIR" "$DS_STREAM_CONF"; then
      die "The dns-setup.sh relay on this server predates n8n support. Re-run the current dns-setup.sh first, then this script."
    fi
    say "dns-setup.sh owns TCP/443; n8n goes behind its SNI relay (127.0.0.1:${TLS_PORT})."
    if port_in_use "$TLS_PORT"; then
      holder=$(port_holder "$TLS_PORT") || true
      if [[ $holder != *'"nginx"'* ]]; then
        die "TCP/${TLS_PORT} is in use: ${holder:-unknown}. Pick another one with --tls-port."
      fi
    fi
  fi
  for p in 80 443; do
    port_in_use "$p" || continue
    holder=$(port_holder "$p") || true
    if [[ $holder == *'"nginx"'* ]]; then
      continue
    fi
    die "TCP/${p} is in use by another program: ${holder:-unknown}. Free it (Apache? Caddy? x-ui?) and re-run."
  done

  if port_in_use "$LOCAL_PORT"; then
    holder=$(port_holder "$LOCAL_PORT") || true
    if [[ $holder == *docker-proxy* ]] && container_exists n8n; then
      say "TCP/${LOCAL_PORT} is already served by the n8n container; continuing (re-run)."
    else
      die "TCP/${LOCAL_PORT} is in use: ${holder:-unknown}. Pick another one with --port."
    fi
  fi
}

precheck_disk() {
  local avail
  avail=$(df -Pk / 2> /dev/null | awk 'NR == 2 {print $4}') || true
  if [[ $avail =~ ^[0-9]+$ ]] && ((avail < 3145728)); then
    die "At least 3 GB of free disk space is required for Docker and n8n (found $((avail / 1024)) MB)."
  fi
}

# n8n needs ~1 GB during its first start (database migrations); small VPSes
# get hit by the OOM killer without some swap.
ensure_swap() {
  [[ $SWAP -eq 1 ]] || return 0
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2> /dev/null) || return 0
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2> /dev/null) || return 0
  [[ $mem_kb =~ ^[0-9]+$ && $swap_kb =~ ^[0-9]+$ ]] || return 0
  if ((mem_kb >= 2000000 || swap_kb > 0)); then
    return 0
  fi
  if [[ -e /swapfile ]]; then
    warn "/swapfile exists but is not active; leaving it alone."
    return 0
  fi
  say "Only $((mem_kb / 1024)) MB RAM and no swap: adding a 2 GB swap file ..."
  if ! { fallocate -l 2G /swapfile 2> /dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; }; then
    rm -f /swapfile
    warn "Could not create /swapfile; continuing without swap."
    return 0
  fi
  chmod 600 /swapfile
  if ! { mkswap /swapfile > /dev/null && swapon /swapfile; }; then
    rm -f /swapfile
    warn "This server does not allow swap (container VPS?); continuing without it."
    return 0
  fi
  grep -qs '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  say "Swap enabled (/swapfile, 2 GB)."
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
detect_compose() {
  if docker compose version > /dev/null 2>&1; then
    COMPOSE_BIN=(docker compose)
  elif command -v docker-compose > /dev/null 2>&1; then
    COMPOSE_BIN=(docker-compose)
  else
    return 1
  fi
}

compose() {
  [[ ${#COMPOSE_BIN[@]} -gt 0 ]] || detect_compose || die "docker compose is not installed."
  (cd "$N8N_DIR" && "${COMPOSE_BIN[@]}" -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@")
}

container_exists() {
  command -v docker > /dev/null 2>&1 || return 1
  docker inspect "$1" > /dev/null 2>&1
}

install_docker_official() {
  [[ $OS_ID == ubuntu || $OS_ID == debian ]] || return 1
  [[ -n $OS_CODENAME ]] || return 1
  local arch key=/etc/apt/keyrings/docker.asc list=/etc/apt/sources.list.d/docker.list
  arch=$(dpkg --print-architecture)
  say "Adding the Docker apt repository (download.docker.com, ${OS_ID} ${OS_CODENAME}) ..."
  install -m 0755 -d /etc/apt/keyrings
  if ! curl -fsSL --max-time 30 "https://download.docker.com/linux/${OS_ID}/gpg" -o "$key"; then
    rm -f "$key"
    return 1
  fi
  chmod a+r "$key"
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$key" "$OS_ID" "$OS_CODENAME" > "$list"
  if apt_update && apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    return 0
  fi
  rm -f "$list" "$key"
  apt_update || true
  return 1
}

install_docker_distro() {
  say "Installing Docker from the distribution repository (docker.io) ..."
  apt_update || die "apt-get update failed."
  apt_install docker.io || die "Could not install docker.io."
  local pkg
  for pkg in docker-compose-v2 docker-compose-plugin docker-compose; do
    if apt_has "$pkg" && apt_install "$pkg"; then
      return 0
    fi
  done
  die "Docker is installed but no compose package is available (docker-compose-v2 / docker-compose)."
}

install_docker() {
  if command -v docker > /dev/null 2>&1 && detect_compose; then
    say "Docker is already installed: $(docker --version 2> /dev/null || printf '?')"
  else
    if command -v docker > /dev/null 2>&1; then
      say "Docker is installed but compose is missing; adding it ..."
      apt_update || true
      local pkg
      for pkg in docker-compose-plugin docker-compose-v2 docker-compose; do
        if apt_has "$pkg" && apt_install "$pkg"; then
          break
        fi
      done
    elif ! install_docker_official; then
      warn "download.docker.com is unreachable or failed; falling back to the distro packages."
      install_docker_distro
    fi
    detect_compose || die "docker compose is still missing after the installation."
    say "Installed: $(docker --version 2> /dev/null || printf 'docker')"
  fi
  systemctl enable --now docker > /dev/null 2>&1 || true
  svc_active docker || systemctl start docker || die "The Docker service does not start (journalctl -u docker)."
  configure_registry_mirror
}

configure_registry_mirror() {
  [[ -n $REGISTRY_MIRROR ]] || return 0
  local f=/etc/docker/daemon.json
  install -d -m 755 /etc/docker
  say "Adding Docker Hub mirror ${REGISTRY_MIRROR} to ${f} ..."
  python3 - "$f" "$REGISTRY_MIRROR" << 'PY' || die "Could not update ${f} (is it valid JSON?)."
import json, os, sys
path, mirror = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as fh:
        data = json.load(fh)
mirrors = [m for m in data.get("registry-mirrors", []) if m != mirror]
data["registry-mirrors"] = [mirror] + mirrors
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  systemctl restart docker || die "Docker did not restart with the new daemon.json."
}

# ---------------------------------------------------------------------------
# n8n
# ---------------------------------------------------------------------------
# Previous install: keep the encryption key, database type and passwords.
load_env() {
  [[ -r $ENV_FILE ]] || return 1
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  return 0
}

prepare_settings() {
  local prev_db="" cfg="${N8N_DIR}/data/config"
  if load_env; then
    say "Existing install found in ${N8N_DIR}; keeping its key and database."
    ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-}"
    POSTGRES_PASSWORD="${N8N_POSTGRES_PASSWORD:-}"
    prev_db="${N8N_SETUP_DB:-sqlite}"
    [[ -n $IMAGE_TAG ]] || IMAGE_TAG="${N8N_SETUP_TAG:-}"
    [[ -n $IMAGE_REF ]] || IMAGE_REF="${N8N_SETUP_IMAGE:-}"
    [[ -n $TIMEZONE ]] || TIMEZONE="${N8N_TZ:-}"
    [[ -n $LOCAL_PORT ]] || LOCAL_PORT="${N8N_LOCAL_PORT:-}"
    [[ -n $TLS_PORT ]] || TLS_PORT="${N8N_SETUP_TLS_PORT:-}"
    [[ -n $MAX_BODY ]] || MAX_BODY="${N8N_SETUP_MAX_BODY:-}"
    [[ -n $EMAIL ]] || EMAIL="${N8N_SETUP_EMAIL:-}"
    [[ -n $OWNER_EMAIL ]] || OWNER_EMAIL="${N8N_SETUP_OWNER_EMAIL:-}"
    [[ -n $OWNER_PASS ]] || OWNER_PASS="${N8N_SETUP_OWNER_PASS:-}"
  fi

  if [[ $WANT_POSTGRES -eq 1 ]]; then
    if [[ $prev_db == sqlite && -s ${N8N_DIR}/data/database.sqlite ]]; then
      die "This install already keeps its workflows in SQLite; switching to --postgres would start empty.
     Export the workflows (n8n export:workflow) first, or re-run without --postgres."
    fi
    DB_TYPE=postgres
  else
    DB_TYPE="${prev_db:-sqlite}"
  fi

  # An n8n data dir from an earlier manual install already holds a key.
  if [[ -z $ENCRYPTION_KEY && -r $cfg ]]; then
    ENCRYPTION_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("encryptionKey",""))' "$cfg" 2> /dev/null) || ENCRYPTION_KEY=""
    if [[ -n $ENCRYPTION_KEY ]]; then
      say "Reusing the encryption key from ${cfg}."
    fi
  fi
  [[ -n $ENCRYPTION_KEY ]] || ENCRYPTION_KEY=$(rand_hex 32)
  if [[ $DB_TYPE == postgres && -z $POSTGRES_PASSWORD ]]; then
    POSTGRES_PASSWORD=$(rand_hex 16)
  fi

  [[ -n $IMAGE_TAG ]] || IMAGE_TAG=latest
  if [[ -z $IMAGE_REF ]]; then
    if [[ -n $REGISTRY_MIRROR ]]; then
      IMAGE_REF=$HUB_IMAGE
    else
      IMAGE_REF=$DEFAULT_IMAGE
    fi
  fi
  [[ -n $TIMEZONE ]] || TIMEZONE=$(detect_timezone)
  [[ -n $LOCAL_PORT ]] || LOCAL_PORT=5678
  [[ -n $TLS_PORT ]] || TLS_PORT=10443
  [[ -n $MAX_BODY ]] || MAX_BODY=100

  [[ $IMAGE_TAG =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid --tag '${IMAGE_TAG}'."
  [[ $IMAGE_REF =~ ^[a-z0-9./:_-]+$ ]] || die "Invalid --image '${IMAGE_REF}' (leave the tag out, use --tag)."
  [[ $TIMEZONE =~ ^[A-Za-z0-9_+/-]+$ ]] || die "Invalid --timezone '${TIMEZONE}'."
  is_port "$LOCAL_PORT" || die "Invalid --port '${LOCAL_PORT}'."
  ((LOCAL_PORT != 80 && LOCAL_PORT != 443)) || die "--port must not be 80 or 443 (nginx uses them)."
  is_port "$TLS_PORT" || die "Invalid --tls-port '${TLS_PORT}'."
  ((TLS_PORT != 80 && TLS_PORT != 443 && TLS_PORT != LOCAL_PORT)) \
    || die "--tls-port must differ from 80, 443 and --port."
  [[ $MAX_BODY =~ ^[0-9]+$ ]] && ((MAX_BODY > 0)) || die "Invalid --max-body '${MAX_BODY}'."
  if [[ -n $OWNER_EMAIL ]]; then
    is_email "$OWNER_EMAIL" || die "Invalid --owner-email '${OWNER_EMAIL}'."
    [[ -n $OWNER_PASS ]] || OWNER_PASS="N8n$(rand_hex 8)x9"
    if [[ ! $OWNER_PASS =~ ^[A-Za-z0-9@#%+=:,._-]{8,64}$ || ! $OWNER_PASS =~ [0-9] || ! $OWNER_PASS =~ [A-Z] ]]; then
      die "--owner-pass needs 8-64 characters (letters, digits, @#%+=:,._-) with a digit and an uppercase letter."
    fi
  elif [[ -n $OWNER_PASS ]]; then
    die "--owner-pass needs --owner-email."
  fi
}

write_env() {
  install -d -m 700 "$N8N_DIR"
  local tmp
  tmp=$(mktemp)
  {
    printf '# n8n-setup %s, generated %s\n' "$SCRIPT_VERSION" "$(date -Is)"
    printf '# Read by docker compose. Back up N8N_ENCRYPTION_KEY: saved credentials\n'
    printf '# cannot be decrypted without it.\n'
    printf 'N8N_DOMAIN=%s\n' "$DOMAIN"
    printf 'N8N_IMAGE=%s\n' "$IMAGE_REF"
    printf 'N8N_TAG=%s\n' "$IMAGE_TAG"
    printf 'N8N_TZ=%s\n' "$TIMEZONE"
    printf 'N8N_LOCAL_PORT=%s\n' "$LOCAL_PORT"
    printf 'N8N_ENCRYPTION_KEY=%s\n' "$ENCRYPTION_KEY"
    if [[ $DB_TYPE == postgres ]]; then
      printf 'N8N_POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
    fi
    printf '\n# Used by n8n-setup.sh / n8nctl only\n'
    printf 'N8N_SETUP_DB=%s\n' "$DB_TYPE"
    printf 'N8N_SETUP_TAG=%s\n' "$IMAGE_TAG"
    printf 'N8N_SETUP_IMAGE=%s\n' "$IMAGE_REF"
    printf 'N8N_SETUP_MAX_BODY=%s\n' "$MAX_BODY"
    printf 'N8N_SETUP_TLS_PORT=%s\n' "$TLS_PORT"
    printf 'N8N_SETUP_EMAIL=%s\n' "$EMAIL"
    printf 'N8N_SETUP_STAGING=%s\n' "$STAGING"
    printf 'N8N_SETUP_OWNER_EMAIL=%s\n' "$OWNER_EMAIL"
    printf 'N8N_SETUP_OWNER_PASS=%s\n' "$OWNER_PASS"
  } > "$tmp"
  install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

render_compose() {
  {
    printf '# Managed by n8n-setup.sh -- change %s, then: n8nctl restart\n' "$ENV_FILE"
    cat << 'EOF'
services:
  n8n:
    image: ${N8N_IMAGE}:${N8N_TAG}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:${N8N_LOCAL_PORT}:5678"
    environment:
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: https://${N8N_DOMAIN}/
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_PROXY_HOPS: "1"
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: ${N8N_TZ}
      TZ: ${N8N_TZ}
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_DIAGNOSTICS_ENABLED: "false"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "336"
EOF
    if [[ $DB_TYPE == postgres ]]; then
      cat << 'EOF'
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${N8N_POSTGRES_PASSWORD}
EOF
    fi
    cat << 'EOF'
    volumes:
      - ./data:/home/node/.n8n
      - ./files:/files
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    if [[ $DB_TYPE == postgres ]]; then
      cat << 'EOF'
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
EOF
      printf '    image: %s\n' "$POSTGRES_IMAGE"
      cat << 'EOF'
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${N8N_POSTGRES_PASSWORD}
      POSTGRES_DB: n8n
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 5s
      timeout: 5s
      retries: 20
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    fi
  } > "$COMPOSE_FILE"
  chmod 644 "$COMPOSE_FILE"
}

prepare_dirs() {
  install -d -m 755 "$N8N_DIR"
  install -d -m 700 "${N8N_DIR}/data" "${N8N_DIR}/files"
  # the image runs as user "node" (uid 1000)
  chown -R 1000:1000 "${N8N_DIR}/data" "${N8N_DIR}/files"
}

n8n_healthy() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${LOCAL_PORT}/healthz" 2> /dev/null) || true
  [[ $code == 200 ]]
}

wait_n8n() {
  local tries=${1:-120} i
  for ((i = 0; i < tries; i++)); do
    n8n_healthy && return 0
    sleep 2
  done
  return 1
}

start_n8n() {
  say "Pulling ${IMAGE_REF}:${IMAGE_TAG} ..."
  if ! compose pull; then
    warn "Could not pull the images. Docker Hub and docker.n8n.io block some regions (Iran included)."
    die "Re-run with a mirror, e.g. --registry-mirror https://docker.arvancloud.ir"
  fi
  say "Starting n8n ..."
  compose up -d --remove-orphans || die "docker compose up failed."
  say "Waiting for n8n to answer on 127.0.0.1:${LOCAL_PORT} (first start runs migrations) ..."
  if ! wait_n8n 150; then
    compose logs --tail 60 n8n >&2 || true
    die "n8n did not become healthy within 5 minutes (log above)."
  fi
  say "n8n is up: $(n8n_version)"
}

n8n_version() {
  docker exec n8n n8n --version 2> /dev/null | tail -n 1 || printf '?'
}

# Creates the owner account so nobody else can claim a fresh instance first.
setup_owner() {
  [[ -n $OWNER_EMAIL ]] || return 0
  local body code out
  body=$(printf '{"email":"%s","firstName":"Admin","lastName":"Owner","password":"%s"}' \
    "$(json_escape "$OWNER_EMAIL")" "$(json_escape "$OWNER_PASS")")
  out=$(mktemp)
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 20 \
    -H 'Content-Type: application/json' -d "$body" \
    "http://127.0.0.1:${LOCAL_PORT}/rest/owner/setup" 2> /dev/null) || code=000
  if [[ $code == 200 ]]; then
    say "Owner account created: ${OWNER_EMAIL}"
  elif grep -qi 'already' "$out" 2> /dev/null; then
    say "The owner account already exists; keeping it."
  else
    warn "Could not create the owner account (HTTP ${code}): $(head -c 200 "$out" 2> /dev/null)"
    warn "Create it in the browser right after this script finishes."
    OWNER_EMAIL=""
    OWNER_PASS=""
    write_env
  fi
  rm -f "$out"
}

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
ensure_nginx() {
  local missing=()
  command -v nginx > /dev/null 2>&1 || missing+=(nginx)
  command -v certbot > /dev/null 2>&1 || missing+=(certbot)
  if ((${#missing[@]} > 0)); then
    say "Installing: ${missing[*]}"
    apt_update || die "apt-get update failed."
    apt_install "${missing[@]}" || die "Could not install: ${missing[*]}"
  fi
  [[ -d /etc/nginx/conf.d ]] || die "/etc/nginx/conf.d is missing; unexpected nginx layout."
  if ! grep -rqs 'conf\.d/\*\.conf' /etc/nginx/nginx.conf; then
    die "/etc/nginx/nginx.conf does not include conf.d/*.conf; add it and re-run."
  fi
  mkdir -p "${ACME_ROOT}/.well-known/acme-challenge"
  chmod 755 "$ACME_ROOT" "${ACME_ROOT}/.well-known" "${ACME_ROOT}/.well-known/acme-challenge"
}

nginx_version_ge() { # x.y.z
  local v
  v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
  [[ -n $v ]] || return 1
  [[ $(printf '%s\n%s\n' "$1" "$v" | sort -V | head -n 1) == "$1" ]]
}

listen_mode() { # what NGINX_CONF serves TLS on: public | loopback | none
  if grep -Eqs '^[[:space:]]*listen[[:space:]]+443[[:space:];]' "$NGINX_CONF"; then
    printf 'public\n'
  elif grep -Eqs '^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:[0-9]+[[:space:]]+ssl' "$NGINX_CONF"; then
    printf 'loopback\n'
  else
    printf 'none\n'
  fi
}

# dns-setup.sh owns :443 with an nginx stream SNI relay; its map includes the
# files in SNI_ROUTES_DIR, so this one sends our domain to the loopback
# listener. n8n then sees 127.0.0.1 as the client address.
sync_sni_route() { # http | https
  if [[ $1 == https ]] && relay_active; then
    install -d -m 755 "$SNI_ROUTES_DIR"
    {
      printf '# Managed by n8n-setup.sh -- SNI route for the dns-setup.sh relay\n'
      printf '"%s" 127.0.0.1:%s;\n' "$DOMAIN" "$TLS_PORT"
    } > "$SNI_MAP"
  else
    rm -f "$SNI_MAP"
  fi
}

render_nginx() { # http | https
  local mode=$1 v6=0 h2_listen="" h2_line="" before after
  ipv6_enabled && v6=1
  before=$(listen_mode)
  if nginx_version_ge 1.25.1; then
    h2_line='    http2 on;'
  else
    h2_listen=' http2'
  fi
  install -d -m 755 "$(dirname "$NGINX_CONF")"
  {
    printf '# Managed by n8n-setup.sh -- re-run the script instead of editing by hand\n'
    if [[ $mode == https ]]; then
      printf 'map $http_upgrade $n8n_setup_connection {\n'
      printf '    default upgrade;\n'
      printf "    ''      close;\n"
      printf '}\n\n'
    fi
    printf 'server {\n'
    printf '    listen 80;\n'
    ((v6)) && printf '    listen [::]:80;\n'
    printf '    server_name %s;\n\n' "$DOMAIN"
    printf '    location ^~ /.well-known/acme-challenge/ {\n'
    printf '        root %s;\n' "${ACME_ROOT%/}"
    printf '        default_type "text/plain";\n'
    printf '    }\n'
    printf '    location / {\n'
    printf '        return 301 https://$host$request_uri;\n'
    printf '    }\n'
    printf '}\n'
    if [[ $mode == https ]]; then
      printf '\nserver {\n'
      if relay_active; then
        printf '    listen 127.0.0.1:%s ssl%s;\n' "$TLS_PORT" "$h2_listen"
      else
        printf '    listen 443 ssl%s;\n' "$h2_listen"
        ((v6)) && printf '    listen [::]:443 ssl%s;\n' "$h2_listen"
      fi
      [[ -n $h2_line ]] && printf '%s\n' "$h2_line"
      printf '    server_name %s;\n\n' "$DOMAIN"
      printf '    ssl_certificate     %s;\n' "$CERT_FULLCHAIN"
      printf '    ssl_certificate_key %s;\n' "$CERT_PRIVKEY"
      printf '    ssl_protocols TLSv1.2 TLSv1.3;\n'
      printf '    ssl_session_cache shared:n8n_setup_ssl:10m;\n'
      printf '    ssl_session_timeout 1d;\n'
      printf '    add_header Strict-Transport-Security "max-age=31536000" always;\n\n'
      printf '    client_max_body_size %sm;\n\n' "$MAX_BODY"
      printf '    location / {\n'
      printf '        proxy_pass http://127.0.0.1:%s;\n' "$LOCAL_PORT"
      printf '        proxy_http_version 1.1;\n'
      printf '        proxy_set_header Upgrade $http_upgrade;\n'
      printf '        proxy_set_header Connection $n8n_setup_connection;\n'
      printf '        proxy_set_header Host $host;\n'
      printf '        proxy_set_header X-Real-IP $remote_addr;\n'
      printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
      printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
      printf '        proxy_set_header X-Forwarded-Host $host;\n'
      printf '        proxy_buffering off;\n'
      printf '        proxy_cache off;\n'
      printf '        proxy_read_timeout 3600s;\n'
      printf '        proxy_send_timeout 3600s;\n'
      printf '    }\n'
      printf '}\n'
    fi
  } > "$NGINX_CONF"
  sync_sni_route "$mode"

  # :443 moves between this http server and the stream relay: a reload would
  # have to hand the socket from one module to the other, a restart is safer
  after=$(listen_mode)
  if [[ $before != none && $after != none && $before != "$after" ]]; then
    NGINX_RESTART=1
  fi
}

apply_nginx() {
  local out
  if ! out=$(nginx -t 2>&1); then
    printf '%s\n' "$out" >&2
    die "nginx configuration test failed (see the output above)."
  fi
  systemctl enable nginx > /dev/null 2>&1 || true
  if svc_active nginx && ((NGINX_RESTART == 0)); then
    systemctl reload nginx || die "Could not reload nginx."
  else
    systemctl restart nginx || die "Could not start nginx."
  fi
  NGINX_RESTART=0
}

# ---------------------------------------------------------------------------
# Certificates
# ---------------------------------------------------------------------------
CERT_FULLCHAIN=""
CERT_PRIVKEY=""

set_cert_paths() {
  CERT_FULLCHAIN="${TLS_DIR}/${DOMAIN}/fullchain.pem"
  CERT_PRIVKEY="${TLS_DIR}/${DOMAIN}/privkey.pem"
}

cert_valid() {
  [[ -s $CERT_FULLCHAIN && -s $CERT_PRIVKEY ]] || return 1
  openssl x509 -in "$CERT_FULLCHAIN" -noout -checkend 86400 > /dev/null 2>&1 || return 1
  local san
  san=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -ext subjectAltName 2> /dev/null) || return 1
  [[ $san == *"DNS:${DOMAIN}"* ]]
}

obtain_certificate() {
  if cert_valid; then
    say "A valid certificate for ${DOMAIN} is already present."
    return 0
  fi
  local args=(
    certonly --webroot -w "$ACME_ROOT"
    -d "$DOMAIN" --cert-name "$DOMAIN"
    --agree-tos --no-eff-email
    --non-interactive --keep-until-expiring
  )
  if [[ -n $EMAIL ]]; then
    args+=(--email "$EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  [[ $STAGING -eq 1 ]] && args+=(--staging)

  say "Requesting a Let's Encrypt certificate for ${DOMAIN} (HTTP-01, webroot) ..."
  if ! certbot "${args[@]}"; then
    warn "certbot failed. Common causes: DNS not pointing here, TCP/80 closed in the provider firewall, Cloudflare proxy on."
    return 1
  fi
  cert_valid || die "certbot reported success but ${CERT_FULLCHAIN} is not usable."
  say "Certificate issued."
}

install_renew_hook() {
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  cat > "$RENEW_HOOK" << 'EOF'
#!/bin/sh
# Added by n8n-setup.sh: reload nginx after a certificate renewal.
systemctl reload nginx 2>/dev/null || true
EOF
  chmod 755 "$RENEW_HOOK"
  systemctl enable --now certbot.timer > /dev/null 2>&1 || true
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
    for p in 80/tcp 443/tcp; do
      ufw allow "$p" > /dev/null 2>&1 || true
    done
    say "Opened 80 and 443 in ufw."
  fi
  if firewalld_is_active; then
    for p in 80/tcp 443/tcp; do
      firewall-cmd --permanent --add-port="$p" > /dev/null 2>&1 || true
    done
    firewall-cmd --reload > /dev/null 2>&1 || true
    say "Opened 80 and 443 in firewalld."
  fi
}

warn_closed_firewall() {
  [[ $OPEN_FIREWALL -eq 1 ]] && return 0
  if ufw_is_active && ! ufw status 2> /dev/null | grep -qE '^(80|443|80/tcp|443/tcp|80,443/tcp|Nginx Full|Nginx HTTPS)[[:space:]]+ALLOW'; then
    warn "ufw is active and may block 80/443; re-run with --open-firewall or run: ufw allow 80,443/tcp"
  fi
}

# ---------------------------------------------------------------------------
# Checks and output
# ---------------------------------------------------------------------------
verify_https() {
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${DOMAIN}:443:127.0.0.1")
  [[ $STAGING -eq 1 ]] && args+=(-k)
  local code
  code=$(curl "${args[@]}" "https://${DOMAIN}/healthz" 2> /dev/null) || code=000
  [[ $code == 200 ]]
}

install_self() {
  local src target=/usr/local/sbin/n8n-setup tmp
  src=$(readlink -f "$0" 2> /dev/null || printf '%s' "$0")
  if [[ -f $src && $src != /proc/* && $src != /dev/* ]]; then
    [[ $src == "$target" ]] || install -m 755 "$src" "$target"
  else
    # bash <(curl ...): the pipe is drained, so rebuild the script from memory
    tmp=$(mktemp)
    {
      printf '#!/usr/bin/env bash
'
      printf '# n8n-setup.sh %s, rebuilt from a piped run (this file is n8nctl)
' "$SCRIPT_VERSION"
      printf 'set -Eeuo pipefail
'
      printf 'export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
'
      printf '%s
' "$PRISTINE_VARS"
      declare -f
      printf 'main "$@"
'
    } > "$tmp"
    if ! bash -n "$tmp" 2> /dev/null; then
      rm -f "$tmp"
      warn "Could not rebuild the script from a piped run; skipping the n8nctl installation."
      return 0
    fi
    install -m 755 "$tmp" "$target"
    rm -f "$tmp"
  fi
  ln -sf "$target" /usr/local/bin/n8nctl
  say "Installed /usr/local/bin/n8nctl."
}

print_summary() {
  local expires
  expires=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires="unknown"
  printf '\n'
  printf '==============================================================\n'
  printf ' n8n was installed successfully\n'
  printf '==============================================================\n'
  printf ' Login link  : https://%s/\n' "$DOMAIN"
  if [[ -n $OWNER_EMAIL ]]; then
    printf ' Owner email : %s\n' "$OWNER_EMAIL"
    printf ' Password    : %s\n' "$OWNER_PASS"
  else
    printf ' First visit : create the owner account right away -- until\n'
    printf '               then, whoever opens the link first can claim it.\n'
  fi
  printf ' Webhooks    : https://%s/webhook/...\n' "$DOMAIN"
  printf ' Version     : %s (%s:%s)\n' "$(n8n_version)" "$IMAGE_REF" "$IMAGE_TAG"
  printf ' Database    : %s\n' "$DB_TYPE"
  printf ' Data        : %s/data (files for nodes: %s/files -> /files)\n' "$N8N_DIR" "$N8N_DIR"
  printf ' Settings    : %s\n' "$ENV_FILE"
  printf ' Certificate : %s (expires %s, renews automatically)\n' "$CERT_FULLCHAIN" "${expires:-unknown}"
  if [[ $(listen_mode) == loopback ]]; then
    printf ' HTTPS       : 127.0.0.1:%s, reached through the dns-setup.sh relay on :443\n' "$TLS_PORT"
  fi
  printf '%s\n' '--------------------------------------------------------------'
  printf ' Back up N8N_ENCRYPTION_KEY from %s: saved\n' "$ENV_FILE"
  printf ' credentials cannot be decrypted without it.\n\n'
  printf ' n8nctl status | logs | restart | update | backup | uninstall\n'
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
      --postgres)
        WANT_POSTGRES=1
        shift
        ;;
      --tag)
        (($# >= 2)) || die "Option $1 needs a value."
        IMAGE_TAG="$2"
        shift 2
        ;;
      --image)
        (($# >= 2)) || die "Option $1 needs a value."
        IMAGE_REF="$2"
        shift 2
        ;;
      --registry-mirror)
        (($# >= 2)) || die "Option $1 needs a value."
        REGISTRY_MIRROR="${2%/}"
        shift 2
        ;;
      --timezone)
        (($# >= 2)) || die "Option $1 needs a value."
        TIMEZONE="$2"
        shift 2
        ;;
      --port)
        (($# >= 2)) || die "Option $1 needs a value."
        LOCAL_PORT="$2"
        shift 2
        ;;
      --tls-port)
        (($# >= 2)) || die "Option $1 needs a value."
        TLS_PORT="$2"
        shift 2
        ;;
      --max-body)
        (($# >= 2)) || die "Option $1 needs a value."
        MAX_BODY="$2"
        shift 2
        ;;
      --owner-email)
        (($# >= 2)) || die "Option $1 needs a value."
        OWNER_EMAIL="$2"
        shift 2
        ;;
      --owner-pass)
        (($# >= 2)) || die "Option $1 needs a value."
        OWNER_PASS="$2"
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
      --no-swap)
        SWAP=0
        shift
        ;;
      --staging)
        STAGING=1
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
  if [[ -n $REGISTRY_MIRROR && ! $REGISTRY_MIRROR =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
    die "Invalid --registry-mirror '${REGISTRY_MIRROR}' (expected https://host[:port])."
  fi
  if [[ -n $EMAIL ]] && ! is_email "$EMAIL"; then
    die "Invalid --email '${EMAIL}'."
  fi
}

resolve_domain() {
  if [[ -z $DOMAIN ]]; then
    [[ -t 0 ]] || die "No domain given. Usage: bash $0 n8n.example.com"
    printf 'Domain for n8n (e.g. n8n.example.com): '
    read -r DOMAIN || die "No input."
  fi
  DOMAIN=$(normalize_domain "$DOMAIN")
  if [[ -z $DOMAIN ]] || ! is_domain "$DOMAIN"; then
    die "Invalid domain '${DOMAIN}'. Use something like n8n.example.com."
  fi
}

install_all() {
  parse_args "$@"
  resolve_domain
  setup_logging
  trap '_on_err $LINENO' ERR

  say "=== n8n-setup ${SCRIPT_VERSION}: n8n + Docker + nginx + Let's Encrypt ==="
  say "domain : ${DOMAIN}"

  load_os
  ensure_base_packages
  prepare_settings
  say "image  : ${IMAGE_REF}:${IMAGE_TAG} (${DB_TYPE}, timezone ${TIMEZONE})"
  precheck_disk
  precheck_dns
  precheck_domain_free
  precheck_ports
  ensure_swap
  set_cert_paths

  # --- 1. Docker ----------------------------------------------------------
  install_docker

  # --- 2. n8n -------------------------------------------------------------
  prepare_dirs
  write_env
  render_compose
  start_n8n
  setup_owner

  # --- 3. nginx (port 80 first: needed for the ACME challenge) ------------
  ensure_nginx
  [[ $OPEN_FIREWALL -eq 1 ]] && open_firewall_rules
  warn_closed_firewall
  if cert_valid; then
    render_nginx https
  else
    render_nginx http
  fi
  apply_nginx

  # --- 4. certificate -----------------------------------------------------
  obtain_certificate || die "Could not obtain a certificate for ${DOMAIN}."
  install_renew_hook
  render_nginx https
  apply_nginx

  # --- 5. checks ----------------------------------------------------------
  if verify_https; then
    say "HTTPS check OK: https://${DOMAIN}/healthz"
  else
    warn "https://${DOMAIN}/healthz did not answer 200 through nginx; see: n8nctl status"
  fi

  install_self
  print_summary
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
load_installed() {
  load_env || die "No install found (${ENV_FILE} is missing); run the installer first."
  DOMAIN="${N8N_DOMAIN:-}"
  IMAGE_REF="${N8N_SETUP_IMAGE:-${N8N_IMAGE:-$DEFAULT_IMAGE}}"
  IMAGE_TAG="${N8N_SETUP_TAG:-${N8N_TAG:-latest}}"
  TIMEZONE="${N8N_TZ:-UTC}"
  LOCAL_PORT="${N8N_LOCAL_PORT:-5678}"
  TLS_PORT="${N8N_SETUP_TLS_PORT:-10443}"
  ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-}"
  POSTGRES_PASSWORD="${N8N_POSTGRES_PASSWORD:-}"
  DB_TYPE="${N8N_SETUP_DB:-sqlite}"
  MAX_BODY="${N8N_SETUP_MAX_BODY:-100}"
  EMAIL="${N8N_SETUP_EMAIL:-}"
  STAGING="${N8N_SETUP_STAGING:-0}"
  OWNER_EMAIL="${N8N_SETUP_OWNER_EMAIL:-}"
  OWNER_PASS="${N8N_SETUP_OWNER_PASS:-}"
  set_cert_paths
  detect_compose || die "docker compose is not installed."
}

cmd_status() {
  load_installed
  local state expires
  state=$(docker inspect -f '{{.State.Status}} (restarts: {{.RestartCount}})' n8n 2> /dev/null) || state="missing"
  expires=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires=""
  printf 'Domain      : https://%s/\n' "$DOMAIN"
  printf 'Container   : %s\n' "$state"
  printf 'Version     : %s (%s:%s)\n' "$(n8n_version)" "$IMAGE_REF" "$IMAGE_TAG"
  printf 'Database    : %s\n' "$DB_TYPE"
  if [[ $DB_TYPE == postgres ]]; then
    printf 'Postgres    : %s\n' "$(docker inspect -f '{{.State.Status}} / {{if .State.Health}}{{.State.Health.Status}}{{end}}' n8n-postgres 2> /dev/null || printf missing)"
  fi
  printf 'Local health: %s\n' "$(n8n_healthy && printf 'OK (127.0.0.1:%s)' "$LOCAL_PORT" || printf 'FAIL')"
  printf 'HTTPS health: %s\n' "$(verify_https && printf OK || printf FAIL)"
  printf 'nginx       : %s\n' "$(svc_active nginx && printf active || printf inactive)"
  if [[ $(listen_mode) == loopback ]]; then
    printf 'HTTPS on    : 127.0.0.1:%s (behind the dns-setup.sh relay on :443)\n' "$TLS_PORT"
  else
    printf 'HTTPS on    : :443\n'
  fi
  printf 'Certificate : %s\n' "${expires:-missing}"
  printf 'Disk (data) : %s\n' "$(du -sh "$N8N_DIR" 2> /dev/null | awk '{print $1}')"
}

cmd_info() {
  load_installed
  printf 'Login link  : https://%s/\n' "$DOMAIN"
  if [[ -n $OWNER_EMAIL ]]; then
    printf 'Owner email : %s\n' "$OWNER_EMAIL"
    printf 'Password    : %s\n' "$OWNER_PASS"
  fi
  printf 'Webhook URL : https://%s/webhook/<path>\n' "$DOMAIN"
  printf 'Data dir    : %s\n' "$N8N_DIR"
  printf 'Settings    : %s\n' "$ENV_FILE"
  printf 'Enc. key    : %s\n' "$ENCRYPTION_KEY"
  printf 'Backups     : %s\n' "$BACKUP_DIR"
  printf 'Reset owner : docker exec -it n8n n8n user-management:reset\n'
}

cmd_logs() {
  load_installed
  if [[ ${1-} == "-f" ]]; then
    compose logs --tail 200 -f n8n
  else
    compose logs --tail 200 n8n
  fi
}

cmd_restart() {
  load_installed
  compose up -d --force-recreate --remove-orphans || die "docker compose up failed."
  wait_n8n 90 || die "n8n did not come back (n8nctl logs)."
  say "n8n restarted: $(n8n_version)"
}

cmd_backup() {
  load_installed
  install -d -m 700 "$BACKUP_DIR"
  local stamp out tmp rc=0
  stamp=$(date +%Y%m%d-%H%M%S)
  out="${BACKUP_DIR}/n8n-${stamp}.tar.gz"
  tmp=$(mktemp -d)

  if [[ $DB_TYPE == postgres ]]; then
    say "Dumping the Postgres database ..."
    docker exec n8n-postgres pg_dump -U n8n -d n8n --no-owner > "${tmp}/postgres.sql" \
      || { rm -rf "$tmp"; die "pg_dump failed."; }
    tar -czf "$out" -C "$N8N_DIR" .env docker-compose.yml data files \
      -C "$tmp" postgres.sql || rc=$?
  else
    # SQLite: stop n8n for a consistent copy of database.sqlite
    say "Stopping n8n for a consistent SQLite copy ..."
    compose stop n8n > /dev/null 2>&1 || true
    tar -czf "$out" -C "$N8N_DIR" .env docker-compose.yml data files || rc=$?
    compose start n8n > /dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
  if ((rc != 0)); then
    rm -f "$out"
    die "Backup failed (tar exit ${rc})."
  fi
  chmod 600 "$out"

  local old
  while IFS= read -r old; do
    rm -f "$old"
  done < <(ls -1t "$BACKUP_DIR"/n8n-*.tar.gz 2> /dev/null | tail -n +"$((BACKUP_KEEP + 1))")

  if [[ $DB_TYPE != postgres ]]; then
    wait_n8n 90 || warn "n8n did not come back after the backup (n8nctl logs)."
  fi
  say "Backup written: ${out} ($(du -h "$out" | awk '{print $1}'))"
  say "Restore: stop n8n, extract into ${N8N_DIR}, then n8nctl restart"
}

cmd_update() {
  local new_tag=${1-} before
  if [[ -n $new_tag && ! $new_tag =~ ^[A-Za-z0-9_.-]+$ ]]; then
    die "Invalid tag '${new_tag}'."
  fi
  cmd_backup # also loads the install
  before=$(n8n_version)
  if [[ -n $new_tag ]]; then
    IMAGE_TAG=$new_tag
    write_env
  fi
  render_compose
  say "Pulling ${IMAGE_REF}:${IMAGE_TAG} ..."
  compose pull || die "Could not pull the image (blocked region? set a mirror in /etc/docker/daemon.json)."
  compose up -d --remove-orphans || die "docker compose up failed."
  wait_n8n 150 || die "n8n did not come back after the update (n8nctl logs); the backup is in ${BACKUP_DIR}."
  docker image prune -f > /dev/null 2>&1 || true
  say "n8n updated: ${before} -> $(n8n_version)"
}

cmd_renew() {
  load_installed
  certbot renew --cert-name "$DOMAIN" --force-renewal || die "certbot renew failed."
  systemctl reload nginx 2> /dev/null || true
  say "Certificate renewed and nginx reloaded."
}

# dns-setup.sh calls this when its relay takes :443 over or gives it back.
cmd_nginx() {
  load_installed
  if cert_valid; then
    render_nginx https
  else
    warn "No valid certificate for ${DOMAIN}; rendering the HTTP-only site."
    render_nginx http
  fi
  apply_nginx
  if [[ $(listen_mode) == loopback ]]; then
    say "n8n now serves HTTPS on 127.0.0.1:${TLS_PORT} behind the dns-setup.sh relay."
  else
    say "n8n now serves HTTPS on :443."
  fi
}

cmd_uninstall() {
  local yes=0 purge=0 a ans=""
  for a in "$@"; do
    case "$a" in
      --yes) yes=1 ;;
      --purge) purge=1 ;;
      *) die "Unknown option: ${a}" ;;
    esac
  done
  if ((yes == 0)); then
    if ((purge == 1)); then
      printf 'This removes n8n AND deletes %s (all workflows and credentials). Type "yes": ' "$N8N_DIR"
    else
      printf 'This removes the n8n containers, the nginx config and n8nctl (data in %s stays). Type "yes": ' "$N8N_DIR"
    fi
    read -r ans || true
    [[ $ans == yes ]] || die "Aborted."
  fi

  load_env || true
  DOMAIN="${N8N_DOMAIN:-}"
  if [[ -f $COMPOSE_FILE ]] && detect_compose; then
    say "Stopping the containers ..."
    compose down --remove-orphans || warn "docker compose down failed."
  fi

  say "Removing the nginx configuration ..."
  rm -f "$NGINX_CONF" "$RENEW_HOOK" "$SNI_MAP"
  rm -rf "$ACME_ROOT"
  if command -v nginx > /dev/null 2>&1 && nginx -t > /dev/null 2>&1; then
    systemctl reload nginx > /dev/null 2>&1 || true
  fi

  rm -f /usr/local/sbin/n8n-setup /usr/local/bin/n8nctl
  if ((purge == 1)); then
    say "Deleting ${N8N_DIR} ..."
    rm -rf "$N8N_DIR"
  else
    say "Data kept in ${N8N_DIR}; re-running the installer picks it up again."
  fi
  say "Uninstalled. Docker and nginx stay installed."
  if [[ -n $DOMAIN ]]; then
    say "Remove the certificate with: certbot delete --cert-name ${DOMAIN}"
  fi
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
    status | info | logs | restart | update | backup | renew | nginx | uninstall)
      shift
      "cmd_${cmd}" "$@"
      ;;
    *)
      install_all "$@"
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  # untouched defaults, used to rebuild n8nctl after a piped run
  PRISTINE_VARS=$(declare -p SCRIPT_VERSION N8N_DIR ENV_FILE COMPOSE_FILE LOG_FILE     BACKUP_DIR BACKUP_KEEP NGINX_CONF ACME_ROOT RENEW_HOOK TLS_DIR DS_STREAM_CONF     SNI_ROUTES_DIR SNI_MAP COMPOSE_PROJECT DEFAULT_IMAGE HUB_IMAGE POSTGRES_IMAGE     DOMAIN EMAIL IMAGE_TAG IMAGE_REF TIMEZONE LOCAL_PORT TLS_PORT MAX_BODY     REGISTRY_MIRROR OWNER_EMAIL OWNER_PASS DB_TYPE SKIP_DNS OPEN_FIREWALL SWAP     STAGING WANT_POSTGRES ENCRYPTION_KEY POSTGRES_PASSWORD PUBLIC_IPV4 COMPOSE_BIN     NGINX_RESTART OS_ID OS_CODENAME CERT_FULLCHAIN CERT_PRIVKEY)
  main "$@"
fi
