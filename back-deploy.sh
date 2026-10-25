#!/usr/bin/env bash
# =============================================================================
#  back-deploy.sh -- a Node.js (Express, Nest, Fastify, ...) backend from its
#                    git repository, behind nginx with a Let's Encrypt
#                    certificate, run by systemd with zero-downtime updates
#
#  What it does
#    1. asks where to serve it: on its own subdomain (api.example.com, checks
#       that it points here) or under a path of a front-deploy.sh site
#       (example.com/api: the frontend's domain and certificate, no CORS)
#    2. asks for the git repository. A public one is cloned over HTTPS; for a
#       private one it creates a read-only deploy key, shows it and waits
#       until it is added to the repository
#    3. asks for the app's .env (optional; edit it later with back-update env)
#    4. installs `back-update` and runs the first deploy with it: Node.js from
#       .nvmrc / engines, npm / pnpm / yarn from the lockfile, the "build"
#       script (TypeScript) when there is one, the start command from
#       package.json (asked to confirm), then starts the app and waits until
#       it answers HTTP
#    5. nginx in front (websockets, real client IP headers, upload limit) and
#       a Let's Encrypt certificate (HTTP-01, webroot) with auto-renewal
#
#  The app runs as its own systemd DynamicUser on a local port (PORT in its
#  environment); two instances per app (blue/green) make updates and
#  restarts switch without downtime.
#
#  This file is independent from front-deploy.sh, dns-setup.sh, n8n-setup.sh
#  and 3xui-setup.sh: each app has its own nginx file, certificate, unit and
#  folder. When dns-setup.sh owns :443 (nginx stream SNI relay), the apps
#  listen on 127.0.0.1:10445 instead and the relay forwards their domains.
#
#  Usage:
#    bash back-deploy.sh                       (asks for the domain and the repository)
#    bash back-deploy.sh --release-cmd "npx prisma migrate deploy" --data-dir uploads
#    bash <(curl -Ls https://raw.githubusercontent.com/USER/REPO/main/back-deploy.sh)
#    back-update
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Paths (shared with back-update.sh; overridable from the environment)
# ---------------------------------------------------------------------------
BD_ETC="${BD_ETC:-/etc/back-deploy}"
SITES_DIR="${BD_ETC}/apps"
APPS_ROOT="${BD_APPS_ROOT:-/srv/back-deploy}"
BD_HOME="${BD_HOME:-/var/lib/back-deploy-build}"
BUILD_USER="${BD_BUILD_USER:-backdeploy}"
LOG_FILE="${BD_LOG_FILE:-/var/log/back-deploy.log}"
NGINX_DIR="${BD_NGINX_DIR:-/etc/nginx/conf.d}"
ACME_ROOT="${BD_ACME_ROOT:-/var/www/back-deploy-acme}"
TLS_DIR="${BD_TLS_DIR:-/etc/letsencrypt/live}"
RENEW_HOOK="${BD_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/back-deploy-reload.sh}"
DS_STREAM_CONF="/etc/nginx/stream.d/dns-setup-relay.conf"
SNI_ROUTES_DIR="${BD_SNI_ROUTES_DIR:-/etc/nginx/sni-routes.d}"
FRONT_SITES_DIR="${BD_FRONT_SITES_DIR:-/etc/front-deploy/sites}"
FRONT_UPDATE_BIN="${BD_FRONT_UPDATE_BIN:-/usr/local/bin/front-update}"
UPDATE_BIN="${BD_UPDATE_BIN:-/usr/local/bin/back-update}"
UPDATE_URL="${BD_UPDATE_URL:-https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/back-update.sh}"

PORT_FIRST=3100 # blue = even port, green = the next one
PORT_LAST=3998

SITE_VARS=(SITE_NAME SITE_DOMAIN SITE_PATH SITE_STRIP SITE_WWW SITE_REPO SITE_BRANCH SITE_KEY SITE_APP_DIR
  SITE_INSTALL_CMD SITE_BUILD_CMD SITE_START_CMD SITE_RELEASE_CMD
  SITE_HEALTH_PATH SITE_HEALTH_TIMEOUT SITE_DATA_DIRS SITE_PRUNE SITE_NODE
  SITE_NPM_REGISTRY SITE_PORT SITE_MAX_BODY SITE_EMAIL SITE_STAGING
  SITE_TLS_PORT SITE_KEEP SITE_ACTIVE SITE_UPSTREAM_HOST SITE_CREATED)
for _v in "${SITE_VARS[@]}"; do
  printf -v "$_v" '%s' ''
