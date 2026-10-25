#!/usr/bin/env bash
# =============================================================================
#  front-deploy.sh -- a React (or any static) frontend behind nginx with a
#                     Let's Encrypt certificate, built from its git repository
#
#  What it does
#    1. asks for the domain and checks that it points here (www.<domain> is
#       served too, as a redirect, when it also points here)
#    2. asks for the git repository. A public one is cloned over HTTPS; for a
#       private one it creates a read-only deploy key, shows it and waits
#       until it is added to the repository. Instead of a repository you can
#       give a path on this server to a ready build (folder, .zip, .tar.gz)
#    3. installs `front-update` and runs the first build with it: Node.js from
#       the project's .nvmrc / engines, npm / pnpm / yarn from the lockfile,
#       finds the build folder (dist, build, ...) and asks to confirm it
#    4. installs nginx with SPA routing (unknown paths -> index.html), gzip,
#       long caching for fingerprinted bundles and none for index.html
#    5. gets a Let's Encrypt certificate (HTTP-01, webroot) with auto-renewal
#
#  After a push, `front-update` pulls, builds and switches to the new release
#  in one step; `front-update rollback` goes back to the previous one.
#
#  This file is independent from dns-setup.sh, n8n-setup.sh and
#  3xui-setup.sh: each site has its own nginx file, certificate and folder.
#  When dns-setup.sh owns :443 (nginx stream SNI relay), the sites listen on
#  127.0.0.1:10444 instead and the relay forwards their domains there.
#
#  Usage:
#    bash front-deploy.sh                      (asks for the domain and the repository)
#    bash front-deploy.sh --open-firewall --email me@example.com
#    bash <(curl -Ls https://raw.githubusercontent.com/USER/REPO/main/front-deploy.sh)
#    front-update
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Paths (shared with front-update.sh; overridable from the environment)
# ---------------------------------------------------------------------------
FD_ETC="${FD_ETC:-/etc/front-deploy}"
SITES_DIR="${FD_ETC}/sites"
WWW_ROOT="${FD_WWW_ROOT:-/var/www}"
FD_HOME="${FD_HOME:-/var/lib/front-deploy}"
BUILD_USER="${FD_BUILD_USER:-frontdeploy}"
LOG_FILE="${FD_LOG_FILE:-/var/log/front-deploy.log}"
NGINX_DIR="${FD_NGINX_DIR:-/etc/nginx/conf.d}"
ACME_ROOT="${FD_ACME_ROOT:-/var/www/front-deploy-acme}"
TLS_DIR="${FD_TLS_DIR:-/etc/letsencrypt/live}"
RENEW_HOOK="${FD_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/front-deploy-reload.sh}"
DS_STREAM_CONF="/etc/nginx/stream.d/dns-setup-relay.conf"
SNI_ROUTES_DIR="${FD_SNI_ROUTES_DIR:-/etc/nginx/sni-routes.d}"
UPDATE_BIN="${FD_UPDATE_BIN:-/usr/local/bin/front-update}"
UPDATE_URL="${FD_UPDATE_URL:-https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/front-update.sh}"

SITE_VARS=(SITE_DOMAIN SITE_WWW SITE_SOURCE SITE_REPO SITE_BRANCH SITE_KEY
  SITE_APP_DIR SITE_INSTALL_CMD SITE_BUILD_CMD SITE_BUILD_DIR SITE_NODE
  SITE_NPM_REGISTRY SITE_EMAIL SITE_STAGING SITE_TLS_PORT SITE_KEEP SITE_CREATED)
for _v in "${SITE_VARS[@]}"; do
  printf -v "$_v" '%s' ''
done
unset _v

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
DOMAIN=""
OPT_SOURCE=""
OPT_BRANCH=""
OPT_APP_DIR=""
OPT_BUILD_DIR=""
OPT_BUILD_CMD=""
OPT_INSTALL_CMD=""
OPT_NODE=""
OPT_ENV_FILE=""
OPT_REGISTRY=""
OPT_EMAIL=""
OPT_TLS_PORT=""
OPT_KEEP=""
NO_WWW=0
SKIP_DNS=0
OPEN_FIREWALL=0
SWAP=1
STAGING=0

EXISTING=0
DIST_PATH=""
REMOTE_HEAD=""
REPO_HOST=""
REPO_PATH=""
PUBLIC_IPV4=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
front-deploy.sh -- deploy a React (or any static) frontend from its git
repository behind nginx with a Let's Encrypt certificate.

Usage:
  sudo bash front-deploy.sh [options]     (asks for the domain and the repository)

