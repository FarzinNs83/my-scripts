#!/usr/bin/env bash
# =============================================================================
#  back-update.sh -- rebuild and restart a Node.js (Express) backend set up by
#                    back-deploy.sh, without downtime
#
#  What it does (for each app)
#    1. pulls the latest commit of the app's branch (shallow, as the
#       unprivileged "backdeploy" user, with the app's deploy key if any)
#    2. stops right there when the live release already has that commit and
#       the same settings (--force rebuilds anyway)
#    3. installs the Node.js major the project asks for (.nvmrc,
#       .node-version, engines.node; default 24) under /opt/back-deploy/node,
#       the dependencies with npm / pnpm / yarn (skipped when the lockfile did
#       not change), and runs the "build" script when there is one (TypeScript)
#    4. copies the result into /srv/back-deploy/<domain>/releases
#       (unchanged files are hard links to the previous release)
#    5. blue/green: every app has two systemd instances on two ports. The new
#       release starts on the idle one; only when it answers HTTP does nginx
#       switch to it, then the old instance stops. A release that crashes or
#       never answers gets no traffic and the live one keeps running
#
#  The app runs as its own systemd DynamicUser. It gets PORT (and the
#  variables of /srv/back-deploy/<domain>/shared/.env) in its environment;
#  folders it writes to (uploads, ...) are kept outside the releases.
#
#  Usage:
#    back-update                     (asks which app when there are several)
#    back-update --all
#    back-update rollback
#    back-update env                 edit the .env, then restart without downtime
#    back-update logs -f
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C

SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Paths (shared with back-deploy.sh; overridable from the environment)
# ---------------------------------------------------------------------------
BD_ETC="${BD_ETC:-/etc/back-deploy}"
SITES_DIR="${BD_ETC}/apps"
APPS_ROOT="${BD_APPS_ROOT:-/srv/back-deploy}"
BD_HOME="${BD_HOME:-/var/lib/back-deploy-build}" # build user's home: keys, caches
STATE_ROOT="${BD_STATE_ROOT:-/var/lib/back-deploy}" # apps' data (systemd StateDirectory)
NODE_ROOT="${BD_NODE_ROOT:-/opt/back-deploy/node}"
BUILD_USER="${BD_BUILD_USER:-backdeploy}"
LOG_FILE="${BD_LOG_FILE:-/var/log/back-deploy.log}"
NGINX_DIR="${BD_NGINX_DIR:-/etc/nginx/conf.d}"
UNIT_DIR="${BD_UNIT_DIR:-/etc/systemd/system}"
ACME_ROOT="${BD_ACME_ROOT:-/var/www/back-deploy-acme}"
TLS_DIR="${BD_TLS_DIR:-/etc/letsencrypt/live}"
DS_STREAM_CONF="/etc/nginx/stream.d/dns-setup-relay.conf"     # dns-setup.sh owns :443
SNI_ROUTES_DIR="${BD_SNI_ROUTES_DIR:-/etc/nginx/sni-routes.d}" # included by its SNI map
LOCK_DIR="${BD_LOCK_DIR:-/run/lock}"

DEFAULT_NODE=24
DRAIN_SECONDS=10 # the old instance finishes its requests before it stops
NODE_MIRRORS=(https://nodejs.org/dist https://npmmirror.com/mirrors/node)
NPM_REGISTRY_FALLBACK="https://registry.npmmirror.com"

# Everything back-deploy.sh stores per app in ${SITES_DIR}/<domain>.conf
SITE_VARS=(SITE_DOMAIN SITE_WWW SITE_REPO SITE_BRANCH SITE_KEY SITE_APP_DIR
  SITE_INSTALL_CMD SITE_BUILD_CMD SITE_START_CMD SITE_RELEASE_CMD
  SITE_HEALTH_PATH SITE_HEALTH_TIMEOUT SITE_DATA_DIRS SITE_PRUNE SITE_NODE
  SITE_NPM_REGISTRY SITE_PORT SITE_MAX_BODY SITE_EMAIL SITE_STAGING
  SITE_TLS_PORT SITE_KEEP SITE_ACTIVE SITE_UPSTREAM_HOST SITE_CREATED)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
SITE_ARG=""
ALL=0
FORCE=0
CLEAN=0
NEW_BRANCH=""
ROLLBACK_TO=""
NO_RELOAD=0
YES=0
PURGE=0
FOLLOW=0

REGISTRY=""
NODE_DIR=""
NODE_MAJOR=""
COMMIT=""
COMMIT_MSG=""
RELEASE=""
PICKED=()

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
back-update.sh -- rebuild and restart a Node.js backend set up by
back-deploy.sh, without downtime (blue/green behind nginx).

Usage:
  back-update [options]         pull, build, start the new release next to the
                                old one, switch nginx when it answers, stop the
                                old one (asks which app when there are several)
  back-update restart           restart the live release without downtime
                                (after editing the .env by hand)
  back-update env               edit the .env, then restart
  back-update rollback [--to <release>]
                                back to the previous release
  back-update status            instances, ports, health, certificate
  back-update logs [-f]         last 200 log lines (-f to follow)
  back-update list              apps, sources and live releases
  back-update nginx             re-render the nginx sites (dns-setup.sh runs it)
  back-update remove [--purge]  delete an app (--purge also deletes its data)

Options:
      --site <name>       the app to work on instead of being asked
      --all               every app, one after the other
      --force             rebuild even when the commit did not change
      --clean             delete node_modules first (fresh dependency install)
      --branch <name>     switch the app to another branch (saved)
  -h, --help              show this help

The app must listen on process.env.PORT. Runtime variables go in
/srv/back-deploy/<app>/shared/.env (read by systemd, not by the app user);
after editing it run back-update restart, or use back-update env.
EOF
}

# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------
_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] back-update failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}

require_root() {
  if [[ ${EUID} -eq 0 ]]; then
    return 0
  fi
  if command -v sudo > /dev/null 2>&1 && [[ -f $0 ]]; then
    exec sudo -E bash "$(readlink -f "$0")" "$@"
  fi
  die "This script must be run as root."
}