done
unset _v

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
DOMAIN=""
NAME=""       # the app's key: the domain, or <domain>+<path> under a frontend
MOUNT_PATH="" # /api when the backend lives under a front-deploy.sh site
OPT_PATH=""
OPT_STRIP=""
OPT_REPO=""
OPT_BRANCH=""
OPT_APP_DIR=""
OPT_BUILD_CMD=""
OPT_INSTALL_CMD=""
OPT_START_CMD=""
OPT_RELEASE_CMD=""
OPT_HEALTH_PATH=""
OPT_HEALTH_TIMEOUT=""
OPT_DATA_DIRS=""
OPT_PRUNE=""
OPT_NODE=""
OPT_ENV_FILE=""
OPT_REGISTRY=""
OPT_PORT=""
OPT_MAX_BODY=""
OPT_EMAIL=""
OPT_TLS_PORT=""
OPT_KEEP=""
NO_WWW=0
SKIP_DNS=0
OPEN_FIREWALL=0
SWAP=1
STAGING=0

EXISTING=0
REMOTE_HEAD=""
REPO_HOST=""
REPO_PATH=""
PUBLIC_IPV4=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
back-deploy.sh -- deploy a Node.js backend (Express, Nest, Fastify, ...) from
its git repository behind nginx with a Let's Encrypt certificate, run by
systemd, updated without downtime.

Usage:
  sudo bash back-deploy.sh [options]      (asks for the domain and the repository)

Where it is served (asked when there are front-deploy.sh sites here):
  on its own subdomain (api.example.com, its own certificate), or under a path
  of a front-deploy.sh site (example.com/api: same domain and certificate as
  the frontend, no CORS):
      --path <path>         under a path of the frontend, e.g. /api (with
                            several frontends also pass the domain with -d)
      --strip-path          the app's routes start at / (app.get("/users")):
                            nginx turns /api/users into /users
      --no-strip-path       the app's routes include the path
                            (app.get("/api/users")); the default

Repository and build:
      --repo <url>         git repository (https://github.com/me/api or
                            git@github.com:me/api.git)
      --branch <name>       branch to deploy (default: the repository's default)
      --app-dir <dir>       folder of the app inside the repository
                            (default: the root, or the only one with package.json)
      --install-cmd <cmd>   dependency install (default: from the lockfile)
      --build-cmd <cmd>     build command (default: the "build" script if there
                            is one; "none" skips it)
      --node <major>        Node.js major, e.g. 22 (default: .nvmrc, engines, 24)
      --npm-registry <url>  npm registry, e.g. https://registry.npmmirror.com
                            (default: registry.npmjs.org, a mirror when blocked)
      --prune-dev           remove devDependencies from the releases (npm, pnpm)

Running:
      --start-cmd <cmd>     start command, run in the app folder (default: the
                            "start:prod" / "start" script, else node <main>)
      --release-cmd <cmd>   runs once per new release before it gets traffic,
                            e.g. "npx prisma migrate deploy"
      --env-file <path>     the app's .env (DATABASE_URL, secrets, ...)
      --data-dir <dir>      folder the app writes to, e.g. uploads (repeatable);
                            kept across releases in /var/lib/back-deploy/<app>
      --health-path <path>  URL the deploy waits for, any answer below 500
                            counts (default: /)
      --health-timeout <s>  how long to wait for it (default: 60)
      --port <n>            first of the two local ports (default: free pair
                            from 3100)

Web:
  -e, --email <address>     Let's Encrypt account email (default: none)
      --max-body <MB>       nginx upload limit in MB (default: 50)
      --no-www              do not serve www.<domain>, even when it points here
      --keep <n>            releases kept for rollback (default: 5)
      --tls-port <n>        loopback HTTPS port when dns-setup.sh owns :443
                            (default: 10445)
      --skip-dns-check      do not verify that the domain points to this server
      --open-firewall       open 80 and 443 in ufw / firewalld
      --no-swap             do not add a 2 GB swap file on small servers
      --staging             Let's Encrypt staging CA (testing only)
  -h, --help                show this help

The app must listen on process.env.PORT. Re-running the script for a deployed
domain changes its settings and keeps the rest.

After the install:
  back-update               pull, build and switch to the latest commit
  back-update env           edit the .env and restart without downtime
  back-update logs -f       follow the app's log
  back-update rollback      back to the previous release
  back-update --help        everything else
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
  local pretty v
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported OS."
  # shellcheck disable=SC1091
  pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-unknown}}")
  if [[ ${pretty,,} != *ubuntu* && ${pretty,,} != *debian* ]]; then
    warn "This script targets Ubuntu/Debian; '${pretty}' is untested."
  fi
  say "OS: ${pretty}"
  # DynamicUser, StateDirectory and systemd-run --pipe
  v=$(systemctl --version 2> /dev/null | awk 'NR == 1 {print $2}') || v=""
  [[ $v =~ ^[0-9]+$ ]] || die "systemd is required."
  ((v >= 236)) || die "systemd ${v} is too old (236 or newer is needed; Ubuntu 18.04+ / Debian 10+)."
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