Options:
      --repo <url>          git repository (https://github.com/me/app or
                            git@github.com:me/app.git), or a path on this server
                            to a ready build: folder, .zip or .tar.gz
      --branch <name>       branch to deploy (default: the repository's default)
      --app-dir <dir>       folder of the frontend inside the repository
                            (default: the root, or the only one with package.json)
      --build-dir <dir>     build output folder (default: detected, e.g. dist)
      --build-cmd <cmd>     build command (default: <npm|pnpm|yarn> run build)
      --install-cmd <cmd>   dependency install (default: from the lockfile)
      --node <major>        Node.js major, e.g. 22 (default: .nvmrc, engines, 24)
      --env-file <path>     .env with build-time variables (VITE_*, REACT_APP_*)
      --npm-registry <url>  npm registry, e.g. https://registry.npmmirror.com
                            (default: registry.npmjs.org, a mirror when blocked)
  -e, --email <address>     Let's Encrypt account email (default: none)
      --no-www              do not serve www.<domain>, even when it points here
      --keep <n>            releases kept for rollback (default: 5)
      --tls-port <n>        loopback HTTPS port when dns-setup.sh owns :443
                            (default: 10444)
      --skip-dns-check      do not verify that the domain points to this server
      --open-firewall       open 80 and 443 in ufw / firewalld
      --no-swap             do not add a 2 GB swap file on small servers
      --staging             Let's Encrypt staging CA (testing only)
  -h, --help                show this help

Re-running the script for a deployed domain changes its settings (repository,
branch, folders, ...) and keeps the rest.

After the install:
  front-update              pull, build and publish the latest commit
  front-update rollback     back to the previous release
  front-update list         all sites
  front-update --help       everything else
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
    exec sudo -E bash "$(readlink -f "$0")" "$@"
  fi
  die "This script must be run as root."
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

load_os() {
  local pretty
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported OS."
  # shellcheck disable=SC1091
  pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
  if [[ ${pretty,,} != *ubuntu* && ${pretty,,} != *debian* ]]; then
    warn "This script targets Ubuntu/Debian; '${pretty}' is untested."
  fi
  say "OS: ${pretty}"
}

normalize_domain() {
  local d=$1
  d=${d#*://}
  d=${d%%/*}
  d=${d%%:*}
  d=${d%.}
  printf '%s\n' "$d" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
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

mask_url() {
  printf '%s\n' "$1" | sed -E 's#(://)[^/@]+@#\1***@#'
}

ask() { # prompt default -> REPLY_VALUE
  local prompt=$1 def=${2-} ans=""
  if [[ -n $def ]]; then
    printf '%s [%s]: ' "$prompt" "$def"
  else
    printf '%s: ' "$prompt"
  fi
  read -r ans || die "No input."
  REPLY_VALUE=${ans:-$def}
}

port_in_use() {
  ss -ltn 2> /dev/null | awk -v p=":${1}" '$4 ~ p"$" {found=1} END {exit !found}'
}

port_holder() {
  ss -ltnp 2> /dev/null | awk -v p=":${1}$" '$4 ~ p && !found {print; found=1}'
}

public_ipv4() {
  local url ip
  for url in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2> /dev/null | tr -d '[:space:]"') || true
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

resolve_ipv4() {
  local ip=""
  ip=$(getent ahostsv4 "$1" 2> /dev/null | awk 'NR == 1 {print $1}') || true
  printf '%s\n' "$ip"
}

svc_active() {
  systemctl is-active --quiet "$1" 2> /dev/null
}

apt_update() {
  apt-get -o DPkg::Lock::Timeout=180 update -qq
}

apt_install() {
  command -v apt-get > /dev/null 2>&1 || die "apt-get is required to install: $*"
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$@"
}

ensure_packages() {
  local missing=() p
  for p in curl git openssl python3; do
    command -v "$p" > /dev/null 2>&1 || missing+=("$p")
  done
  command -v ssh-keygen > /dev/null 2>&1 || missing+=(openssh-client)
  command -v ss > /dev/null 2>&1 || missing+=(iproute2)
  command -v unzip > /dev/null 2>&1 || missing+=(unzip)
  [[ -d /etc/ssl/certs ]] || missing+=(ca-certificates)
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  say "Installing packages: ${missing[*]}"
  apt_update || die "apt-get update failed."
  apt_install "${missing[@]}" || die "Could not install: ${missing[*]}"
}

# after the port checks: nginx starts right away when it is installed
ensure_nginx() {
  local missing=()
  command -v nginx > /dev/null 2>&1 || missing+=(nginx)
  command -v certbot > /dev/null 2>&1 || missing+=(certbot)
  if ((${#missing[@]} > 0)); then
    say "Installing: ${missing[*]}"
    apt_update || die "apt-get update failed."
    apt_install "${missing[@]}" || die "Could not install: ${missing[*]}"
  fi
  [[ -d $NGINX_DIR ]] || die "${NGINX_DIR} is missing; unexpected nginx layout."
  if ! grep -rqs 'conf\.d/\*\.conf' /etc/nginx/nginx.conf; then
    die "/etc/nginx/nginx.conf does not include conf.d/*.conf; add it and re-run."
  fi
  install -d -m 755 "${ACME_ROOT}/.well-known/acme-challenge"
}

# ---------------------------------------------------------------------------
# Site settings
# ---------------------------------------------------------------------------
save_site() {
  local f="${SITES_DIR}/${SITE_DOMAIN}.conf" tmp v
  install -d -m 700 "$FD_ETC" "$SITES_DIR"
  tmp=$(mktemp)
  {
    printf '# front-deploy site, written %s -- read by front-update\n' "$(date -Is)"
    for v in "${SITE_VARS[@]}"; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
}

load_existing() {
  local f="${SITES_DIR}/${DOMAIN}.conf"
  [[ -r $f ]] || return 0
  # shellcheck disable=SC1090
  . "$f"
  EXISTING=1
  say "${DOMAIN} is already deployed; updating its settings."
}

# ---------------------------------------------------------------------------
# Build user (same as front-update.sh)
# ---------------------------------------------------------------------------
ensure_build_user() {
  if ! id -u "$BUILD_USER" > /dev/null 2>&1; then
    useradd --system --user-group --home-dir "$FD_HOME" --shell /usr/sbin/nologin "$BUILD_USER" \
      || die "Could not create the ${BUILD_USER} user."
  fi
  install -d -m 750 -o "$BUILD_USER" -g "$BUILD_USER" "$FD_HOME"
  install -d -m 700 -o "$BUILD_USER" -g "$BUILD_USER" "${FD_HOME}/.ssh" "${FD_HOME}/keys"
}

as_builder() { # key-or-empty command...
  local key=$1 v env=(HOME="$FD_HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 GIT_TERMINAL_PROMPT=0)
  shift
  if [[ -n $key ]]; then
    env+=(GIT_SSH_COMMAND="ssh -i ${key} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${FD_HOME}/.ssh/known_hosts")
  fi
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [[ -n ${!v:-} ]]; then
      env+=("${v}=${!v}")
    fi
  done
  (cd "$FD_HOME" && runuser -u "$BUILD_USER" -- env -i "${env[@]}" "$@")
}

# ---------------------------------------------------------------------------
# Domain and pre-checks
# ---------------------------------------------------------------------------
resolve_domain() {
  if [[ -z $DOMAIN ]]; then
    [[ -t 0 ]] || die "No domain given and no terminal to ask for one."
    ask "Domain for the site (e.g. example.com or app.example.com)"
    DOMAIN=$REPLY_VALUE
  fi
  DOMAIN=$(normalize_domain "$DOMAIN")
  if [[ -z $DOMAIN ]] || ! is_domain "$DOMAIN"; then
    die "Invalid domain '${DOMAIN}'. Use something like example.com."
  fi
}

precheck_disk() {
  local avail
  avail=$(df -Pk / 2> /dev/null | awk 'NR == 2 {print $4}') || true
  if [[ $avail =~ ^[0-9]+$ ]] && ((avail < 2097152)); then
    die "At least 2 GB of free disk space is required for Node.js, node_modules and the builds (found $((avail / 1024)) MB)."
  fi
}

# Also decides about www.<domain>: served (as a redirect) when it points here.
precheck_dns() {
  local resolved www
  if [[ $SKIP_DNS -eq 1 ]]; then
    warn "DNS verification skipped (--skip-dns-check)."
    [[ $EXISTING -eq 1 && $NO_WWW -eq 0 ]] || SITE_WWW=0
    return 0
  fi
  if ! PUBLIC_IPV4=$(public_ipv4); then
    warn "Could not detect this server's public IPv4; skipping the DNS check."
    [[ $EXISTING -eq 1 && $NO_WWW -eq 0 ]] || SITE_WWW=0
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

  SITE_WWW=0
  if [[ $NO_WWW -eq 0 && $DOMAIN != www.* ]]; then
    www=$(resolve_ipv4 "www.${DOMAIN}")
    if [[ $www == "$PUBLIC_IPV4" ]]; then
      SITE_WWW=1
      say "www.${DOMAIN} points here too; it will redirect to ${DOMAIN}."
    fi
  fi
}

# Every setup on the server needs its own (sub)domain.
precheck_domain_free() {
  local entry f key owner d
  for entry in "/etc/dns-setup/state.env|DS_DOMAIN|dns-setup.sh" "/root/3xui-info.env|XUI_DOMAIN|3xui-setup.sh" "/opt/n8n/.env|N8N_DOMAIN|n8n-setup.sh"; do
    IFS='|' read -r f key owner <<< "$entry"
    [[ -r $f ]] || continue
    d=$(sed -n -E "s/^${key}='?([^']*)'?$/\1/p" "$f" | sed -n '1p')
    if [[ $d == "$DOMAIN" || ($SITE_WWW == 1 && $d == "www.${DOMAIN}") ]]; then
      die "${d} is already used by ${owner}. Give the site its own domain or subdomain."
    fi
  done

  if [[ -f /etc/back-deploy/apps/${DOMAIN}.conf ]]; then
    die "${DOMAIN} is a back-deploy.sh backend. Give the site its own domain or subdomain."
  fi

  # other front-deploy sites: example.com (with its www redirect) and
  # www.example.com as a site of its own cannot both exist
  for f in "$SITES_DIR"/*.conf; do
    [[ -f $f ]] || continue
    d=${f##*/}
    d=${d%.conf}
    [[ $d != "$DOMAIN" ]] || continue
    if [[ $DOMAIN == "www.${d}" ]] && grep -qx 'SITE_WWW=1' "$f"; then
      die "${DOMAIN} is already the www redirect of the site ${d}. Re-run this script for ${d} with --no-www first."
    fi
    if [[ $SITE_WWW == 1 && $d == "www.${DOMAIN}" ]]; then
      warn "www.${DOMAIN} is a site of its own here; ${DOMAIN} is served without the www redirect."
      SITE_WWW=0
    fi
  done
}

relay_active() {
  [[ -f $DS_STREAM_CONF ]]
}

precheck_ports() {
  local p holder
  if relay_active; then
    if ! grep -qF "$SNI_ROUTES_DIR" "$DS_STREAM_CONF"; then
      die "The dns-setup.sh relay on this server is too old for other sites. Re-run the current dns-setup.sh first, then this script."
    fi
    say "dns-setup.sh owns TCP/443; the site goes behind its SNI relay (127.0.0.1:${SITE_TLS_PORT})."
    if port_in_use "$SITE_TLS_PORT"; then
      holder=$(port_holder "$SITE_TLS_PORT") || true
      if [[ $holder != *'"nginx"'* ]]; then
        die "TCP/${SITE_TLS_PORT} is in use: ${holder:-unknown}. Pick another port with --tls-port."
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
}

# Builds (webpack / Vite) easily need 1-2 GB; small VPSes get hit by the
# OOM killer without some swap.
ensure_swap() {
  [[ $SWAP -eq 1 ]] || return 0
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2> /dev/null) || return 0
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2> /dev/null) || return 0
  [[ $mem_kb =~ ^[0-9]+$ && $swap_kb =~ ^[0-9]+$ ]] || return 0
  if ((mem_kb >= 3000000 || swap_kb > 0)); then
    return 0
  fi
  if [[ -e /swapfile ]]; then
    warn "/swapfile exists but is not active; leaving it alone."
    return 0
  fi
  say "Only $((mem_kb / 1024)) MB RAM and no swap: adding a 2 GB swap file for the builds ..."
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
# Source: git repository or a ready build
# ---------------------------------------------------------------------------
resolve_source() {
  local src=$OPT_SOURCE def=""
  if [[ -z $src ]]; then
    if [[ $SITE_SOURCE == git && -n $SITE_REPO ]]; then
      def=$SITE_REPO
    fi
    [[ -t 0 ]] || die "No repository given (--repo) and no terminal to ask for one."
    printf 'Git repository of the frontend, e.g. https://github.com/me/app\n'
    printf '(or a path on this server to a ready build: folder, .zip, .tar.gz)\n'
    ask "Repository" "$def"
    src=$REPLY_VALUE
  fi
  src=${src#"${src%%[![:space:]]*}"}
  src=${src%"${src##*[![:space:]]}"}
  [[ -n $src ]] || die "No repository given."
  src=${src/#\~/$HOME}

  if [[ -e $src ]]; then
    DIST_PATH=$(readlink -f "$src")
    SITE_SOURCE=upload
    SITE_REPO=""
    SITE_BRANCH=""
    SITE_KEY=""
    say "Source: a ready build (${DIST_PATH}); later updates take one with front-update --dist <path>."
    return 0
  fi

  # github.com/me/app -> https://github.com/me/app
  if [[ $src != *://* && $src != *@*:* && $src =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}/ ]]; then
    src="https://${src}"
  fi
  parse_repo_url "$src" || die "'$(mask_url "$src")' is neither a git URL nor an existing path."
  if [[ $SITE_SOURCE == git && -n $SITE_REPO && $SITE_REPO != "$src" ]] && ! same_repo "$SITE_REPO" "$src"; then
    say "The repository changed; the next build starts from a fresh clone."
    rm -rf "${WWW_ROOT}/${DOMAIN}/repo" "${WWW_ROOT}/${DOMAIN}/meta/deps.hash"
    [[ -n $OPT_APP_DIR ]] || SITE_APP_DIR=""
    [[ -n $OPT_BUILD_DIR ]] || SITE_BUILD_DIR=""
    SITE_BRANCH=""
  fi
  SITE_SOURCE=git
  SITE_REPO=$src
}

parse_repo_url() { # url -> REPO_HOST REPO_PATH
  local u=$1 host path
  if [[ $u =~ ^(https?|ssh|git)://([^/@]+@)?([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
    host=${BASH_REMATCH[3]}
    path=${BASH_REMATCH[5]}
  elif [[ $u =~ ^([A-Za-z0-9._-]+@)?([A-Za-z0-9.-]+\.[A-Za-z]{2,}):([^/].*)$ ]]; then
    host=${BASH_REMATCH[2]}
    path=${BASH_REMATCH[3]}
  else
    return 1
  fi
  path=${path%/}
  path=${path%.git}
  [[ $path == */* ]] || return 1
  REPO_HOST=${host,,}
  REPO_PATH=$path
}

same_repo() {
  local a b
  parse_repo_url "$1" || return 1
  a="${REPO_HOST#ssh.}/${REPO_PATH,,}" # ssh.github.com:443 is github.com
  parse_repo_url "$2" || return 1
  b="${REPO_HOST#ssh.}/${REPO_PATH,,}"
  [[ $a == "$b" ]]
}

ls_remote() { # url key -> sets REMOTE_HEAD (default branch)
  local out
  out=$(as_builder "$2" timeout 60 git ls-remote --symref -- "$1" HEAD 2> /dev/null) || return 1
  REMOTE_HEAD=$(printf '%s\n' "$out" | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' | head -n 1)
  return 0
}

print_deploy_key() { # key
  local pub
  pub=$(cat "${1}.pub")
  printf '\n'
  printf '==============================================================\n'
  printf ' Deploy key for %s (read-only)\n' "$REPO_PATH"
  printf '==============================================================\n'
  printf '%s\n' "$pub"
  printf '%s\n' '--------------------------------------------------------------'
  if [[ $REPO_HOST == github.com ]]; then
    printf ' Add it here: https://github.com/%s/settings/keys/new\n' "$REPO_PATH"
    printf ' Any title, paste the line above, leave "Allow write access" off.\n'
  elif [[ $REPO_HOST == gitlab.com ]]; then
    printf ' Add it here: https://gitlab.com/%s/-/settings/repository\n' "$REPO_PATH"
    printf ' (Deploy keys -> Add new key, without write access)\n'
  else
    printf ' Add it in the repository settings under "Deploy keys"\n'
    printf ' (read-only, no write access).\n'
  fi
  printf '==============================================================\n\n'
}

# Public repositories are read over HTTPS. Anything else gets its own
# ed25519 deploy key (GitHub accepts a key on one repository only).
ensure_repo_access() {
  local key="${FD_HOME}/keys/${DOMAIN}" candidates=() c ans shown=0
  ensure_build_user
  if [[ $SITE_REPO == http://* || $SITE_REPO == https://* ]]; then
    say "Checking $(mask_url "$SITE_REPO") ..."
    if ls_remote "$SITE_REPO" ""; then
      SITE_KEY=""
      say "The repository is reachable over HTTPS."
      return 0
    fi
    say "Not readable anonymously (private repository, or a wrong URL); using a deploy key over SSH."
    candidates=("git@${REPO_HOST}:${REPO_PATH}.git")
  else
    candidates=("$SITE_REPO")
  fi
  if [[ $REPO_HOST == github.com ]]; then
    # for servers where outgoing port 22 is blocked
    candidates+=("ssh://git@ssh.github.com:443/${REPO_PATH}.git")
  fi

  if [[ ! -s $key ]]; then
    as_builder "" ssh-keygen -q -t ed25519 -N '' -C "front-deploy@${DOMAIN}" -f "$key" \
      || die "Could not create a deploy key."
  fi

  while :; do
    for c in "${candidates[@]}"; do
      if ls_remote "$c" "$key"; then
        SITE_REPO=$c
        SITE_KEY=$key
        say "Repository access OK: ${c}"
        return 0
      fi
    done
    if ((shown == 0)); then
      print_deploy_key "$key"
      shown=1
    else
      warn "Still no access with the deploy key."
    fi
    [[ -t 0 ]] || die "Add the deploy key above to the repository, then re-run this script."
    printf 'Add the key, then press Enter to try again (k = show the key, q = quit): '
    read -r ans || die "No input."
    case $ans in
      q | Q) die "Stopped. If the URL was wrong, re-run the script with the right one." ;;
      k | K) print_deploy_key "$key" ;;
    esac
  done
}

resolve_branch() {
  local def=${OPT_BRANCH:-${SITE_BRANCH:-${REMOTE_HEAD:-main}}}
  if [[ -n $OPT_BRANCH || ! -t 0 ]]; then
    SITE_BRANCH=$def
  else
    ask "Branch" "$def"
    SITE_BRANCH=$REPLY_VALUE
  fi
  [[ $SITE_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid branch '${SITE_BRANCH}'."
  local out
  out=$(as_builder "$SITE_KEY" timeout 60 git ls-remote --heads -- "$SITE_REPO" "refs/heads/${SITE_BRANCH}" 2> /dev/null) || true
  [[ -n $out ]] || die "Branch '${SITE_BRANCH}' does not exist in the repository."
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
apply_options() {
  [[ -n $OPT_APP_DIR ]] && SITE_APP_DIR=$OPT_APP_DIR
  [[ -n $OPT_BUILD_DIR ]] && SITE_BUILD_DIR=$OPT_BUILD_DIR
  [[ -n $OPT_BUILD_CMD ]] && SITE_BUILD_CMD=$OPT_BUILD_CMD
  [[ -n $OPT_INSTALL_CMD ]] && SITE_INSTALL_CMD=$OPT_INSTALL_CMD
  [[ -n $OPT_NODE ]] && SITE_NODE=$OPT_NODE
  [[ -n $OPT_REGISTRY ]] && SITE_NPM_REGISTRY=$OPT_REGISTRY
  [[ -n $OPT_EMAIL ]] && SITE_EMAIL=$OPT_EMAIL
  [[ -n $OPT_TLS_PORT ]] && SITE_TLS_PORT=$OPT_TLS_PORT
  [[ -n $OPT_KEEP ]] && SITE_KEEP=$OPT_KEEP
  SITE_DOMAIN=$DOMAIN
  SITE_STAGING=$STAGING
  : "${SITE_TLS_PORT:=10444}" "${SITE_KEEP:=5}" "${SITE_WWW:=0}"
  [[ -n $SITE_CREATED ]] || SITE_CREATED=$(date -Is)

  is_port "$SITE_TLS_PORT" && ((SITE_TLS_PORT != 80 && SITE_TLS_PORT != 443)) \
    || die "Invalid --tls-port '${SITE_TLS_PORT}'."
  [[ $SITE_KEEP =~ ^[0-9]+$ ]] && ((SITE_KEEP >= 2)) || die "--keep must be 2 or more."
  [[ -z $SITE_NODE || $SITE_NODE =~ ^[0-9]{2}$ ]] || die "Invalid --node '${SITE_NODE}' (a major version, e.g. 22)."
  if [[ -n $SITE_NPM_REGISTRY && ! $SITE_NPM_REGISTRY =~ ^https?://[^[:space:]]+$ ]]; then
    die "Invalid --npm-registry '${SITE_NPM_REGISTRY}'."
  fi
  local d
  for d in "$SITE_APP_DIR" "$SITE_BUILD_DIR"; do
    [[ -z $d || ($d != /* && $d != *..*) ]] || die "Folders must be inside the project: '${d}'."
  done
}

prepare_site_dirs() {
  local root="${WWW_ROOT}/${DOMAIN}"
  install -d -m 755 "$root" "${root}/releases" "${root}/meta"
  install -d -m 750 -o root -g "$BUILD_USER" "${root}/shared"
  if [[ -n $OPT_ENV_FILE ]]; then
    [[ -r $OPT_ENV_FILE ]] || die "Cannot read --env-file ${OPT_ENV_FILE}."
    install -m 640 -o root -g "$BUILD_USER" "$OPT_ENV_FILE" "${root}/shared/.env"
    say "Build env copied to ${root}/shared/.env"
  fi
}

# front-update.sh next to this script, else from the repository of these scripts
install_update_tool() {
  local src dir tmp
  src=$(readlink -f "$0" 2> /dev/null || printf '%s' "$0")
  dir=$(dirname "$src")
  tmp=$(mktemp)
  if [[ -f ${dir}/front-update.sh && $src != /proc/* && $src != /dev/* ]]; then
    cp "${dir}/front-update.sh" "$tmp"
  else
    say "Downloading front-update.sh ..."
    if ! curl -fsSL --max-time 60 -o "$tmp" "$UPDATE_URL"; then
      rm -f "$tmp"
      die "Could not download ${UPDATE_URL}. Put front-update.sh next to this script and re-run."
    fi
  fi
  if ! grep -q 'front-update.sh -- ' "$tmp" || ! bash -n "$tmp" 2> /dev/null; then
    rm -f "$tmp"
    die "front-update.sh is damaged or incomplete."
  fi
  install -m 755 "$tmp" "$UPDATE_BIN"
  rm -f "$tmp"
  say "Installed ${UPDATE_BIN}."
}

first_publish() {
  local args=(--site "$DOMAIN" --force)
  if [[ $SITE_SOURCE == upload ]]; then
    args+=(--dist "$DIST_PATH")
  fi
  FD_NO_LOG=1 "$UPDATE_BIN" "${args[@]}" \
    || die "The first build failed (output above). Fix it, then re-run this script."
}

# ---------------------------------------------------------------------------
# nginx and certificate
# ---------------------------------------------------------------------------
render_nginx() {
  FD_NO_LOG=1 "$UPDATE_BIN" nginx --site "$DOMAIN" || die "Could not set up nginx for ${DOMAIN}."
}

cert_valid() {
  local full="${TLS_DIR}/${DOMAIN}/fullchain.pem" san
  [[ -s $full && -s ${TLS_DIR}/${DOMAIN}/privkey.pem ]] || return 1
  openssl x509 -in "$full" -noout -checkend 86400 > /dev/null 2>&1 || return 1
  san=$(openssl x509 -in "$full" -noout -ext subjectAltName 2> /dev/null) || return 1
  [[ $san == *"DNS:${DOMAIN}"* ]] || return 1
  [[ $SITE_WWW != 1 || $san == *"DNS:www.${DOMAIN}"* ]]
}

obtain_certificate() {
  if cert_valid; then
    say "A valid certificate for ${DOMAIN} is already present."
    return 0
  fi
  local args=(
    certonly --webroot -w "$ACME_ROOT"
    --cert-name "$DOMAIN" -d "$DOMAIN"
    --agree-tos --no-eff-email
    --non-interactive --keep-until-expiring --expand
  )
  [[ $SITE_WWW == 1 ]] && args+=(-d "www.${DOMAIN}")
  if [[ -n $SITE_EMAIL ]]; then
    args+=(--email "$SITE_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi
  [[ $STAGING -eq 1 ]] && args+=(--staging)

  say "Requesting a Let's Encrypt certificate for ${DOMAIN}$([[ $SITE_WWW == 1 ]] && printf ' + www') ..."
  if ! certbot "${args[@]}"; then
    warn "certbot failed. Common causes: DNS not pointing here, TCP/80 closed in the provider firewall, Cloudflare proxy on."
    return 1
  fi
  cert_valid || die "certbot reported success but the certificate in ${TLS_DIR}/${DOMAIN} is not usable."
  say "Certificate issued."
}

install_renew_hook() {
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  cat > "$RENEW_HOOK" << 'EOF'
#!/bin/sh
# Added by front-deploy.sh: reload nginx after a certificate renewal.
systemctl reload nginx 2>/dev/null || true
EOF
  chmod 755 "$RENEW_HOOK"
  systemctl enable --now certbot.timer > /dev/null 2>&1 || true
}

ufw_is_active() {
  command -v ufw > /dev/null 2>&1 || return 1
  [[ $(ufw status 2> /dev/null) == *'Status: active'* ]]
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

verify_https() {
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${DOMAIN}:443:127.0.0.1")
  [[ $STAGING -eq 1 ]] && args+=(-k)
  local code
  code=$(curl "${args[@]}" "https://${DOMAIN}/" 2> /dev/null) || code=000
  [[ $code == 200 ]]
}

print_summary() {
  local root="${WWW_ROOT}/${DOMAIN}" expires live
  # front-update saved what it detected (app folder, build folder)
  # shellcheck disable=SC1090
  . "${SITES_DIR}/${DOMAIN}.conf"
  expires=$(openssl x509 -in "${TLS_DIR}/${DOMAIN}/fullchain.pem" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires=""
  live=$(readlink "${root}/current" 2> /dev/null) || live=""
  printf '\n'
  printf '==============================================================\n'
  printf ' %s is live\n' "$DOMAIN"
  printf '==============================================================\n'
  printf ' URL         : https://%s/\n' "$DOMAIN"
  if [[ $SITE_WWW == 1 ]]; then
    printf ' www         : https://www.%s/ redirects to it\n' "$DOMAIN"
  fi
  if [[ $SITE_SOURCE == upload ]]; then
    printf ' Source      : uploaded builds\n'
  else
    printf ' Repository  : %s (%s)\n' "$(mask_url "$SITE_REPO")" "$SITE_BRANCH"
    if [[ -n $SITE_KEY ]]; then
      printf ' Deploy key  : %s.pub (read-only)\n' "$SITE_KEY"
    fi
    printf ' Build       : %s -> %s\n' "${SITE_APP_DIR:-.}" "${SITE_BUILD_DIR:-?}"
  fi
  printf ' Release     : %s\n' "${live##*/}"
  printf ' Build env   : %s/shared/.env%s\n' "$root" "$([[ -s ${root}/shared/.env ]] || printf ' (none yet)')"
  printf ' Certificate : expires %s, renews automatically\n' "${expires:-unknown}"
  if relay_active; then
    printf ' HTTPS       : 127.0.0.1:%s, reached through the dns-setup.sh relay on :443\n' "$SITE_TLS_PORT"
  fi
  printf '%s\n' '--------------------------------------------------------------'
  if [[ $SITE_SOURCE == upload ]]; then
    printf ' New build        : front-update --dist <folder|zip|tar.gz>\n'
  else
    printf ' After a push     : front-update\n'
    printf ' Changed .env     : front-update --force\n'
  fi
  printf ' Previous release : front-update rollback\n'
  printf ' All sites        : front-update list | front-update --all\n'
  printf ' Another site     : run this script again with the other domain\n'
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
      --repo)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_SOURCE="$2"
        shift 2
        ;;
      --branch)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_BRANCH="$2"
        shift 2
        ;;
      --app-dir)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_APP_DIR="${2#./}"
        OPT_APP_DIR=${OPT_APP_DIR%/}
        [[ -n $OPT_APP_DIR ]] || OPT_APP_DIR=.
        shift 2
        ;;
      --build-dir)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_BUILD_DIR="${2#./}"
        OPT_BUILD_DIR=${OPT_BUILD_DIR%/}
        shift 2
        ;;
      --build-cmd)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_BUILD_CMD="$2"
        shift 2
        ;;
      --install-cmd)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_INSTALL_CMD="$2"
        shift 2
        ;;
      --node)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_NODE="${2#v}"
        shift 2
        ;;
      --env-file)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_ENV_FILE="$2"
        shift 2
        ;;
      --npm-registry)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_REGISTRY="${2%/}"
        shift 2
        ;;
      -e | --email)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_EMAIL="$2"
        shift 2
        ;;
      --tls-port)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_TLS_PORT="$2"
        shift 2
        ;;
      --keep)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_KEEP="$2"
        shift 2
        ;;
      --no-www)
        NO_WWW=1
        shift
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
      -*)
        die "Unknown option: $1 (try --help)."
        ;;
      *)
        [[ -z $DOMAIN ]] || die "Unexpected argument: $1 (try --help)."
        DOMAIN="$1"
        shift
        ;;
    esac
  done
  if [[ -n $OPT_EMAIL ]] && ! is_email "$OPT_EMAIL"; then
    die "Invalid --email '${OPT_EMAIL}'."
  fi
}