# back-deploy.sh already logs the whole run when it calls this script
setup_logging() {
  [[ ${BD_NO_LOG:-0} == 1 ]] && return 0
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

normalize_domain() {
  local d=$1
  d=${d#*://}
  d=${d%%/*}
  d=${d%%:*}
  d=${d%.}
  printf '%s\n' "$d" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

mask_url() {
  printf '%s\n' "$1" | sed -E 's#(://)[^/@]+@#\1***@#'
}

svc_active() {
  systemctl is-active --quiet "$1" 2> /dev/null
}

ipv6_enabled() {
  [[ -f /proc/net/if_inet6 ]]
}

port_in_use() {
  ss -ltn 2> /dev/null | awk -v p=":${1}" '$4 ~ p"$" {found=1} END {exit !found}'
}

port_holder() {
  ss -ltnp 2> /dev/null | awk -v p=":${1}$" '$4 ~ p && !found {print; found=1}'
}

# Short name for systemd units, the app user and nginx variables.
site_id() { # domain
  local id=${1//./-}
  if ((${#id} > 26)); then
    id="${id:0:19}-$(printf '%s' "$1" | sha256sum | cut -c1-6)"
  fi
  printf '%s\n' "$id"
}

# ---------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------
site_names() {
  local f
  for f in "$SITES_DIR"/*.conf; do
    [[ -f $f ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.conf}"
  done
}

load_site() {
  local d=$1 f="${SITES_DIR}/$1.conf" v
  [[ -r $f ]] || die "No app ${d} (${f} is missing). Set it up with back-deploy.sh."
  for v in "${SITE_VARS[@]}"; do
    printf -v "$v" '%s' ''
  done
  # shellcheck disable=SC1090
  . "$f"
  [[ $SITE_DOMAIN == "$d" ]] || die "${f} is damaged (SITE_DOMAIN='${SITE_DOMAIN}')."
  [[ $SITE_PORT =~ ^[0-9]+$ ]] || die "${f} has no valid SITE_PORT; re-run back-deploy.sh."
  : "${SITE_WWW:=0}" "${SITE_STAGING:=0}" "${SITE_TLS_PORT:=10445}" "${SITE_KEEP:=5}" \
    "${SITE_HEALTH_PATH:=/}" "${SITE_HEALTH_TIMEOUT:=60}" "${SITE_MAX_BODY:=50}" \
    "${SITE_PRUNE:=0}" "${SITE_UPSTREAM_HOST:=127.0.0.1}"
  SITE_ID=$(site_id "$SITE_DOMAIN")
  UNIT="bd-${SITE_ID}"
  APP_USER="bd-${SITE_ID}"
  UNIT_FILE="${UNIT_DIR}/${UNIT}@.service"
  SITE_ROOT="${APPS_ROOT}/${SITE_DOMAIN}"
  REPO_DIR="${SITE_ROOT}/repo"
  STAGE_DIR="${SITE_ROOT}/staging"
  RELEASES_DIR="${SITE_ROOT}/releases"
  META_DIR="${SITE_ROOT}/meta"
  SLOTS_DIR="${SITE_ROOT}/slots"
  ENV_FILE="${SITE_ROOT}/shared/.env"
  ENV_SYSTEMD="${SITE_ROOT}/shared/env.systemd"
  STATE_DIR="${STATE_ROOT}/${SITE_ID}"
  NGINX_CONF="${NGINX_DIR}/back-deploy-${SITE_DOMAIN}.conf"
  SNI_MAP="${SNI_ROUTES_DIR}/back-deploy-${SITE_DOMAIN}.map"
  CERT_FULLCHAIN="${TLS_DIR}/${SITE_DOMAIN}/fullchain.pem"
  CERT_PRIVKEY="${TLS_DIR}/${SITE_DOMAIN}/privkey.pem"
}

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

# one deploy per app at a time (fd 9 stays open until the next app / exit)
lock_site() {
  install -d -m 755 "$LOCK_DIR"
  exec 9> "${LOCK_DIR}/back-deploy-${SITE_DOMAIN}.lock"
  flock -n 9 || die "Another deploy of ${SITE_DOMAIN} is running."
}

# One build at a time across all apps, so a small VPS does not run out of
# memory. Waits instead of failing.
lock_builds() {
  exec 8> "${LOCK_DIR}/back-deploy-build.lock"
  if ! flock -n 8; then
    say "Another app is building; waiting for it to finish ..."
    flock 8
  fi
}

# Fills PICKED: --all, --site, the only app, or a menu.
pick_sites() { # allow_all
  local allow_all=$1 names=() i ans
  PICKED=()
  mapfile -t names < <(site_names)
  ((${#names[@]} > 0)) || die "No apps yet. Set one up with back-deploy.sh first."
  if [[ $ALL -eq 1 ]]; then
    ((allow_all)) || die "--all does not work with this command."
    PICKED=("${names[@]}")
    return 0
  fi
  if [[ -n $SITE_ARG ]]; then
    SITE_ARG=$(normalize_domain "$SITE_ARG")
    [[ -f ${SITES_DIR}/${SITE_ARG}.conf ]] || die "No app '${SITE_ARG}'. Apps: ${names[*]}"
    PICKED=("$SITE_ARG")
    return 0
  fi
  if ((${#names[@]} == 1)); then
    PICKED=("${names[0]}")
    return 0
  fi
  if [[ ! -t 0 ]]; then
    if ((allow_all)); then
      die "There are several apps (${names[*]}); pass --site <name> or --all."
    fi
    die "There are several apps (${names[*]}); pass --site <name>."
  fi
  printf 'Apps:\n'
  for i in "${!names[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${names[i]}"
  done
  ((allow_all)) && printf '  a) all of them\n'
  printf 'Which one? [1]: '
  read -r ans || die "No input."
  ans=${ans:-1}
  if ((allow_all)) && [[ $ans == a || $ans == all ]]; then
    PICKED=("${names[@]}")
    return 0
  fi
  [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#names[@]})) || die "Invalid choice '${ans}'."
  PICKED=("${names[ans - 1]}")
}

# ---------------------------------------------------------------------------
# Build user
# ---------------------------------------------------------------------------
# Dependencies and build scripts run as this user, never as root.
ensure_build_user() {
  if ! id -u "$BUILD_USER" > /dev/null 2>&1; then
    useradd --system --user-group --home-dir "$BD_HOME" --shell /usr/sbin/nologin "$BUILD_USER" \
      || die "Could not create the ${BUILD_USER} user."
  fi
  install -d -m 750 -o "$BUILD_USER" -g "$BUILD_USER" "$BD_HOME"
  install -d -m 700 -o "$BUILD_USER" -g "$BUILD_USER" "${BD_HOME}/.ssh" "${BD_HOME}/keys"
}

builder_env() {
  local v
  BENV=(
    HOME="$BD_HOME"
    PATH="${NODE_DIR:+${NODE_DIR}/bin:}/usr/local/bin:/usr/bin:/bin"
    LANG=C.UTF-8
    LC_ALL=C.UTF-8
    GIT_TERMINAL_PROMPT=0
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    COREPACK_ENABLE_STRICT=0
    npm_config_update_notifier=false
    npm_config_fund=false
    npm_config_audit=false
  )
  if [[ -n $REGISTRY ]]; then
    BENV+=(npm_config_registry="$REGISTRY" COREPACK_NPM_REGISTRY="$REGISTRY"
      YARN_REGISTRY="$REGISTRY" YARN_NPM_REGISTRY_SERVER="$REGISTRY")
  fi
  if [[ -n $SITE_KEY ]]; then
    BENV+=(GIT_SSH_COMMAND="ssh -i ${SITE_KEY} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${BD_HOME}/.ssh/known_hosts")
  fi
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [[ -n ${!v:-} ]]; then
      BENV+=("${v}=${!v}")
    fi
  done
}

as_builder() {
  builder_env
  (cd "$BD_HOME" && runuser -u "$BUILD_USER" -- env -i "${BENV[@]}" "$@")
}

run_in() { # dir command-string
  as_builder bash -c 'cd -- "$1" && eval "$2"' _ "$1" "$2"
}

# ---------------------------------------------------------------------------
# Node.js
# ---------------------------------------------------------------------------
node_arch() {
  case $(uname -m) in
    x86_64 | amd64) printf 'x64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    armv7l) printf 'armv7l\n' ;;
    ppc64le) printf 'ppc64le\n' ;;
    s390x) printf 's390x\n' ;;
    *) die "No Node.js build for this CPU: $(uname -m)" ;;
  esac
}

# Official tarballs, one folder per version, so apps can use different
# majors. An installed major is reused; nothing is downloaded on later runs.
ensure_node() { # major
  local major=$1 arch mirror ver file tmp sum
  NODE_DIR="${NODE_ROOT}/${major}"
  if [[ -x ${NODE_DIR}/bin/node ]]; then
    return 0
  fi
  arch=$(node_arch)
  install -d -m 755 "$NODE_ROOT"
  for mirror in "${NODE_MIRRORS[@]}"; do
    ver=$(curl -fsSL --max-time 30 "${mirror}/index.json" 2> /dev/null | python3 -c '
import json, sys
major, arch = sys.argv[1], sys.argv[2]
for r in json.load(sys.stdin):
    if r["version"].startswith("v%s." % major) and ("linux-%s" % arch) in r.get("files", []):
        print(r["version"])
        break
' "$major" "$arch" 2> /dev/null) || ver=""
    if [[ -z $ver ]]; then
      warn "Could not find Node.js ${major} for linux-${arch} on ${mirror}."
      continue
    fi
    file="node-${ver}-linux-${arch}.tar.gz"
    tmp=$(mktemp -d)
    say "Downloading Node.js ${ver} from ${mirror} ..."
    sum=""
    if curl -fsSL --max-time 900 -o "${tmp}/${file}" "${mirror}/${ver}/${file}" \
      && curl -fsSL --max-time 60 -o "${tmp}/SHASUMS256.txt" "${mirror}/${ver}/SHASUMS256.txt" \
      && sum=$(awk -v f="$file" '$2 == f {print $1}' "${tmp}/SHASUMS256.txt") && [[ -n $sum ]] \
      && [[ $(sha256sum "${tmp}/${file}" | awk '{print $1}') == "$sum" ]]; then
      rm -rf "${NODE_ROOT:?}/${ver}"
      install -d -m 755 "${NODE_ROOT}/${ver}"
      tar -xzf "${tmp}/${file}" -C "${NODE_ROOT}/${ver}" --strip-components=1 --no-same-owner
      rm -rf "$tmp"
      ln -sfn "$ver" "$NODE_DIR"
      say "Node.js ${ver} installed in ${NODE_ROOT}/${ver}."
      return 0
    fi
    rm -rf "$tmp"
    warn "Downloading Node.js from ${mirror} failed."
  done
  die "Could not install Node.js ${major}. Check the network, or pin another major with back-deploy.sh --node."
}

# pnpm and yarn run through corepack (it reads "packageManager" from
# package.json). Node 25+ no longer ships it.
ensure_corepack() {
  if [[ -x ${NODE_DIR}/bin/corepack ]]; then
    return 0
  fi
  say "Installing corepack (runs pnpm / yarn) ..."
  local e=(PATH="${NODE_DIR}/bin:/usr/local/bin:/usr/bin:/bin" npm_config_update_notifier=false)
  [[ -n $REGISTRY ]] && e+=(npm_config_registry="$REGISTRY")
  env "${e[@]}" npm install -g --no-fund --no-audit corepack > /dev/null \
    || die "Could not install corepack."
}

# The registry for this run: the app's own, else npmjs, else a mirror.
pick_registry() {
  REGISTRY=$SITE_NPM_REGISTRY
  if [[ -n $REGISTRY ]]; then
    return 0
  fi
  if curl -fsS -o /dev/null --max-time 10 https://registry.npmjs.org/-/ping 2> /dev/null; then
    return 0
  fi
  REGISTRY=$NPM_REGISTRY_FALLBACK
  warn "registry.npmjs.org is unreachable; using ${REGISTRY} (pin one with back-deploy.sh --npm-registry)."
}

# ---------------------------------------------------------------------------
# Repository and build
# ---------------------------------------------------------------------------
git_sync() {
  local br=$SITE_BRANCH
  if [[ -d ${REPO_DIR}/.git ]]; then
    if [[ $(stat -c %U "$REPO_DIR") != "$BUILD_USER" ]]; then
      chown -R "${BUILD_USER}:${BUILD_USER}" "$REPO_DIR"
    fi
    say "Fetching ${br} from $(mask_url "$SITE_REPO") ..."
    as_builder git -C "$REPO_DIR" remote set-url origin "$SITE_REPO"
    as_builder timeout 600 git -C "$REPO_DIR" fetch -q --depth 1 origin "$br" \
      || die "git fetch failed (deploy key removed? branch '${br}' deleted? network?)."
    as_builder git -C "$REPO_DIR" checkout -q -f -B "$br" FETCH_HEAD
    as_builder git -C "$REPO_DIR" clean -fdq
  else
    rm -rf "$REPO_DIR"
    install -d -m 750 -o "$BUILD_USER" -g "$BUILD_USER" "$REPO_DIR"
    say "Cloning $(mask_url "$SITE_REPO") (${br}) ..."
    as_builder timeout 900 git clone -q --depth 1 --single-branch --branch "$br" -- "$SITE_REPO" "$REPO_DIR" \
      || die "git clone failed (repository access? branch '${br}'? network?)."
  fi
  if [[ -f ${REPO_DIR}/.gitmodules ]]; then
    as_builder timeout 600 git -C "$REPO_DIR" submodule update -q --init --recursive --depth 1 \
      || warn "Updating the git submodules failed; building without them."
  fi
  COMMIT=$(as_builder git -C "$REPO_DIR" rev-parse --short=10 HEAD)
  COMMIT_MSG=$(as_builder git -C "$REPO_DIR" log -1 --format=%s | cut -c1-70)
}

# The folder with the backend's package.json: the repository root, or the
# one sub-folder that has one (monorepo); asked once and saved.
choose_app_dir() {
  local c=() f i ans
  if [[ -n $SITE_APP_DIR ]]; then
    return 0
  fi
  if [[ -f ${REPO_DIR}/package.json ]]; then
    SITE_APP_DIR=.
    save_site
    return 0
  fi
  while IFS= read -r f; do
    c+=("$f")
  done < <(cd "$REPO_DIR" && find . -mindepth 2 -maxdepth 3 -name package.json \
    -not -path '*/node_modules/*' -not -path './.git/*' -printf '%h\n' | sed 's|^\./||' | sort)
  ((${#c[@]} > 0)) || die "The repository has no package.json; is this a Node.js app?"
  if ((${#c[@]} == 1)); then
    SITE_APP_DIR=${c[0]}
    say "App found in ${SITE_APP_DIR}/"
  else
    [[ -t 0 ]] || die "Several package.json files (${c[*]}); set the folder with back-deploy.sh --app-dir."
    printf 'Which folder is the backend?\n'
    for i in "${!c[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${c[i]}"
    done
    printf 'Choice [1]: '
    read -r ans || die "No input."
    ans=${ans:-1}
    [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#c[@]})) || die "Invalid choice '${ans}'."
    SITE_APP_DIR=${c[ans - 1]}
  fi
  save_site
}

pkg_json_info() { # package.json
  python3 - "$1" "$DEFAULT_NODE" << 'PY'
import json, re, sys
path, default = sys.argv[1], int(sys.argv[2])
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as e:
    print("ERROR=%s" % str(e).replace("\n", " "))
    sys.exit(0)
def one_line(s):
    return str(s).replace("\n", " ").strip()
scripts = d.get("scripts") if isinstance(d.get("scripts"), dict) else {}
print("HAS_BUILD=%d" % (1 if "build" in scripts else 0))
pm = str(d.get("packageManager") or "").split("@")[0]
print("PM=%s" % (pm if pm in ("npm", "pnpm", "yarn", "bun") else ""))
# watch-mode dev servers are no start command for production
dev = re.compile(r"\b(nodemon|ts-node-dev|node-dev)\b|--watch|\bnest start\b(?!.*--prod)")
for key in ("start:prod", "start:production", "prod", "start"):
    s = scripts.get(key)
    if isinstance(s, str) and s.strip() and not dev.search(s):
        print("START=%s" % one_line(s))
        break
main = d.get("main")
if isinstance(main, str) and main.strip():
    print("MAIN=%s" % one_line(main))
engines = d.get("engines") if isinstance(d.get("engines"), dict) else {}
best = None
for alt in str(engines.get("node") or "").split("||"):
    alt = alt.strip()
    m = re.search(r"\d+", alt)
    if not m:
        continue
    major = int(m.group())
    if alt.startswith(">") and "<" not in alt:
        major = max(major, default)  # ">=18": a current LTS satisfies it
    best = major if best is None else max(best, major)
if best:
    print("NODE=%d" % best)
PY
}

read_package_json() { # app dir
  local k v
  PKG_HAS_BUILD=0 PKG_PM="" PKG_NODE="" PKG_START="" PKG_MAIN=""
  while IFS='=' read -r k v; do
    case $k in
      ERROR) die "Cannot read ${1}/package.json: ${v}" ;;
      HAS_BUILD) PKG_HAS_BUILD=$v ;;
      PM) PKG_PM=$v ;;
      NODE) PKG_NODE=$v ;;
      START) PKG_START=$v ;;
      MAIN) PKG_MAIN=$v ;;
    esac
  done < <(pkg_json_info "${1}/package.json")
}

# --node from back-deploy.sh, else .nvmrc / .node-version, else engines.node
pick_node_major() {
  local f v
  if [[ -n $SITE_NODE ]]; then
    NODE_MAJOR=$SITE_NODE
    return 0
  fi
  for f in "${APP}/.nvmrc" "${APP}/.node-version" "${REPO_DIR}/.nvmrc" "${REPO_DIR}/.node-version"; do
    [[ -r $f ]] || continue
    v=$(head -n 1 "$f" | tr -d '[:space:]')
    v=${v#v}
    if [[ $v =~ ^([0-9]+) ]]; then
      NODE_MAJOR=${BASH_REMATCH[1]}
    else
      NODE_MAJOR=$DEFAULT_NODE # lts/*, node, ...
    fi
    return 0
  done
  NODE_MAJOR=${PKG_NODE:-$DEFAULT_NODE}
}

# Package manager from the lockfile, looked up from the app folder towards
# the repository root (workspaces keep one lockfile at the root).
detect_pm() {
  local dir=$APP lock=""
  INSTALL_DIR=$APP
  while :; do
    for lock in pnpm-lock.yaml yarn.lock package-lock.json npm-shrinkwrap.json bun.lock bun.lockb; do
      if [[ -f ${dir}/${lock} ]]; then
        INSTALL_DIR=$dir
        break 2
      fi
    done
    lock=""
    [[ $dir != "$REPO_DIR" && $dir == "$REPO_DIR"/* ]] || break
    dir=$(dirname "$dir")
  done

  case $lock in
    pnpm-lock.yaml) PM=pnpm ;;
    yarn.lock) PM=yarn ;;
    package-lock.json | npm-shrinkwrap.json) PM=npm ;;
    bun.lock | bun.lockb)
      warn "bun is not supported; installing with npm instead."
      PM=npm
      ;;
    *) PM=${PKG_PM:-npm} ;;
  esac
  [[ $PM == bun ]] && PM=npm

  INSTALL_FALLBACK=""
  PRUNE_CMD=""
  case $PM in
    pnpm)
      INSTALL_CMD="corepack pnpm install --frozen-lockfile"
      INSTALL_FALLBACK="corepack pnpm install --no-frozen-lockfile"
      BUILD_CMD="corepack pnpm run build"
      PRUNE_CMD="corepack pnpm prune --prod"
      ;;
    yarn)
      if [[ -f ${INSTALL_DIR}/.yarnrc.yml ]]; then
        INSTALL_CMD="corepack yarn install --immutable"
      else
        INSTALL_CMD="corepack yarn install --frozen-lockfile --non-interactive"
      fi
      INSTALL_FALLBACK="corepack yarn install"
      BUILD_CMD="corepack yarn run build"
      ;;
    *)
      if [[ $lock == package-lock.json || $lock == npm-shrinkwrap.json ]]; then
        INSTALL_CMD="npm ci"
        INSTALL_FALLBACK="npm install"
      else
        INSTALL_CMD="npm install"
      fi
      BUILD_CMD="npm run build"
      PRUNE_CMD="npm prune --omit=dev"
      ;;
  esac
  if [[ -z $lock && -n $INSTALL_FALLBACK ]]; then
    INSTALL_CMD=$INSTALL_FALLBACK # nothing to freeze
    INSTALL_FALLBACK=""
  fi
  [[ $PKG_HAS_BUILD == 1 ]] || BUILD_CMD=""
  if [[ -n $SITE_INSTALL_CMD ]]; then
    INSTALL_CMD=$SITE_INSTALL_CMD
    INSTALL_FALLBACK=""
  fi
  case $SITE_BUILD_CMD in
    "") ;;
    none) BUILD_CMD="" ;;
    *) BUILD_CMD=$SITE_BUILD_CMD ;;
  esac
  # the folder the app runs from, relative to the install root
  APP_REL=${APP#"$INSTALL_DIR"}
  APP_REL=${APP_REL#/}
}

deps_hash() {
  {
    printf '%s|%s\n' "$NODE_MAJOR" "$INSTALL_CMD"
    cat "${INSTALL_DIR}"/{pnpm-lock.yaml,yarn.lock,package-lock.json,npm-shrinkwrap.json} 2> /dev/null || true
    find "$INSTALL_DIR" -maxdepth 3 -name package.json -not -path '*/node_modules/*' -print0 | sort -z | xargs -0r cat
  } | sha256sum | cut -c1-32
}

install_deps() {
  local h stamp="${META_DIR}/deps.hash"
  h=$(deps_hash)
  if [[ $CLEAN -eq 0 && -f $stamp && $(cat "$stamp") == "$h" ]] \
    && [[ -d ${INSTALL_DIR}/node_modules || -f ${INSTALL_DIR}/.pnp.cjs ]]; then
    say "Dependencies did not change; skipping the install."
    return 0
  fi
  rm -f "$stamp"
  say "Installing dependencies: ${INSTALL_CMD}"
  if ! run_in "$INSTALL_DIR" "$INSTALL_CMD"; then
    [[ -n $INSTALL_FALLBACK ]] || die "Installing the dependencies failed (output above)."
    warn "'${INSTALL_CMD}' failed (lockfile out of date?); retrying with '${INSTALL_FALLBACK}' ..."
    run_in "$INSTALL_DIR" "$INSTALL_FALLBACK" || die "Installing the dependencies failed (output above)."
  fi
  printf '%s\n' "$h" > "$stamp"
}

build_app() {
  if [[ -z $BUILD_CMD ]]; then
    say "No build script; running the sources as they are."
    return 0
  fi
  say "Building: ${BUILD_CMD}"
  run_in "$APP" "$BUILD_CMD" || die "The build failed (output above); the live release keeps running."
}

# First deploy: the start command from package.json (start:prod, start), else
# "node <main>", else a usual entry file; asked to confirm, then saved.
choose_start_cmd() {
  local guess="" f ans
  if [[ -n $SITE_START_CMD ]]; then
    return 0
  fi
  if [[ -n $PKG_START ]]; then
    guess=$PKG_START
  elif [[ -n $PKG_MAIN && -f ${APP}/${PKG_MAIN} ]]; then
    guess="node ${PKG_MAIN}"
  else
    for f in dist/main.js dist/index.js dist/server.js dist/app.js build/index.js build/server.js \
      server.js index.js app.js src/server.js src/index.js src/app.js; do
      if [[ -f ${APP}/${f} ]]; then
        guess="node ${f}"
        break
      fi
    done
  fi
  if [[ -t 0 ]]; then
    printf 'Start command, run in %s/ [%s]: ' "$SITE_APP_DIR" "${guess:-none found}"
    read -r ans || ans=""
    guess=${ans:-$guess}
  fi
  [[ -n $guess ]] || die "No start command found (no \"start\" script, no index.js / server.js). Set one with back-deploy.sh --start-cmd."
  SITE_START_CMD=$guess
  save_site
  say "Start command: ${SITE_START_CMD} (saved; change it with back-deploy.sh --start-cmd)"
}

build_signature() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$COMMIT" "$NODE_MAJOR" "$INSTALL_CMD" "$BUILD_CMD" \
    "$SITE_START_CMD" "$SITE_RELEASE_CMD" "$SITE_APP_DIR" "$SITE_PRUNE" "$SITE_DATA_DIRS"
}

# ---------------------------------------------------------------------------
# Releases
# ---------------------------------------------------------------------------
current_release() {
  local t
  t=$(readlink "${SITE_ROOT}/current" 2> /dev/null) || return 1
  printf '%s\n' "${t##*/}"
}

release_list() {
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '*.tmp' -printf '%f\n' 2> /dev/null | sort
}

release_with_sig() { # signature -> newest kept release built with it
  local r
  while IFS= read -r r; do
    if [[ -f ${META_DIR}/${r}.sig && $(cat "${META_DIR}/${r}.sig") == "$1" ]]; then
      printf '%s\n' "$r"
      return 0
    fi
  done < <(release_list | sort -r)
  return 1
}

meta_get() { # release key
  sed -n "s/^${2}=//p" "${META_DIR}/${1}.info" 2> /dev/null | head -n 1
}

prune_releases() {
  local cur all=() n i
  cur=$(current_release || true)
  mapfile -t all < <(release_list)
  n=${#all[@]}
  ((n > SITE_KEEP)) || return 0
  for ((i = 0; i < n - SITE_KEEP; i++)); do
    [[ ${all[i]} == "$cur" ]] && continue
    rm -rf "${RELEASES_DIR:?}/${all[i]}" "${META_DIR}/${all[i]}".{sig,info}
  done
}

# repo -> staging (with node_modules, optionally pruned) -> releases/<name>.
# Unchanged files are hard links to the live release.
make_release() { # signature
  local sig=$1 name rel prev d link=()
  install -d -m 750 -o "$BUILD_USER" -g "$BUILD_USER" "$STAGE_DIR"
  say "Staging the release ..."
  as_builder rsync -a --delete --exclude=.git "${INSTALL_DIR}/" "${STAGE_DIR}/" \
    || die "Copying the build to ${STAGE_DIR} failed."
  if [[ $SITE_PRUNE == 1 ]]; then
    if [[ -n $PRUNE_CMD ]]; then
      say "Removing devDependencies: ${PRUNE_CMD}"
      run_in "$STAGE_DIR" "$PRUNE_CMD" || die "Pruning the devDependencies failed."
    else
      warn "--prune-dev is not supported with ${PM}; keeping all dependencies."
    fi
  fi

  install -d -m 755 "$RELEASES_DIR" "$META_DIR"
  while :; do
    name="$(date +%Y%m%d-%H%M%S)-${COMMIT}"
    rel="${RELEASES_DIR}/${name}"
    [[ -e $rel ]] || break
    sleep 1
  done
  prev=$(current_release || true)
  if [[ -n $prev && -d ${RELEASES_DIR}/${prev} ]]; then
    link=(--link-dest="${RELEASES_DIR}/${prev}")
  fi
  rm -rf "${rel}.tmp"
  rsync -rlptD --delete --chmod=u=rwX,go=rX ${link[@]+"${link[@]}"} "${STAGE_DIR}/" "${rel}.tmp/" \
    || die "Creating the release failed."
  chmod 755 "${rel}.tmp"

  # data folders live in the app's state directory, not in the release
  for d in $SITE_DATA_DIRS; do
    rm -rf "${rel}.tmp/${APP_REL:+${APP_REL}/}${d}"
    install -d -m 755 "$(dirname "${rel}.tmp/${APP_REL:+${APP_REL}/}${d}")"
    ln -s "${STATE_DIR}/${d}" "${rel}.tmp/${APP_REL:+${APP_REL}/}${d}"
  done
  mv "${rel}.tmp" "$rel"
  printf '%s\n' "$sig" > "${META_DIR}/${name}.sig"
  {
    printf 'node=%s\n' "$NODE_MAJOR"
    printf 'app=%s\n' "$APP_REL"
    printf 'commit=%s\n' "$COMMIT"
    printf 'message=%s\n' "$COMMIT_MSG"
  } > "${META_DIR}/${name}.info"
  RELEASE=$name
}

# ---------------------------------------------------------------------------
# systemd: two instances per app, bd-<id>@blue and bd-<id>@green
# ---------------------------------------------------------------------------
other_color() {
  if [[ $1 == blue ]]; then
    printf 'green\n'
  else
    printf 'blue\n'
  fi
}

color_port() {
  if [[ $1 == blue ]]; then
    printf '%s\n' "$SITE_PORT"
  else
    printf '%s\n' "$((SITE_PORT + 1))"
  fi
}

state_dirs() {
  local d out="back-deploy/${SITE_ID}"
  for d in $SITE_DATA_DIRS; do
    out+=" back-deploy/${SITE_ID}/${d}"
  done
  printf '%s\n' "$out"
}

render_unit() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" << EOF
# Managed by back-deploy -- re-run back-deploy.sh instead of editing by hand
[Unit]
Description=${SITE_DOMAIN} (%i), deployed by back-deploy
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
DynamicUser=yes
User=${APP_USER}
StateDirectory=$(state_dirs)
Environment=NODE_ENV=production
Environment=HOME=${STATE_DIR}
Environment=npm_config_update_notifier=false
EnvironmentFile=-${ENV_SYSTEMD}
EnvironmentFile=${SLOTS_DIR}/%i.env
ExecStart=${SLOTS_DIR}/%i.sh
Restart=always
RestartSec=2
TimeoutStopSec=30
LimitNOFILE=65536
SyslogIdentifier=${UNIT}-%i
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF
  if ! cmp -s "$tmp" "$UNIT_FILE"; then
    install -m 644 "$tmp" "$UNIT_FILE"
    systemctl daemon-reload
  fi
  rm -f "$tmp"
}

# dotenv syntax -> systemd EnvironmentFile (quotes, "export", inline comments)
render_env() {
  install -d -m 700 "$(dirname "$ENV_FILE")"
  if [[ ! -s $ENV_FILE ]]; then
    : > "$ENV_SYSTEMD"
    chmod 600 "$ENV_SYSTEMD"
    return 0
  fi
  python3 - "$ENV_FILE" "$ENV_SYSTEMD" << 'PY' || die "Could not read ${ENV_FILE}."
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
out = []
key_re = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", re.S)
text = open(src, encoding="utf-8", errors="replace").read().replace("\r\n", "\n")
lines = text.split("\n")
i = 0
while i < len(lines):
    line = lines[i]
    i += 1
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    m = key_re.match(s)
    if not m:
        print("[!] .env line %d ignored: not KEY=value" % i, file=sys.stderr)
        continue
    key, val = m.group(1), m.group(2)
    if val[:1] in ("'", '"'):
        q = val[0]
        body = val[1:]
        while q not in body and i < len(lines):  # multi-line quoted value
            body += "\n" + lines[i]
            i += 1
        val = body.split(q, 1)[0]
        if q == '"':
            val = val.replace("\\n", "\n")
    else:
        val = re.split(r"\s+#", val, 1)[0].strip()
    if key == "PORT":
        print("[!] PORT in .env is ignored; back-deploy sets it per instance.", file=sys.stderr)
        continue
    # systemd takes \ " $ ` literally after a backslash inside double quotes,
    # and newlines inside them as part of the value
    out.append('%s="%s"' % (key, re.sub(r'([\\"$`])', r"\\\1", val)))
fd = os.open(dst + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write("# generated by back-update from .env -- edit .env instead\n")
    fh.write("\n".join(out) + "\n")
os.replace(dst + ".tmp", dst)
PY
}

write_slot() { # color release
  local color=$1 rel=$2 node app dir tmp
  node=$(meta_get "$rel" node)
  app=$(meta_get "$rel" app)
  node=${node:-$DEFAULT_NODE}
  [[ -x ${NODE_ROOT}/${node}/bin/node ]] || ensure_node "$node"
  dir="${RELEASES_DIR}/${rel}${app:+/${app}}"
  install -d -m 755 "$SLOTS_DIR"
  tmp=$(mktemp)
  {
    printf '#!/bin/sh\n'
    printf '# Managed by back-deploy: %s instance -> release %s\n' "$color" "$rel"
    printf "PATH='%s/node_modules/.bin:%s/%s/bin:/usr/local/bin:/usr/bin:/bin'\n" "$dir" "$NODE_ROOT" "$node"
    printf 'export PATH\n'
    printf "cd '%s' || exit 1\n" "$dir"
    if [[ $SITE_START_CMD == *[\;\&\|\<\>\`\$\(\)]* ]]; then
      printf '%s\n' "$SITE_START_CMD"
    else
      printf 'exec %s\n' "$SITE_START_CMD"
    fi
  } > "$tmp"
  install -m 755 "$tmp" "${SLOTS_DIR}/${color}.sh"
  printf 'PORT=%s\n' "$(color_port "$color")" > "$tmp"
  install -m 644 "$tmp" "${SLOTS_DIR}/${color}.env"
  rm -f "$tmp"
}

# Runs once per new release, before it gets traffic (e.g. database
# migrations), as the app user with the app's environment.
run_release_cmd() { # release
  local rel=$1 node app dir
  [[ -n $SITE_RELEASE_CMD ]] || return 0
  node=$(meta_get "$rel" node)
  app=$(meta_get "$rel" app)
  dir="${RELEASES_DIR}/${rel}${app:+/${app}}"
  say "Release command: ${SITE_RELEASE_CMD}"
  systemd-run --quiet --wait --pipe --collect \
    --unit="${UNIT}-release-$(date +%s)" \
    -p DynamicUser=yes -p User="$APP_USER" -p "StateDirectory=$(state_dirs)" \
    -p Environment=NODE_ENV=production -p "Environment=HOME=${STATE_DIR}" \
    -p "EnvironmentFile=-${ENV_SYSTEMD}" -p "WorkingDirectory=${dir}" \
    /bin/sh -c "PATH='${dir}/node_modules/.bin:${NODE_ROOT}/${node:-$DEFAULT_NODE}/bin:/usr/local/bin:/usr/bin:/bin'; export PATH; ${SITE_RELEASE_CMD}" < /dev/null \
    || die "The release command failed (output above); the live release keeps running."
}

restarts_of() {
  systemctl show -p NRestarts --value "$1" 2> /dev/null || printf '0\n'
}

# Healthy = any HTTP answer below 500 on the health path. Also learns whether
# the app listens on 127.0.0.1 or only on ::1 (listen("localhost") on Node 17+).
wait_healthy() { # instance port
  local inst=$1 port=$2 i code host n
  for ((i = 0; i < SITE_HEALTH_TIMEOUT; i++)); do
    for host in 127.0.0.1 '[::1]'; do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${host}:${port}${SITE_HEALTH_PATH}" 2> /dev/null) || code=000
      if [[ $code =~ ^[1-4][0-9][0-9]$ ]]; then
        UP_HOST=$host
        return 0
      fi
    done
    n=$(restarts_of "$inst")
    if [[ $n =~ ^[0-9]+$ ]] && ((n >= 3)); then
      warn "${inst} crashed ${n} times."
      return 1
    fi
    sleep 1
  done
  warn "${inst} did not answer on port ${port}${SITE_HEALTH_PATH} within ${SITE_HEALTH_TIMEOUT}s. Does the app listen on process.env.PORT?"
  return 1
}

# Starts <release> on the idle instance, waits until it answers, points nginx
# at it, then stops the old instance. Anything failing before the nginx
# switch leaves the live instance alone.
go_live() { # release run-release-cmd
  local rel=$1 with_cmd=$2 old=$SITE_ACTIVE idle port inst old_inst holder
  idle=$(other_color "${old:-green}")
  port=$(color_port "$idle")
  inst="${UNIT}@${idle}"

  render_unit
  render_env
  write_slot "$idle" "$rel"
  systemctl stop "$inst" > /dev/null 2>&1 || true
  systemctl reset-failed "$inst" > /dev/null 2>&1 || true
  if port_in_use "$port"; then
    holder=$(port_holder "$port") || true
    die "TCP/${port} is in use: ${holder:-unknown}. Pick other ports with back-deploy.sh --port."
  fi
  if [[ $with_cmd == 1 ]]; then
    run_release_cmd "$rel"
  fi

  say "Starting ${rel} on ${idle} (port ${port}) ..."
  systemctl start "$inst" || true
  if ! wait_healthy "$inst" "$port"; then
    journalctl -u "$inst" -n 40 --no-pager -o cat >&2 || true
    systemctl stop "$inst" > /dev/null 2>&1 || true
    if [[ -n $old ]]; then
      die "The new release did not start (log above). ${SITE_DOMAIN} keeps running the previous release."
    fi
    die "The app did not start (log above). Missing variables? Add them with 'back-update env' (it starts the app again), or fix the code and run back-update."
  fi
  say "${idle} answers on ${UP_HOST}:${port}."

  SITE_ACTIVE=$idle
  SITE_UPSTREAM_HOST=$UP_HOST
  save_site
  ln -sfn "releases/${rel}" "${SITE_ROOT}/current.new"
  mv -Tf "${SITE_ROOT}/current.new" "${SITE_ROOT}/current"
  if command -v nginx > /dev/null 2>&1 && [[ -f $NGINX_CONF ]]; then
    render_site_nginx
    apply_nginx 0
  fi
  systemctl enable "$inst" > /dev/null 2>&1 || true

  if [[ -n $old ]]; then
    old_inst="${UNIT}@${old}"
    systemctl disable "$old_inst" > /dev/null 2>&1 || true
    if svc_active "$old_inst"; then
      say "Stopping ${old} after ${DRAIN_SECONDS}s (it finishes its open requests) ..."
      sleep "$DRAIN_SECONDS"
      systemctl stop "$old_inst" || warn "Could not stop ${old_inst}."
    fi
  fi
  prune_releases
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
update_site() { # domain
  local started sig cur kept
  started=$(date +%s)
  load_site "$1"
  lock_site
  say "=== ${SITE_DOMAIN} ==="
  if [[ -n $NEW_BRANCH ]]; then
    SITE_BRANCH=$NEW_BRANCH
    save_site
    say "Branch switched to ${SITE_BRANCH} (saved)."
  fi
  [[ -n $SITE_REPO && -n $SITE_BRANCH ]] || die "${SITE_DOMAIN} has no repository; re-run back-deploy.sh."
  command -v rsync > /dev/null 2>&1 || die "rsync is missing; re-run back-deploy.sh."

  ensure_build_user
  install -d -m 755 "$META_DIR"
  git_sync
  choose_app_dir
  APP="${REPO_DIR}/${SITE_APP_DIR}"
  APP=${APP%/.}
  [[ -f ${APP}/package.json ]] || die "${SITE_APP_DIR}/package.json is missing in the repository."
  read_package_json "$APP"
  pick_node_major
  detect_pm

  if [[ -n $SITE_START_CMD ]]; then
    sig=$(build_signature)
    cur=$(current_release || true)
    if [[ $FORCE -eq 0 && -n $cur && -n $SITE_ACTIVE && -f ${META_DIR}/${cur}.sig \
      && $(cat "${META_DIR}/${cur}.sig") == "$sig" ]] && svc_active "${UNIT}@${SITE_ACTIVE}"; then
      say "Already live: ${COMMIT} \"${COMMIT_MSG}\". Nothing to do (--force rebuilds, restart restarts)."
      return 0
    fi
    # after a rollback: the build of this commit is still on disk
    if [[ $FORCE -eq 0 ]] && kept=$(release_with_sig "$sig"); then
      say "Commit ${COMMIT} was built before (release ${kept}); starting it again."
      go_live "$kept" 0
      say "Live: https://${SITE_DOMAIN}/ -> ${COMMIT} \"${COMMIT_MSG}\" ($(($(date +%s) - started))s)"
      return 0
    fi
  fi
  say "Commit: ${COMMIT} \"${COMMIT_MSG}\""

  lock_builds
  ensure_node "$NODE_MAJOR"
  say "Node.js $("${NODE_DIR}/bin/node" -v), ${PM}"
  pick_registry
  if [[ $CLEAN -eq 1 ]]; then
    say "Deleting node_modules (--clean) ..."
    rm -rf "${INSTALL_DIR}/node_modules" "${APP}/node_modules"
  fi
  [[ $PM == npm ]] || ensure_corepack
  install_deps
  build_app
  choose_start_cmd
  sig=$(build_signature)
  make_release "$sig"
  exec 8>&- # the build lock: starting the app needs no build slot
  go_live "$RELEASE" 1
  say "Live: https://${SITE_DOMAIN}/ -> ${COMMIT} \"${COMMIT_MSG}\" in $(($(date +%s) - started))s (release ${RELEASE})"
}

cmd_update() {
  local d self args=() ok=() failed=()
  pick_sites 1
  if ((${#PICKED[@]} == 1)); then
    update_site "${PICKED[0]}"
    return 0
  fi
  if [[ -n $NEW_BRANCH ]]; then
    die "--branch changes one app; pick it with --site."
  fi
  # each app in its own process, so one failing build does not stop the rest
  self=$(readlink -f "$0" 2> /dev/null || printf '%s' "$0")
  if [[ ! -f $self || $self == /proc/* || $self == /dev/* ]]; then
    for d in "${PICKED[@]}"; do
      update_site "$d" # piped run: stops at the first failure
    done
    return 0
  fi
  ((FORCE)) && args+=(--force)
  ((CLEAN)) && args+=(--clean)
  for d in "${PICKED[@]}"; do
    if BD_NO_LOG=1 bash "$self" --site "$d" ${args[@]+"${args[@]}"} < /dev/null; then
      ok+=("$d")
    else
      failed+=("$d")
    fi
    printf '\n'
  done
  say "Done: ${ok[*]:-none}"
  if ((${#failed[@]} > 0)); then
    die "Failed: ${failed[*]} (output above; those apps keep running their previous release)."
  fi
}

# Same release on the other instance: picks up a changed .env without downtime.
restart_site() {
  local cur
  # no live release yet (the first start failed): the newest build
  cur=$(current_release || release_list | tail -n 1)
  [[ -n $cur && -d ${RELEASES_DIR}/${cur} ]] || die "${SITE_DOMAIN} has no release yet; run back-update first."
  go_live "$cur" 0
  say "${SITE_DOMAIN} restarted (${cur}, now on ${SITE_ACTIVE})."
}

cmd_restart() {
  pick_sites 0
  load_site "${PICKED[0]}"
  lock_site
  restart_site
}

cmd_env() {
  local editor before after
  pick_sites 0
  load_site "${PICKED[0]}"
  [[ -t 0 ]] || die "back-update env needs a terminal; edit ${ENV_FILE}, then run back-update restart."
  lock_site
  install -d -m 700 "$(dirname "$ENV_FILE")"
  [[ -f $ENV_FILE ]] || install -m 600 /dev/null "$ENV_FILE"
  editor=${VISUAL:-${EDITOR:-}}
  if [[ -z $editor ]]; then
    for editor in nano vim vi; do
      command -v "$editor" > /dev/null 2>&1 && break
    done
  fi
  before=$(sha256sum "$ENV_FILE")
  "$editor" "$ENV_FILE" < /dev/tty > /dev/tty
  after=$(sha256sum "$ENV_FILE")
  if [[ $before == "$after" ]]; then
    say "No changes."
    return 0
  fi
  chmod 600 "$ENV_FILE"
  restart_site
}

cmd_rollback() {
  local all=() cur idx=-1 i target
  pick_sites 0
  load_site "${PICKED[0]}"
  lock_site
  mapfile -t all < <(release_list)
  cur=$(current_release || true)
  for i in "${!all[@]}"; do
    [[ ${all[i]} == "$cur" ]] && idx=$i
  done
  if [[ -n $ROLLBACK_TO ]]; then
    target=$ROLLBACK_TO
    [[ -d ${RELEASES_DIR}/${target} && $target != */* ]] \
      || die "No release '${target}'. Releases: ${all[*]:-none}"
  else
    ((idx > 0)) || die "No older release of ${SITE_DOMAIN} to roll back to (releases: ${all[*]:-none})."
    target=${all[idx - 1]}
  fi
  [[ $target != "$cur" ]] || die "${target} is already live."
  if [[ -n $SITE_RELEASE_CMD ]]; then
    warn "The release command (migrations) is not undone; the database stays as it is."
  fi
  go_live "$target" 0
  say "${SITE_DOMAIN}: ${cur:-none} -> ${target}"
  say "Plain 'back-update' brings the latest commit back."
}

health_of() { # port
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${SITE_UPSTREAM_HOST}:${1}${SITE_HEALTH_PATH}" 2> /dev/null) || code=000
  if [[ $code =~ ^[1-4][0-9][0-9]$ ]]; then
    printf 'OK (HTTP %s)\n' "$code"
  else
    printf 'FAIL (HTTP %s)\n' "$code"
  fi
}

cmd_status() {
  local d c inst state expires https
  pick_sites 0
  for d in "${PICKED[@]}"; do
    load_site "$d"
    expires=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2> /dev/null | sed -n 's/^notAfter=//p') || expires=""
    https=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${SITE_DOMAIN}:443:127.0.0.1" \
      "https://${SITE_DOMAIN}${SITE_HEALTH_PATH}" 2> /dev/null) || https=000
    printf 'App         : https://%s/\n' "$SITE_DOMAIN"
    printf 'Release     : %s (%s)\n' "$(current_release || printf none)" "$(meta_get "$(current_release || true)" message)"
    for c in blue green; do
      inst="${UNIT}@${c}"
      state=$(systemctl is-active "$inst" 2> /dev/null) || true
      printf '%-12s: %s, port %s%s%s\n' "$c" "${state:-inactive}" "$(color_port "$c")" \
        "$([[ $c == "$SITE_ACTIVE" ]] && printf ', live')" \
        "$([[ $state == active ]] && printf ', %s' "$(health_of "$(color_port "$c")")")"
    done
    printf 'HTTPS       : HTTP %s via nginx\n' "$https"
    printf 'Certificate : %s\n' "${expires:-missing}"
    printf 'Data        : %s\n' "$STATE_DIR"
    printf 'Env         : %s\n' "$ENV_FILE"
    printf 'Logs        : back-update logs --site %s\n' "$SITE_DOMAIN"
  done
}

cmd_logs() {
  pick_sites 0
  load_site "${PICKED[0]}"
  if [[ $FOLLOW -eq 1 ]]; then
    journalctl -u "${UNIT}@*" -n 200 -f --no-pager -o short-iso
  else
    journalctl -u "${UNIT}@*" -n 200 --no-pager -o short-iso
  fi
}

cmd_list() {
  local d cur n names=()
  mapfile -t names < <(site_names)
  if ((${#names[@]} == 0)); then
    say "No apps yet. Set one up with back-deploy.sh."
    return 0
  fi
  for d in "${names[@]}"; do
    load_site "$d"
    cur=$(current_release || printf 'none')
    n=$(release_list | wc -l)
    printf '%s\n' "https://${SITE_DOMAIN}/"
    printf '  source  : %s (%s)\n' "$(mask_url "$SITE_REPO")" "$SITE_BRANCH"
    printf '  live    : %s on %s, port %s (%s releases kept)\n' "$cur" "${SITE_ACTIVE:-none}" \
      "$(color_port "${SITE_ACTIVE:-blue}")" "$n"
    printf '  start   : %s (in %s)\n' "${SITE_START_CMD:-?}" "${SITE_APP_DIR:-?}"
    printf '  env     : %s%s\n' "$ENV_FILE" "$([[ -s $ENV_FILE ]] || printf ' (none)')"
    printf '  disk    : %s in %s\n' "$(du -sh "$SITE_ROOT" 2> /dev/null | cut -f1)" "$SITE_ROOT"
  done
}

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
relay_active() {
  [[ -f $DS_STREAM_CONF ]]
}

nginx_version_ge() { # x.y.z
  local v
  v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
  [[ -n $v ]] || return 1
  [[ $(printf '%s\n%s\n' "$1" "$v" | sort -V | head -n 1) == "$1" ]]
}

listen_mode() { # conf -> public | loopback | none
  if grep -Eqs '^[[:space:]]*listen[[:space:]]+443[[:space:];]' "$1"; then
    printf 'public\n'
  elif grep -Eqs '^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:[0-9]+[[:space:]]+ssl' "$1"; then
    printf 'loopback\n'
  else
    printf 'none\n'
  fi
}

cert_valid() {
  [[ -s $CERT_FULLCHAIN && -s $CERT_PRIVKEY ]] || return 1
  openssl x509 -in "$CERT_FULLCHAIN" -noout -checkend 86400 > /dev/null 2>&1 || return 1
  local san
  san=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -ext subjectAltName 2> /dev/null) || return 1
  [[ $san == *"DNS:${SITE_DOMAIN}"* ]] || return 1
  [[ $SITE_WWW != 1 || $san == *"DNS:www.${SITE_DOMAIN}"* ]]
}

tls_server_head() { # server_name
  if relay_active; then
    printf '    listen 127.0.0.1:%s ssl%s;\n' "$SITE_TLS_PORT" "$H2_LISTEN"
  else
    printf '    listen 443 ssl%s;\n' "$H2_LISTEN"
    if ipv6_enabled; then
      printf '    listen [::]:443 ssl%s;\n' "$H2_LISTEN"
    fi
  fi
  if [[ -n $H2_LINE ]]; then
    printf '%s\n' "$H2_LINE"
  fi
  printf '    server_name %s;\n\n' "$1"
  printf '    ssl_certificate     %s;\n' "$CERT_FULLCHAIN"
  printf '    ssl_certificate_key %s;\n' "$CERT_PRIVKEY"
  printf '    ssl_protocols TLSv1.2 TLSv1.3;\n'
  printf '    ssl_session_cache shared:back_deploy_ssl:10m;\n'
  printf '    ssl_session_timeout 1d;\n'
  printf '    add_header Strict-Transport-Security "max-age=31536000" always;\n'
}

# Proxy to the live instance: websockets, real client IP headers (use
# app.set("trust proxy", 1) in Express), long timeouts, upload limit.
proxy_body() {
  local up=$1 var=$2
  cat << EOF

    client_max_body_size ${SITE_MAX_BODY}m;

    location / {
        proxy_pass http://${up};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$${var};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_connect_timeout 10s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_next_upstream error timeout;
    }
EOF
}

sync_sni_route() { # http | https
  if [[ $1 == https ]] && relay_active; then
    install -d -m 755 "$SNI_ROUTES_DIR"
    {
      printf '# Managed by back-deploy -- SNI route for the dns-setup.sh relay\n'
      printf '"%s" 127.0.0.1:%s;\n' "$SITE_DOMAIN" "$SITE_TLS_PORT"
      if [[ $SITE_WWW == 1 ]]; then
        printf '"www.%s" 127.0.0.1:%s;\n' "$SITE_DOMAIN" "$SITE_TLS_PORT"
      fi
    } > "$SNI_MAP"
  else
    rm -f "$SNI_MAP"
  fi
}

# Without a certificate yet, port 80 proxies to the app (and answers the
# ACME challenge); with one, port 80 only redirects.
render_site_nginx() {
  local mode=http names=$SITE_DOMAIN up var port
  cert_valid && mode=https
  [[ $SITE_WWW == 1 ]] && names+=" www.${SITE_DOMAIN}"
  up="bd_${SITE_ID//-/_}"
  var="${up}_connection"
  port=$(color_port "${SITE_ACTIVE:-blue}")
  H2_LISTEN=""
  H2_LINE=""
  if nginx_version_ge 1.25.1; then
    H2_LINE='    http2 on;'
  else
    H2_LISTEN=' http2'
  fi
  install -d -m 755 "$NGINX_DIR" "${ACME_ROOT}/.well-known/acme-challenge"
  {
    printf '# Managed by back-deploy -- run "back-update nginx" instead of editing by hand\n'
    printf '# live instance: %s\n' "${SITE_ACTIVE:-none yet}"
    printf 'upstream %s {\n' "$up"
    if [[ $SITE_UPSTREAM_HOST == '[::1]' ]]; then
      printf '    server [::1]:%s;\n' "$port"
    else
      printf '    server 127.0.0.1:%s;\n' "$port"
    fi
    printf '    keepalive 16;\n'
    printf '}\n\n'
    printf 'map $http_upgrade $%s {\n' "$var"
    printf '    default upgrade;\n'
    printf "    ''      \"\";\n"
    printf '}\n\n'
    printf 'server {\n'
    printf '    listen 80;\n'
    if ipv6_enabled; then
      printf '    listen [::]:80;\n'
    fi
    printf '    server_name %s;\n\n' "$names"
    printf '    location ^~ /.well-known/acme-challenge/ {\n'
    printf '        root %s;\n' "$ACME_ROOT"
    printf '        default_type "text/plain";\n'
    printf '    }\n'
    if [[ $mode == https ]]; then
      printf '    location / {\n'
      printf '        return 301 https://%s$request_uri;\n' "$SITE_DOMAIN"
      printf '    }\n'
    else
      proxy_body "$up" "$var"
    fi
    printf '}\n'
    if [[ $mode == https ]]; then
      if [[ $SITE_WWW == 1 ]]; then
        printf '\nserver {\n'
        tls_server_head "www.${SITE_DOMAIN}"
        printf '\n    return 301 https://%s$request_uri;\n' "$SITE_DOMAIN"
        printf '}\n'
      fi
      printf '\nserver {\n'
      tls_server_head "$SITE_DOMAIN"
      proxy_body "$up" "$var"
      printf '}\n'
    fi
  } > "$NGINX_CONF"
  sync_sni_route "$mode"
}

apply_nginx() { # restart?
  local out
  if ! out=$(nginx -t 2>&1); then
    printf '%s\n' "$out" >&2
    die "nginx configuration test failed (see the output above)."
  fi
  systemctl enable nginx > /dev/null 2>&1 || true
  if svc_active nginx && [[ $1 -eq 0 ]]; then
    systemctl reload nginx || die "Could not reload nginx."
  else
    systemctl restart nginx || die "Could not start nginx."
  fi
}

# Renders every app (or --site) for the current :443 layout. dns-setup.sh
# calls this with --no-reload when its relay takes :443 over or gives it back.
cmd_nginx() {
  local names=() d before after restart=0
  command -v nginx > /dev/null 2>&1 || die "nginx is not installed."
  if [[ -n $SITE_ARG ]]; then
    pick_sites 0
    names=("${PICKED[@]}")
  else
    mapfile -t names < <(site_names)
  fi
  if ((${#names[@]} == 0)); then
    say "No back-deploy apps."
    return 0
  fi
  for d in "${names[@]}"; do
    load_site "$d"
    before=$(listen_mode "$NGINX_CONF")
    render_site_nginx
    after=$(listen_mode "$NGINX_CONF")
    # :443 moves between the http and stream modules: restart, not reload
    if [[ $before != none && $after != none && $before != "$after" ]]; then
      restart=1
    fi
    case $after in
      public) say "${d}: HTTPS on :443" ;;
      loopback) say "${d}: HTTPS on 127.0.0.1:${SITE_TLS_PORT} behind the dns-setup.sh relay" ;;
      *) say "${d}: HTTP only (no certificate yet)" ;;
    esac
  done
  if [[ $NO_RELOAD -eq 0 ]]; then
    apply_nginx "$restart"
  fi
}

cmd_remove() {
  local ans="" c
  pick_sites 0
  load_site "${PICKED[0]}"
  lock_site
  if [[ $YES -eq 0 ]]; then
    [[ -t 0 ]] || die "Pass --yes to remove ${SITE_DOMAIN} without a prompt."
    if [[ $PURGE -eq 1 ]]; then
      printf 'This deletes %s with its releases, .env, certificate AND its data in %s. Type "yes": ' "$SITE_DOMAIN" "$STATE_DIR"
    else
      printf 'This deletes %s: instances, nginx config, %s, certificate, deploy key (data in %s stays). Type "yes": ' \
        "$SITE_DOMAIN" "$SITE_ROOT" "$STATE_DIR"
    fi
    read -r ans || true
    [[ $ans == yes ]] || die "Aborted."
  fi
  for c in blue green; do
    systemctl disable --now "${UNIT}@${c}" > /dev/null 2>&1 || true
  done
  rm -f "$UNIT_FILE"
  systemctl daemon-reload || true
  rm -f "$NGINX_CONF" "$SNI_MAP"
  if command -v nginx > /dev/null 2>&1 && nginx -t > /dev/null 2>&1 && svc_active nginx; then
    systemctl reload nginx || true
  fi
  if command -v certbot > /dev/null 2>&1 && [[ -e /etc/letsencrypt/renewal/${SITE_DOMAIN}.conf ]]; then
    certbot delete --non-interactive --cert-name "$SITE_DOMAIN" > /dev/null 2>&1 \
      || warn "certbot could not delete the certificate; run: certbot delete --cert-name ${SITE_DOMAIN}"
  fi
  if [[ -n $SITE_KEY ]]; then
    rm -f "$SITE_KEY" "${SITE_KEY}.pub"
    say "Also delete the deploy key from the repository settings."
  fi
  rm -rf "${APPS_ROOT:?}/${SITE_DOMAIN:?}"
  rm -f "${SITES_DIR}/${SITE_DOMAIN}.conf" "${LOCK_DIR}/back-deploy-${SITE_DOMAIN}.lock"
  if [[ $PURGE -eq 1 ]]; then
    # with DynamicUser the data lives in /var/lib/private
    rm -rf "${STATE_ROOT:?}/${SITE_ID:?}" "/var/lib/private/back-deploy/${SITE_ID:?}"
    say "${SITE_DOMAIN} and its data removed."
  else
    say "${SITE_DOMAIN} removed; its data stays in ${STATE_DIR} (--purge deletes it)."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
parse_args() {
  while (($# > 0)); do
    case "$1" in
      --site)
        (($# >= 2)) || die "Option $1 needs a value."
        SITE_ARG="$2"
        shift 2
        ;;
      --all)
        ALL=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --clean)
        CLEAN=1
        FORCE=1
        shift
        ;;
      --branch)
        (($# >= 2)) || die "Option $1 needs a value."
        NEW_BRANCH="$2"
        shift 2
        ;;
      --to)
        (($# >= 2)) || die "Option $1 needs a value."
        ROLLBACK_TO="$2"
        shift 2
        ;;
      -f | --follow)
        FOLLOW=1
        shift
        ;;
      --no-reload)
        NO_RELOAD=1
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --purge)
        PURGE=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1 (try --help)."
        ;;
    esac
  done
  if [[ -n $NEW_BRANCH && ! $NEW_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]]; then
    die "Invalid branch '${NEW_BRANCH}'."
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
  local cmd=update
  case "${1-}" in
    update | restart | env | rollback | status | logs | list | nginx | remove)
      cmd=$1
      shift
      ;;
  esac
  parse_args "$@"
  if [[ $cmd != logs ]]; then
    setup_logging
  fi
  trap '_on_err $LINENO' ERR
  "cmd_${cmd}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