apt_update() {
  apt-get -o DPkg::Lock::Timeout=180 update -qq
}

apt_install() {
  command -v apt-get > /dev/null 2>&1 || die "apt-get is required to install: $*"
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$@"
}

ensure_packages() {
  local missing=() p
  for p in curl git openssl python3 rsync; do
    command -v "$p" > /dev/null 2>&1 || missing+=("$p")
  done
  command -v ssh-keygen > /dev/null 2>&1 || missing+=(openssh-client)
  command -v ss > /dev/null 2>&1 || missing+=(iproute2)
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
# App settings
# ---------------------------------------------------------------------------
save_site() {
  local f="${SITES_DIR}/${SITE_DOMAIN}.conf" tmp v
  install -d -m 700 "$BD_ETC" "$SITES_DIR"
  tmp=$(mktemp)
  {
    printf '# back-deploy app, written %s -- read by back-update\n' "$(date -Is)"
    for v in "${SITE_VARS[@]}"; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$tmp"
  install -m 600 "$tmp" "$f"
  rm -f "$tmp"
}

load_existing() {
  local f="${SITES_DIR}/${NAME}.conf"
  [[ -r $f ]] || return 0
  # shellcheck disable=SC1090
  . "$f"
  EXISTING=1
  say "${DOMAIN} is already deployed; updating its settings."
}

apply_options() {
  [[ -n $OPT_APP_DIR ]] && SITE_APP_DIR=$OPT_APP_DIR
  [[ -n $OPT_BUILD_CMD ]] && SITE_BUILD_CMD=$OPT_BUILD_CMD
  [[ -n $OPT_INSTALL_CMD ]] && SITE_INSTALL_CMD=$OPT_INSTALL_CMD
  [[ -n $OPT_START_CMD ]] && SITE_START_CMD=$OPT_START_CMD
  [[ -n $OPT_RELEASE_CMD ]] && SITE_RELEASE_CMD=$OPT_RELEASE_CMD
  [[ $OPT_RELEASE_CMD == none ]] && SITE_RELEASE_CMD=""
  [[ -n $OPT_HEALTH_PATH ]] && SITE_HEALTH_PATH=$OPT_HEALTH_PATH
  [[ -n $OPT_HEALTH_TIMEOUT ]] && SITE_HEALTH_TIMEOUT=$OPT_HEALTH_TIMEOUT
  [[ -n $OPT_DATA_DIRS ]] && SITE_DATA_DIRS=${OPT_DATA_DIRS# }
  [[ -n $OPT_PRUNE ]] && SITE_PRUNE=$OPT_PRUNE
  [[ -n $OPT_NODE ]] && SITE_NODE=$OPT_NODE
  [[ -n $OPT_REGISTRY ]] && SITE_NPM_REGISTRY=$OPT_REGISTRY
  [[ -n $OPT_PORT ]] && SITE_PORT=$OPT_PORT
  [[ -n $OPT_MAX_BODY ]] && SITE_MAX_BODY=$OPT_MAX_BODY
  [[ -n $OPT_EMAIL ]] && SITE_EMAIL=$OPT_EMAIL
  [[ -n $OPT_TLS_PORT ]] && SITE_TLS_PORT=$OPT_TLS_PORT
  [[ -n $OPT_KEEP ]] && SITE_KEEP=$OPT_KEEP
  SITE_NAME=$NAME
  SITE_DOMAIN=$DOMAIN
  SITE_PATH=$MOUNT_PATH
  SITE_STAGING=$STAGING
  : "${SITE_TLS_PORT:=10445}" "${SITE_KEEP:=5}" "${SITE_WWW:=0}" "${SITE_HEALTH_PATH:=/}" \
    "${SITE_HEALTH_TIMEOUT:=60}" "${SITE_MAX_BODY:=50}" "${SITE_PRUNE:=0}"
  [[ -n $SITE_CREATED ]] || SITE_CREATED=$(date -Is)

  is_port "$SITE_TLS_PORT" && ((SITE_TLS_PORT != 80 && SITE_TLS_PORT != 443)) \
    || die "Invalid --tls-port '${SITE_TLS_PORT}'."
  [[ $SITE_KEEP =~ ^[0-9]+$ ]] && ((SITE_KEEP >= 2)) || die "--keep must be 2 or more."
  [[ -z $SITE_NODE || $SITE_NODE =~ ^[0-9]{2}$ ]] || die "Invalid --node '${SITE_NODE}' (a major version, e.g. 22)."
  [[ $SITE_HEALTH_PATH == /* && $SITE_HEALTH_PATH != *[[:space:]]* ]] || die "--health-path must start with / (e.g. /health)."
  [[ $SITE_HEALTH_TIMEOUT =~ ^[0-9]+$ ]] && ((SITE_HEALTH_TIMEOUT >= 5)) || die "Invalid --health-timeout '${SITE_HEALTH_TIMEOUT}'."
  [[ $SITE_MAX_BODY =~ ^[0-9]+$ ]] && ((SITE_MAX_BODY > 0)) || die "Invalid --max-body '${SITE_MAX_BODY}'."
  if [[ -n $SITE_NPM_REGISTRY && ! $SITE_NPM_REGISTRY =~ ^https?://[^[:space:]]+$ ]]; then
    die "Invalid --npm-registry '${SITE_NPM_REGISTRY}'."
  fi
  [[ -z $SITE_APP_DIR || ($SITE_APP_DIR != /* && $SITE_APP_DIR != *..*) ]] \
    || die "The app folder must be inside the repository: '${SITE_APP_DIR}'."
  local d
  for d in $SITE_DATA_DIRS; do
    [[ $d =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $d != *..* && $d != node_modules* ]] \
      || die "Invalid --data-dir '${d}' (a folder inside the app, e.g. uploads)."
  done
}

# Two ports per app (blue / green), never shared with another app.
allocate_port() {
  local used=() f p
  for f in "$SITES_DIR"/*.conf; do
    [[ -f $f && $f != "${SITES_DIR}/${NAME}.conf" ]] || continue
    p=$(sed -n 's/^SITE_PORT=//p' "$f" | head -n 1)
    [[ $p =~ ^[0-9]+$ ]] && used+=("$p" "$((p + 1))")
  done
  if [[ -n $SITE_PORT ]]; then
    is_port "$SITE_PORT" && ((SITE_PORT >= 1024 && SITE_PORT < 65535)) || die "Invalid --port '${SITE_PORT}'."
    for p in "${used[@]}"; do
      if ((p == SITE_PORT || p == SITE_PORT + 1)); then
        die "Ports ${SITE_PORT}-$((SITE_PORT + 1)) overlap another app's; pick another --port."
      fi
    done
    return 0
  fi
  for ((p = PORT_FIRST; p <= PORT_LAST; p += 2)); do
    if [[ " ${used[*]} " == *" ${p} "* || " ${used[*]} " == *" $((p + 1)) "* ]]; then
      continue
    fi
    if port_in_use "$p" || port_in_use "$((p + 1))"; then
      continue
    fi
    SITE_PORT=$p
    return 0
  done
  die "No free port pair between ${PORT_FIRST} and ${PORT_LAST}; pass --port."
}

# ---------------------------------------------------------------------------
# Build user (same as back-update.sh)
# ---------------------------------------------------------------------------
ensure_build_user() {
  if ! id -u "$BUILD_USER" > /dev/null 2>&1; then
    useradd --system --user-group --home-dir "$BD_HOME" --shell /usr/sbin/nologin "$BUILD_USER" \
      || die "Could not create the ${BUILD_USER} user."
  fi
  install -d -m 750 -o "$BUILD_USER" -g "$BUILD_USER" "$BD_HOME"
  install -d -m 700 -o "$BUILD_USER" -g "$BUILD_USER" "${BD_HOME}/.ssh" "${BD_HOME}/keys"
}

as_builder() { # key-or-empty command...
  local key=$1 v env=(HOME="$BD_HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 GIT_TERMINAL_PROMPT=0)
  shift
  if [[ -n $key ]]; then
    env+=(GIT_SSH_COMMAND="ssh -i ${key} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${BD_HOME}/.ssh/known_hosts")
  fi
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [[ -n ${!v:-} ]]; then
      env+=("${v}=${!v}")
    fi
  done
  (cd "$BD_HOME" && runuser -u "$BUILD_USER" -- env -i "${env[@]}" "$@")
}

# ---------------------------------------------------------------------------
# Domain and pre-checks
# ---------------------------------------------------------------------------
app_name() { # domain [path] -- same as back-update.sh
  local p=${2-}
  p=${p#/}
  p=${p%/}
  if [[ -n $p ]]; then
    printf '%s+%s\n' "$1" "${p//\//-}"
  else
    printf '%s\n' "$1"
  fi
}

front_sites() {
  local f
  for f in "$FRONT_SITES_DIR"/*.conf; do
    [[ -f $f ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.conf}"
  done
}

# Where the backend is served: its own (sub)domain, or a path of a
# front-deploy.sh site (same domain and certificate, no CORS). Asked unless
# --domain / --path decide it.
resolve_target() {
  local mode="" fronts=() i ans
  mapfile -t fronts < <(front_sites)
  DOMAIN=$(normalize_domain "$DOMAIN")
  if [[ -n $OPT_PATH ]]; then
    mode=path
  elif [[ -n $DOMAIN ]]; then
    mode=own
    [[ -f ${FRONT_SITES_DIR}/${DOMAIN}.conf ]] && mode=path
  elif ((${#fronts[@]} == 0)); then
    mode=own
  else
    [[ -t 0 ]] || die "No domain given and no terminal to ask for one."
    printf 'Where should the backend be served?\n'
    printf '  1) on its own subdomain, e.g. api.example.com\n'
    printf '  2) under a path of a frontend on this server, e.g. %s/api\n' "${fronts[0]}"
    ask "Choice" "1"
    case $REPLY_VALUE in
      1) mode=own ;;
      2) mode=path ;;
      *) die "Invalid choice '${REPLY_VALUE}'." ;;
    esac
  fi

  if [[ $mode == own ]]; then
    if [[ -z $DOMAIN ]]; then
      [[ -t 0 ]] || die "No domain given and no terminal to ask for one."
      ask "Domain for the backend (e.g. api.example.com)"
      DOMAIN=$(normalize_domain "$REPLY_VALUE")
    fi
    if [[ -z $DOMAIN ]] || ! is_domain "$DOMAIN"; then
      die "Invalid domain '${DOMAIN}'. Use something like api.example.com."
    fi
    if [[ -f ${FRONT_SITES_DIR}/${DOMAIN}.conf ]]; then
      die "${DOMAIN} is a frontend (front-deploy.sh). Serve the backend under a path of it (--path /api), or give it its own subdomain."
    fi
    NAME=$DOMAIN
    return 0
  fi

  # --- under a path of a frontend ---
  ((${#fronts[@]} > 0)) || die "There is no front-deploy.sh site on this server to put the backend under; set the frontend up first."
  if [[ -z $DOMAIN ]]; then
    if ((${#fronts[@]} == 1)); then
      DOMAIN=${fronts[0]}
      say "Frontend: ${DOMAIN}"
    else
      [[ -t 0 ]] || die "There are several frontends (${fronts[*]}); pass --domain <one of them> with --path."
      printf 'Frontend sites:\n'
      for i in "${!fronts[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${fronts[i]}"
      done
      ask "Which one" "1"
      ans=$REPLY_VALUE
      if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#fronts[@]})); then
        DOMAIN=${fronts[ans - 1]}
      else
        DOMAIN=$(normalize_domain "$ans")
      fi
    fi
  fi
  [[ -f ${FRONT_SITES_DIR}/${DOMAIN}.conf ]] \
    || die "${DOMAIN} is not a front-deploy.sh site (sites: ${fronts[*]})."

  local p=$OPT_PATH
  if [[ -z $p ]]; then
    [[ -t 0 ]] || die "Pass --path (e.g. /api)."
    ask "Path for the backend on ${DOMAIN}" "/api"
    p=$REPLY_VALUE
  fi
  p="/${p#/}"
  p=${p%/}
  [[ $p =~ ^(/[A-Za-z0-9._-]+)+$ && $p != *..* ]] || die "Invalid path '${p}' (something like /api)."
  case $p in
    /assets | /assets/* | /static | /static/* | /.well-known* | /index.html)
      die "${p} is used by the frontend itself; pick another path (e.g. /api)."
      ;;
  esac
  if [[ ! -x $FRONT_UPDATE_BIN ]] || ! grep -q 'front-deploy.d' "$FRONT_UPDATE_BIN"; then
    die "${FRONT_UPDATE_BIN} is missing or too old for backends under a path. Re-run the current front-deploy.sh for ${DOMAIN} first."
  fi
  MOUNT_PATH=$p
  NAME=$(app_name "$DOMAIN" "$p")
}

# Does the app expect /api/users or /users? Asked once, then kept.
resolve_strip() {
  local ans
  [[ -n $MOUNT_PATH ]] || return 0
  if [[ -n $OPT_STRIP ]]; then
    SITE_STRIP=$OPT_STRIP
  elif [[ -z $SITE_STRIP && -t 0 ]]; then
    printf 'How are the routes written in the app?\n'
    printf '  1) with the path:    app.get("%s/users")  -> requests are passed on as they are\n' "$MOUNT_PATH"
    printf '  2) without the path: app.get("/users")      -> nginx strips %s\n' "$MOUNT_PATH"
    ask "Choice" "1"
    ans=$REPLY_VALUE
    case $ans in
      1) SITE_STRIP=0 ;;
      2) SITE_STRIP=1 ;;
      *) die "Invalid choice '${ans}'." ;;
    esac
  fi
  : "${SITE_STRIP:=0}"
}

precheck_disk() {
  local avail
  avail=$(df -Pk / 2> /dev/null | awk 'NR == 2 {print $4}') || true
  if [[ $avail =~ ^[0-9]+$ ]] && ((avail < 2097152)); then
    die "At least 2 GB of free disk space is required for Node.js, node_modules and the releases (found $((avail / 1024)) MB)."
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
      die "${d} is already used by ${owner}. Give the backend its own subdomain (e.g. api.example.com)."
    fi
  done
  if [[ -f ${FRONT_SITES_DIR}/${DOMAIN}.conf ]]; then
    die "${DOMAIN} is a front-deploy.sh site. Give the backend its own subdomain (e.g. api.${DOMAIN#www.})."
  fi
  if [[ $SITE_WWW == 1 && -f ${FRONT_SITES_DIR}/www.${DOMAIN}.conf ]]; then
    warn "www.${DOMAIN} is a front-deploy.sh site; ${DOMAIN} is served without the www redirect."
    SITE_WWW=0
  fi
  if [[ $DOMAIN == www.* ]] && grep -qsx 'SITE_WWW=1' "${FRONT_SITES_DIR}/${DOMAIN#www.}.conf" "${SITES_DIR}/${DOMAIN#www.}.conf"; then
    die "${DOMAIN} is already the www redirect of ${DOMAIN#www.}. Re-run its setup with --no-www first."
  fi
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
    say "dns-setup.sh owns TCP/443; the app goes behind its SNI relay (127.0.0.1:${SITE_TLS_PORT})."
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

# npm installs and TypeScript builds easily need 1-2 GB; small VPSes get
# hit by the OOM killer without some swap.
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
# Repository
# ---------------------------------------------------------------------------
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

resolve_repo() {
  local src=$OPT_REPO
  if [[ -z $src ]]; then
    [[ -t 0 ]] || die "No repository given (--repo) and no terminal to ask for one."
    printf 'Git repository of the backend, e.g. https://github.com/me/api\n'
    ask "Repository" "$SITE_REPO"
    src=$REPLY_VALUE
  fi
  src=${src#"${src%%[![:space:]]*}"}
  src=${src%"${src##*[![:space:]]}"}
  [[ -n $src ]] || die "No repository given."
  # github.com/me/api -> https://github.com/me/api
  if [[ $src != *://* && $src != *@*:* && $src =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}/ ]]; then
    src="https://${src}"
  fi
  parse_repo_url "$src" || die "'$(mask_url "$src")' is not a git repository URL."
  if [[ -n $SITE_REPO && $SITE_REPO != "$src" ]] && ! same_repo "$SITE_REPO" "$src"; then
    say "The repository changed; the next build starts from a fresh clone."
    rm -rf "${APPS_ROOT}/${NAME}/repo" "${APPS_ROOT}/${NAME}/staging" "${APPS_ROOT}/${NAME}/meta/deps.hash"
    [[ -n $OPT_APP_DIR ]] || SITE_APP_DIR=""
    [[ -n $OPT_START_CMD ]] || SITE_START_CMD=""
    SITE_BRANCH=""
  fi
  parse_repo_url "$src"
  SITE_REPO=$src
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
  local key="${BD_HOME}/keys/${NAME}" candidates=() c ans shown=0
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
  if [[ $REPO_HOST == github.com || $REPO_HOST == ssh.github.com ]]; then
    # for servers where outgoing port 22 is blocked
    candidates+=("ssh://git@ssh.github.com:443/${REPO_PATH}.git")
  fi

  if [[ ! -s $key ]]; then
    as_builder "" ssh-keygen -q -t ed25519 -N '' -C "back-deploy@${DOMAIN}" -f "$key" \
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
  local def=${OPT_BRANCH:-${SITE_BRANCH:-${REMOTE_HEAD:-main}}} out
  if [[ -n $OPT_BRANCH || ! -t 0 ]]; then
    SITE_BRANCH=$def
  else
    ask "Branch" "$def"
    SITE_BRANCH=$REPLY_VALUE
  fi
  [[ $SITE_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid branch '${SITE_BRANCH}'."
  out=$(as_builder "$SITE_KEY" timeout 60 git ls-remote --heads -- "$SITE_REPO" "refs/heads/${SITE_BRANCH}" 2> /dev/null) || true
  [[ -n $out ]] || die "Branch '${SITE_BRANCH}' does not exist in the repository."
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
# The .env is read by systemd (root), never by the app user.
prepare_app_dirs() {
  local root="${APPS_ROOT}/${NAME}" env_src=$OPT_ENV_FILE
  install -d -m 755 "$APPS_ROOT" "$root" "${root}/releases" "${root}/meta" "${root}/slots"
  install -d -m 700 "${root}/shared"
  if [[ -z $env_src && ! -s ${root}/shared/.env && -t 0 ]]; then
    printf 'The app'"'"'s .env (DATABASE_URL, secrets, ...): path to a file on this server,\n'
    printf 'or Enter to skip and add it later with: back-update env\n'
    ask ".env file" ""
    env_src=${REPLY_VALUE/#\~/$HOME}
  fi
  if [[ -n $env_src ]]; then
    [[ -r $env_src ]] || die "Cannot read the .env file ${env_src}."
    install -m 600 "$env_src" "${root}/shared/.env"
    say "App env copied to ${root}/shared/.env"
  fi
}

# back-update.sh next to this script, else from the repository of these scripts
install_update_tool() {
  local src dir tmp
  src=$(readlink -f "$0" 2> /dev/null || printf '%s' "$0")
  dir=$(dirname "$src")
  tmp=$(mktemp)
  if [[ -f ${dir}/back-update.sh && $src != /proc/* && $src != /dev/* ]]; then
    cp "${dir}/back-update.sh" "$tmp"
  else
    say "Downloading back-update.sh ..."
    if ! curl -fsSL --max-time 60 -o "$tmp" "$UPDATE_URL"; then
      rm -f "$tmp"
      die "Could not download ${UPDATE_URL}. Put back-update.sh next to this script and re-run."
    fi
  fi
  if ! grep -q 'back-update.sh -- ' "$tmp" || ! bash -n "$tmp" 2> /dev/null; then
    rm -f "$tmp"
    die "back-update.sh is damaged or incomplete."
  fi
  install -m 755 "$tmp" "$UPDATE_BIN"
  rm -f "$tmp"
  say "Installed ${UPDATE_BIN}."
}

first_deploy() {
  BD_NO_LOG=1 "$UPDATE_BIN" --site "$NAME" --force \
    || die "The first deploy failed (output above). Fix it, then run: back-update"
}

# ---------------------------------------------------------------------------
# nginx and certificate
# ---------------------------------------------------------------------------
render_nginx() {
  BD_NO_LOG=1 "$UPDATE_BIN" nginx --site "$NAME" || die "Could not set up nginx for ${NAME}."
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
# Added by back-deploy.sh: reload nginx after a certificate renewal.
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
  VERIFY_URL="https://${DOMAIN}${SITE_HEALTH_PATH}"
  [[ -z $MOUNT_PATH ]] || VERIFY_URL="https://${DOMAIN}${MOUNT_PATH}/"
  code=$(curl "${args[@]}" "$VERIFY_URL" 2> /dev/null) || code=000
  HTTPS_CODE=$code
  [[ $code =~ ^[1-4][0-9][0-9]$ ]]
}

print_summary() {
  local root="${APPS_ROOT}/${NAME}" expires live
  # back-update saved what it detected (app folder, start command, instance)
  # shellcheck disable=SC1090
  . "${SITES_DIR}/${NAME}.conf"
  expires=$(openssl x509 -in "${TLS_DIR}/${DOMAIN}/fullchain.pem" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires=""
  live=$(readlink "${root}/current" 2> /dev/null) || live=""
  printf '\n'
  printf '==============================================================\n'
  printf ' %s%s is live\n' "$DOMAIN" "$MOUNT_PATH"
  printf '==============================================================\n'
  printf ' URL         : https://%s%s/\n' "$DOMAIN" "$MOUNT_PATH"
  if [[ -n $MOUNT_PATH ]]; then
    printf ' Mounted     : under the front-deploy site %s; ' "$DOMAIN"
    if [[ $SITE_STRIP == 1 ]]; then
      printf '%s/users reaches the app as /users\n' "$MOUNT_PATH"
    else
      printf 'the app sees the full path (%s/users)\n' "$MOUNT_PATH"
    fi
    printf ' In React    : fetch("%s/users") -- same origin, no CORS needed\n' "$MOUNT_PATH"
  fi
  if [[ $SITE_WWW == 1 ]]; then
    printf ' www         : https://www.%s/ redirects to it\n' "$DOMAIN"
  fi
  printf ' Repository  : %s (%s)\n' "$(mask_url "$SITE_REPO")" "$SITE_BRANCH"
  if [[ -n $SITE_KEY ]]; then
    printf ' Deploy key  : %s.pub (read-only)\n' "$SITE_KEY"
  fi
  printf ' Start       : %s (in %s)\n' "$SITE_START_CMD" "${SITE_APP_DIR:-.}"
  if [[ -n $SITE_RELEASE_CMD ]]; then
    printf ' Per release : %s\n' "$SITE_RELEASE_CMD"
  fi
  printf ' Release     : %s\n' "${live##*/}"
  printf ' Instances   : bd-*@blue on %s, bd-*@green on %s (live: %s)\n' "$SITE_PORT" "$((SITE_PORT + 1))" "$SITE_ACTIVE"
  printf ' Env         : %s/shared/.env%s\n' "$root" "$([[ -s ${root}/shared/.env ]] || printf ' (none yet)')"
  if [[ -n $SITE_DATA_DIRS ]]; then
    printf ' Data        : /var/lib/back-deploy/... (%s), kept across releases\n' "$SITE_DATA_DIRS"
  fi
  printf ' Certificate : expires %s, renews automatically\n' "${expires:-unknown}"
  if [[ -z $MOUNT_PATH ]] && relay_active; then
    printf ' HTTPS       : 127.0.0.1:%s, reached through the dns-setup.sh relay on :443\n' "$SITE_TLS_PORT"
  fi
  printf '%s\n' '--------------------------------------------------------------'
  printf ' The app gets PORT from systemd; behind nginx, Express needs\n'
  printf ' app.set("trust proxy", 1) for the real client IP.\n'
  printf '%s\n' '--------------------------------------------------------------'
  printf ' After a push     : back-update\n'
  printf ' Edit the .env    : back-update env\n'
  printf ' Logs             : back-update logs -f\n'
  printf ' Status           : back-update status\n'
  printf ' Previous release : back-update rollback\n'
  printf ' Another backend  : run this script again with the other domain\n'
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
        OPT_REPO="$2"
        shift 2
        ;;
      --path)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_PATH="$2"
        shift 2
        ;;
      --strip-path)
        OPT_STRIP=1
        shift
        ;;
      --no-strip-path)
        OPT_STRIP=0
        shift
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
      --start-cmd)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_START_CMD="$2"
        shift 2
        ;;
      --release-cmd)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_RELEASE_CMD="$2"
        shift 2
        ;;
      --health-path)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_HEALTH_PATH="$2"
        shift 2
        ;;
      --health-timeout)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_HEALTH_TIMEOUT="$2"
        shift 2
        ;;
      --data-dir)
        (($# >= 2)) || die "Option $1 needs a value."
        local d
        for d in ${2//,/ }; do
          d=${d#./}
          OPT_DATA_DIRS+=" ${d%/}"
        done
        shift 2
        ;;
      --prune-dev)
        OPT_PRUNE=1
        shift
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
      --port)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_PORT="$2"
        shift 2
        ;;
      --max-body)
        (($# >= 2)) || die "Option $1 needs a value."
        OPT_MAX_BODY="$2"
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
  resolve_target
  setup_logging
  trap '_on_err $LINENO' ERR

  say "=== back-deploy ${SCRIPT_VERSION}: Node.js backend + systemd + nginx + Let's Encrypt ==="
  load_os
  ensure_packages
  say "app    : https://${DOMAIN}${MOUNT_PATH}/"
  load_existing
  resolve_strip
  apply_options
  precheck_disk
  if [[ -z $MOUNT_PATH ]]; then
    precheck_dns
    precheck_domain_free
    precheck_ports
  else
    SITE_WWW=0 # the front-deploy site owns the domain, www and certificate
  fi
  allocate_port
  ensure_nginx
  [[ $OPEN_FIREWALL -eq 1 ]] && open_firewall_rules
  warn_closed_firewall

  # --- 1. repository ------------------------------------------------------
  ensure_build_user
  resolve_repo
  ensure_repo_access
  resolve_branch
  ensure_swap
  prepare_app_dirs
  save_site
  install_update_tool

  # --- 2. first deploy: build, start, wait until it answers ---------------
  first_deploy

  if [[ -n $MOUNT_PATH ]]; then
    # --- 3. locations inside the frontend's server blocks -----------------
    render_nginx
    FD_NO_LOG=1 "$FRONT_UPDATE_BIN" nginx --site "$DOMAIN" \
      || die "Could not update the nginx site of ${DOMAIN} (front-update nginx)."
  else
    # --- 3. nginx: port 80 first, needed for the ACME challenge -----------
    render_nginx

    # --- 4. certificate ---------------------------------------------------
    obtain_certificate || die "Could not obtain a certificate for ${DOMAIN}. The app is served over http:// until you re-run this script."
    install_renew_hook
    render_nginx
  fi

  # --- 5. check -----------------------------------------------------------
  if verify_https; then
    say "HTTPS check OK: ${VERIFY_URL} (HTTP ${HTTPS_CODE})"
  else
    warn "${VERIFY_URL} answered HTTP ${HTTPS_CODE} through nginx; check: back-update status"
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