install_all() {
  parse_args "$@"
  resolve_domain
  setup_logging
  trap '_on_err $LINENO' ERR

  say "=== front-deploy ${SCRIPT_VERSION}: frontend + nginx + Let's Encrypt ==="
  say "domain : ${DOMAIN}"

  load_os
  ensure_packages
  load_existing
  apply_options
  precheck_disk
  precheck_dns
  precheck_domain_free
  precheck_ports
  ensure_nginx
  [[ $OPEN_FIREWALL -eq 1 ]] && open_firewall_rules
  warn_closed_firewall

  # --- 1. source ----------------------------------------------------------
  ensure_build_user
  resolve_source
  if [[ $SITE_SOURCE == git ]]; then
    ensure_repo_access
    resolve_branch
    ensure_swap
  fi
  prepare_site_dirs
  save_site
  install_update_tool

  # --- 2. first build (nothing is published if it fails) ------------------
  first_publish

  # --- 3. nginx: port 80 first, needed for the ACME challenge -------------
  render_nginx

  # --- 4. certificate -----------------------------------------------------
  obtain_certificate || die "Could not obtain a certificate for ${DOMAIN}. The site is served over http:// until you re-run this script."
  install_renew_hook
  render_nginx

  # --- 5. check -----------------------------------------------------------
  if verify_https; then
    say "HTTPS check OK: https://${DOMAIN}/"
  else
    warn "https://${DOMAIN}/ did not answer 200 through nginx; check: nginx -t, front-update list"
  fi
  print_summary
}

main() {
  case "${1-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac
  require_root "$@"
  install_all "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
