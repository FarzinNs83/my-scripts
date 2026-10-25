#!/usr/bin/env bash
# =============================================================================
#  front-update.sh -- rebuild and republish a frontend set up by front-deploy.sh
#
#  What it does (for each site)
#    1. pulls the latest commit of the site's branch (shallow, as the
#       unprivileged "frontdeploy" user, with the site's deploy key if any)
#    2. stops right there when the live release already has that commit and
#       the same build settings (--force rebuilds anyway)
#    3. installs the Node.js major the project asks for (.nvmrc,
#       .node-version, engines.node; default 24) under /opt/front-deploy/node
#    4. installs dependencies with npm / pnpm / yarn (from the lockfile),
#       skipped when the lockfile did not change
#    5. builds into a new folder in /var/www/<domain>/releases and switches
#       the "current" symlink nginx serves in one atomic step. A failed build
#       never touches the live site; the last 5 releases are kept for rollback
#
#  Sites published from uploads (no repository) take a ready build instead:
#  a folder, .zip or .tar.gz with index.html at the top.
#
#  Usage:
#    front-update                      (asks which site when there are several)
#    front-update --all
#    front-update rollback
#    front-update list
#    front-update --dist /root/dist.zip
#
#  Options: --help
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C

SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Paths (shared with front-deploy.sh; overridable from the environment)
# ---------------------------------------------------------------------------
FD_ETC="${FD_ETC:-/etc/front-deploy}"
SITES_DIR="${FD_ETC}/sites"
WWW_ROOT="${FD_WWW_ROOT:-/var/www}"
FD_HOME="${FD_HOME:-/var/lib/front-deploy}" # build user's home: keys, caches
NODE_ROOT="${FD_NODE_ROOT:-/opt/front-deploy/node}"
BUILD_USER="${FD_BUILD_USER:-frontdeploy}"
LOG_FILE="${FD_LOG_FILE:-/var/log/front-deploy.log}"
NGINX_DIR="${FD_NGINX_DIR:-/etc/nginx/conf.d}"
ACME_ROOT="${FD_ACME_ROOT:-/var/www/front-deploy-acme}"
TLS_DIR="${FD_TLS_DIR:-/etc/letsencrypt/live}"
DS_STREAM_CONF="/etc/nginx/stream.d/dns-setup-relay.conf"     # dns-setup.sh owns :443
SNI_ROUTES_DIR="${FD_SNI_ROUTES_DIR:-/etc/nginx/sni-routes.d}" # included by its SNI map
FRONT_MOUNT_DIR="${FD_MOUNT_DIR:-/etc/nginx/front-deploy.d}"   # back-deploy.sh paths (/api)
LOCK_DIR="${FD_LOCK_DIR:-/run/lock}"

DEFAULT_NODE=24
NODE_MIRRORS=(https://nodejs.org/dist https://npmmirror.com/mirrors/node)
NPM_REGISTRY_FALLBACK="https://registry.npmmirror.com"

# Everything front-deploy.sh stores per site in ${SITES_DIR}/<domain>.conf
SITE_VARS=(SITE_DOMAIN SITE_WWW SITE_SOURCE SITE_REPO SITE_BRANCH SITE_KEY
  SITE_APP_DIR SITE_INSTALL_CMD SITE_BUILD_CMD SITE_BUILD_DIR SITE_NODE
  SITE_NPM_REGISTRY SITE_EMAIL SITE_STAGING SITE_TLS_PORT SITE_KEEP SITE_CREATED)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
SITE_ARG=""
ALL=0
FORCE=0
CLEAN=0
DIST=""
NEW_BRANCH=""
NEW_BUILD_DIR=""
ROLLBACK_TO=""
NO_RELOAD=0
YES=0

REGISTRY=""
NODE_DIR=""
NODE_MAJOR=""
COMMIT=""
COMMIT_MSG=""
STAGE_TMP=""
PICKED=()

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
front-update.sh -- rebuild and republish a frontend set up by front-deploy.sh.

Usage:
  front-update [options]        pull, build and publish (asks which site when
                                there are several)
  front-update rollback [--to <release>]
                                switch back to the previous release
  front-update list             sites, sources and live releases
  front-update nginx            re-render the nginx sites (dns-setup.sh runs it)
  front-update remove           delete a site: nginx config, files, certificate

Update options:
      --site <name>       the site to work on instead of being asked
      --all               every site, one after the other
      --force             rebuild even when the commit did not change
      --clean             delete node_modules first (fresh dependency install)
      --branch <name>     switch the site to another branch (saved)
      --build-dir <dir>   change the build output folder, e.g. dist (saved)
      --dist <path>       publish a ready build instead of building: a folder,
                          .zip or .tar.gz with index.html at the top
  -h, --help              show this help

Build-time variables (VITE_*, REACT_APP_*) go in /var/www/<site>/shared/.env;
it is copied to .env.production.local before each build. After editing it,
run front-update --force.
EOF
}

# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------
_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] front-update failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}

_cleanup() {
  if [[ -n $STAGE_TMP ]]; then
    rm -rf "$STAGE_TMP"
  fi
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

# front-deploy.sh already logs the whole run when it calls this script
setup_logging() {
  [[ ${FD_NO_LOG:-0} == 1 ]] && return 0
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

apt_install() {
  command -v apt-get > /dev/null 2>&1 || die "apt-get is required to install: $*"
  apt-get -o DPkg::Lock::Timeout=180 update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq "$@"
}

# ---------------------------------------------------------------------------
# Sites
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
  [[ -r $f ]] || die "No site ${d} (${f} is missing). Set it up with front-deploy.sh."
  for v in "${SITE_VARS[@]}"; do
    printf -v "$v" '%s' ''
  done
  # shellcheck disable=SC1090
  . "$f"
  [[ $SITE_DOMAIN == "$d" ]] || die "${f} is damaged (SITE_DOMAIN='${SITE_DOMAIN}')."
  : "${SITE_WWW:=0}" "${SITE_SOURCE:=git}" "${SITE_STAGING:=0}" "${SITE_TLS_PORT:=10444}" "${SITE_KEEP:=5}"
  SITE_ROOT="${WWW_ROOT}/${SITE_DOMAIN}"
  REPO_DIR="${SITE_ROOT}/repo"
  RELEASES_DIR="${SITE_ROOT}/releases"
  META_DIR="${SITE_ROOT}/meta"
  ENV_FILE="${SITE_ROOT}/shared/.env"
  NGINX_CONF="${NGINX_DIR}/front-deploy-${SITE_DOMAIN}.conf"
  SNI_MAP="${SNI_ROUTES_DIR}/front-deploy-${SITE_DOMAIN}.map"
  MOUNT_DIR="${FRONT_MOUNT_DIR}/${SITE_DOMAIN}"
  CERT_FULLCHAIN="${TLS_DIR}/${SITE_DOMAIN}/fullchain.pem"
  CERT_PRIVKEY="${TLS_DIR}/${SITE_DOMAIN}/privkey.pem"
}

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

# one deploy per site at a time (fd 9 stays open until the next site / exit)
lock_site() {
  install -d -m 755 "$LOCK_DIR"
  exec 9> "${LOCK_DIR}/front-deploy-${SITE_DOMAIN}.lock"
  flock -n 9 || die "Another deploy of ${SITE_DOMAIN} is running."
}

# One build at a time across all sites: two webpack / Vite builds side by
# side easily exhaust the RAM of a small VPS. Waits instead of failing.
lock_builds() {
  exec 8> "${LOCK_DIR}/front-deploy-build.lock"
  if ! flock -n 8; then
    say "Another site is building; waiting for it to finish ..."
    flock 8
  fi
}

# Fills PICKED: --all, --site, the only site, or a menu.
pick_sites() { # allow_all
  local allow_all=$1 names=() i ans
  PICKED=()
  mapfile -t names < <(site_names)
  ((${#names[@]} > 0)) || die "No sites yet. Set one up with front-deploy.sh first."
  if [[ $ALL -eq 1 ]]; then
    ((allow_all)) || die "--all does not work with this command."
    PICKED=("${names[@]}")
    return 0
  fi
  if [[ -n $SITE_ARG ]]; then
    SITE_ARG=$(normalize_domain "$SITE_ARG")
    [[ -f ${SITES_DIR}/${SITE_ARG}.conf ]] || die "No site '${SITE_ARG}'. Sites: ${names[*]}"
    PICKED=("$SITE_ARG")
    return 0
  fi
  if ((${#names[@]} == 1)); then
    PICKED=("${names[0]}")
    return 0
  fi
  if [[ ! -t 0 ]]; then
    if ((allow_all)); then
      die "There are several sites (${names[*]}); pass --site <name> or --all."
    fi
    die "There are several sites (${names[*]}); pass --site <name>."
  fi
  printf 'Sites:\n'
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
    useradd --system --user-group --home-dir "$FD_HOME" --shell /usr/sbin/nologin "$BUILD_USER" \
      || die "Could not create the ${BUILD_USER} user."
  fi
  install -d -m 750 -o "$BUILD_USER" -g "$BUILD_USER" "$FD_HOME"
  install -d -m 700 -o "$BUILD_USER" -g "$BUILD_USER" "${FD_HOME}/.ssh" "${FD_HOME}/keys"
}

builder_env() {
  local v
  BENV=(
    HOME="$FD_HOME"
    PATH="${NODE_DIR:+${NODE_DIR}/bin:}/usr/local/bin:/usr/bin:/bin"
    LANG=C.UTF-8
    LC_ALL=C.UTF-8
    GIT_TERMINAL_PROMPT=0
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    COREPACK_ENABLE_STRICT=0
    npm_config_update_notifier=false
    npm_config_fund=false
    npm_config_audit=false
    BROWSERSLIST_IGNORE_OLD_DATA=1
    NEXT_TELEMETRY_DISABLED=1
  )
  if [[ -n $REGISTRY ]]; then
    BENV+=(npm_config_registry="$REGISTRY" COREPACK_NPM_REGISTRY="$REGISTRY"
      YARN_REGISTRY="$REGISTRY" YARN_NPM_REGISTRY_SERVER="$REGISTRY")
  fi
  if [[ -n $SITE_KEY ]]; then
    BENV+=(GIT_SSH_COMMAND="ssh -i ${SITE_KEY} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${FD_HOME}/.ssh/known_hosts")
  fi
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    if [[ -n ${!v:-} ]]; then
      BENV+=("${v}=${!v}")
    fi
  done
}

as_builder() {
  builder_env
  (cd "$FD_HOME" && runuser -u "$BUILD_USER" -- env -i "${BENV[@]}" "$@")
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

# Official tarballs, one folder per version, so sites can use different
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
  die "Could not install Node.js ${major}. Check the network, or pin another major with front-deploy.sh --node."
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

# The registry for this run: the site's own, else npmjs, else a mirror.
pick_registry() {
  REGISTRY=$SITE_NPM_REGISTRY
  if [[ -n $REGISTRY ]]; then
    return 0
  fi
  if curl -fsS -o /dev/null --max-time 10 https://registry.npmjs.org/-/ping 2> /dev/null; then
    return 0
  fi
  REGISTRY=$NPM_REGISTRY_FALLBACK
  warn "registry.npmjs.org is unreachable; using ${REGISTRY} (pin one with front-deploy.sh --npm-registry)."
}

# ---------------------------------------------------------------------------
# Repository
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

# The folder with the frontend's package.json: the repository root, or the
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
  ((${#c[@]} > 0)) || die "The repository has no package.json; is this a JavaScript frontend?"
  if ((${#c[@]} == 1)); then
    SITE_APP_DIR=${c[0]}
    say "Frontend found in ${SITE_APP_DIR}/"
  else
    [[ -t 0 ]] || die "Several package.json files (${c[*]}); set the folder with front-deploy.sh --app-dir."
    printf 'Which folder is the frontend?\n'
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
scripts = d.get("scripts") if isinstance(d.get("scripts"), dict) else {}
print("HAS_BUILD=%d" % (1 if "build" in scripts else 0))
pm = str(d.get("packageManager") or "").split("@")[0]
print("PM=%s" % (pm if pm in ("npm", "pnpm", "yarn", "bun") else ""))
deps = {}
for key in ("dependencies", "devDependencies"):
    if isinstance(d.get(key), dict):
        deps.update(d[key])
if any(k in deps for k in ("react-scripts", "@craco/craco", "react-app-rewired")):
    hint = "build"
elif "next" in deps:
    hint = "out"
    print("NEXT=1")
elif "@sveltejs/adapter-static" in deps:
    hint = "build"
else:
    hint = "dist"  # Vite, Vue CLI, Parcel, Rsbuild, ...
print("HINT=%s" % hint)
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
  PKG_HAS_BUILD=0 PKG_PM="" PKG_HINT=dist PKG_NODE="" PKG_NEXT=0
  while IFS='=' read -r k v; do
    case $k in
      ERROR) die "Cannot read ${1}/package.json: ${v}" ;;
      HAS_BUILD) PKG_HAS_BUILD=$v ;;
      PM) PKG_PM=$v ;;
      HINT) PKG_HINT=$v ;;
      NODE) PKG_NODE=$v ;;
      NEXT) PKG_NEXT=$v ;;
    esac
  done < <(pkg_json_info "${1}/package.json")
}

# --node from front-deploy.sh, else .nvmrc / .node-version, else engines.node
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
  case $PM in
    pnpm)
      INSTALL_CMD="corepack pnpm install --frozen-lockfile"
      INSTALL_FALLBACK="corepack pnpm install --no-frozen-lockfile"
      BUILD_CMD="corepack pnpm run build"
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
      ;;
  esac
  if [[ -z $lock && -n $INSTALL_FALLBACK ]]; then
    INSTALL_CMD=$INSTALL_FALLBACK # nothing to freeze
    INSTALL_FALLBACK=""
  fi
  if [[ -n $SITE_INSTALL_CMD ]]; then
    INSTALL_CMD=$SITE_INSTALL_CMD
    INSTALL_FALLBACK=""
  fi
  if [[ -n $SITE_BUILD_CMD ]]; then
    BUILD_CMD=$SITE_BUILD_CMD
  fi
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

# shared/.env -> .env.production.local, which Vite and CRA read last
stage_env() {
  local target="${APP}/.env.production.local"
  rm -f "$target"
  if [[ -s $ENV_FILE ]]; then
    install -m 640 -o "$BUILD_USER" -g "$BUILD_USER" "$ENV_FILE" "$target"
    say "Build env: ${ENV_FILE}"
  fi
}

env_hash() {
  if [[ -s $ENV_FILE ]]; then
    sha256sum "$ENV_FILE" | cut -c1-16
  else
    printf -- '-\n'
  fi
}

# What decides whether the live release is still current.
build_signature() {
  printf '%s|%s|%s|%s|%s\n' "$COMMIT" "$(env_hash)" "$NODE_MAJOR" "$BUILD_CMD" "$SITE_APP_DIR"
}

safe_rel_dir() {
  [[ -n $1 && $1 != /* && $1 != *..* ]]
}

# Sets OUT_DIR. The first build guesses the folder (from package.json, else
# the newest index.html), asks to confirm it and saves it.
find_output() { # stamp
  local stamp=$1 guess="" ans d
  if [[ -n $SITE_BUILD_DIR ]]; then
    OUT_DIR="${APP}/${SITE_BUILD_DIR}"
    [[ -f ${OUT_DIR}/index.html ]] \
      || die "The build finished but ${SITE_BUILD_DIR}/index.html is missing. Pick the right folder with: front-update --force --build-dir <dir>"
    return 0
  fi
  if [[ ${APP}/${PKG_HINT}/index.html -nt $stamp ]]; then
    guess=$PKG_HINT
  else
    while IFS= read -r d; do
      [[ $d == . ]] && continue
      guess=$d
      break
    done < <(cd "$APP" && find . -name index.html -newer "$stamp" -not -path '*/node_modules/*' \
      -not -path './.git/*' -printf '%h\n' 2> /dev/null | sed 's|^\./||' | awk '{print length, $0}' | sort -n | cut -d' ' -f2-)
  fi
  if [[ -z $guess ]]; then
    if [[ $PKG_NEXT == 1 ]]; then
      die "No static output found. A Next.js app needs output: 'export' in next.config to build a static site."
    fi
    die "The build did not write an index.html anywhere. Set the output folder with --build-dir."
  fi
  if [[ -t 0 ]]; then
    printf 'Build output folder [%s]: ' "$guess"
    read -r ans || ans=""
    ans=${ans:-$guess}
    ans=${ans#./}
    guess=${ans%/}
  fi
  safe_rel_dir "$guess" || die "Invalid build folder '${guess}'."
  [[ -f ${APP}/${guess}/index.html ]] || die "${guess}/index.html does not exist."
  SITE_BUILD_DIR=$guess
  save_site
  say "Build output folder: ${SITE_BUILD_DIR} (saved; change it with --build-dir)"
  OUT_DIR="${APP}/${SITE_BUILD_DIR}"
}

build_app() {
  local stamp
  stamp=$(mktemp)
  say "Building: ${BUILD_CMD}"
  if ! run_in "$APP" "$BUILD_CMD"; then
    rm -f "$stamp"
    die "The build failed (output above); the live site was not touched."
  fi
  find_output "$stamp"
  rm -f "$stamp"
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

switch_to() { # release name
  ln -sfn "releases/$1" "${SITE_ROOT}/current.new"
  mv -Tf "${SITE_ROOT}/current.new" "${SITE_ROOT}/current"
}

prune_releases() {
  local cur all=() n i
  cur=$(current_release || true)
  mapfile -t all < <(release_list)
  n=${#all[@]}
  ((n > SITE_KEEP)) || return 0
  for ((i = 0; i < n - SITE_KEEP; i++)); do
    [[ ${all[i]} == "$cur" ]] && continue
    rm -rf "${RELEASES_DIR:?}/${all[i]}" "${META_DIR}/${all[i]}.sig"
  done
}

# Copies a finished build into releases/<time>-<tag> and makes it live.
publish() { # source-dir signature tag
  local src=$1 sig=$2 tag=$3 name rel
  install -d -m 755 "$RELEASES_DIR" "$META_DIR"
  while :; do
    name="$(date +%Y%m%d-%H%M%S)-${tag}"
    rel="${RELEASES_DIR}/${name}"
    [[ -e $rel ]] || break
    sleep 1
  done
  rm -rf "${rel}.tmp"
  mkdir "${rel}.tmp"
  cp -a "${src}/." "${rel}.tmp/"
  chown -R root:root "${rel}.tmp"
  chmod -R u=rwX,go=rX "${rel}.tmp"
  mv "${rel}.tmp" "$rel"
  printf '%s\n' "$sig" > "${META_DIR}/${name}.sig"
  switch_to "$name"
  prune_releases
  RELEASE=$name
}

# --dist: a folder, or an archive unpacked into a temp folder. index.html at
# the top, or in the only folder inside it (a zipped "dist/").
stage_dist() { # path
  local p=$1 src subs=()
  [[ -e $p ]] || die "${p} does not exist."
  if [[ -d $p ]]; then
    src=$(readlink -f "$p")
  else
    STAGE_TMP=$(mktemp -d)
    src=$STAGE_TMP
    case ${p,,} in
      *.zip)
        command -v unzip > /dev/null 2>&1 || apt_install unzip || die "Could not install unzip."
        unzip -q "$p" -d "$src" || die "Could not unpack ${p}."
        ;;
      *.tar.gz | *.tgz) tar -xzf "$p" -C "$src" --no-same-owner || die "Could not unpack ${p}." ;;
      *.tar.xz) tar -xJf "$p" -C "$src" --no-same-owner || die "Could not unpack ${p}." ;;
      *.tar) tar -xf "$p" -C "$src" --no-same-owner || die "Could not unpack ${p}." ;;
      *) die "Unsupported file ${p}: use a folder, .zip, .tar.gz or .tar" ;;
    esac
  fi
  if [[ -f ${src}/index.html ]]; then
    OUT_DIR=$src
    return 0
  fi
  mapfile -t subs < <(find "$src" -mindepth 2 -maxdepth 2 -name index.html -printf '%h\n' | sort)
  ((${#subs[@]} == 1)) || die "${p} has no index.html at the top (or in exactly one folder inside it)."
  OUT_DIR=${subs[0]}
}

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------
update_dist() {
  local p=$DIST
  if [[ -z $p ]]; then
    [[ -t 0 ]] || die "${SITE_DOMAIN} is published from uploads; pass --dist <folder|zip|tar.gz>."
    printf 'Path to the new build (folder, .zip or .tar.gz): '
    read -r p || die "No input."
    p=${p/#\~/$HOME}
  fi
  stage_dist "$p"
  publish "$OUT_DIR" "upload|$(date +%s)" upload
  _cleanup
  STAGE_TMP=""
  say "Live: https://${SITE_DOMAIN}/ -> ${RELEASE} (from ${p})"
}

update_site() { # domain
  local started sig cur
  started=$(date +%s)
  load_site "$1"
  lock_site
  say "=== ${SITE_DOMAIN} ==="

  if [[ -n $NEW_BRANCH ]]; then
    SITE_BRANCH=$NEW_BRANCH
    save_site
    say "Branch switched to ${SITE_BRANCH} (saved)."
  fi
  if [[ -n $NEW_BUILD_DIR ]]; then
    SITE_BUILD_DIR=$NEW_BUILD_DIR
    save_site
    say "Build output folder set to ${SITE_BUILD_DIR} (saved)."
  fi
  if [[ -n $DIST || $SITE_SOURCE == upload ]]; then
    update_dist
    return 0
  fi
  [[ -n $SITE_REPO && -n $SITE_BRANCH ]] || die "${SITE_DOMAIN} has no repository; re-run front-deploy.sh."

  ensure_build_user
  install -d -m 755 "$META_DIR"
  git_sync
  choose_app_dir
  APP="${REPO_DIR}/${SITE_APP_DIR}"
  APP=${APP%/.}
  [[ -f ${APP}/package.json ]] || die "${SITE_APP_DIR}/package.json is missing in the repository."
  read_package_json "$APP"
  if [[ $PKG_HAS_BUILD != 1 && -z $SITE_BUILD_CMD ]]; then
    die "package.json has no \"build\" script; set the command with front-deploy.sh --build-cmd."
  fi
  pick_node_major
  detect_pm

  sig=$(build_signature)
  cur=$(current_release || true)
  if [[ $FORCE -eq 0 && -n $cur && -f ${META_DIR}/${cur}.sig && $(cat "${META_DIR}/${cur}.sig") == "$sig" ]]; then
    say "Already live: ${COMMIT} \"${COMMIT_MSG}\". Nothing to do (--force rebuilds)."
    return 0
  fi
  # after a rollback: the build of this commit is still on disk
  if [[ $FORCE -eq 0 ]] && RELEASE=$(release_with_sig "$sig"); then
    switch_to "$RELEASE"
    say "Live again: ${COMMIT} \"${COMMIT_MSG}\" (kept release ${RELEASE}, no rebuild)."
    return 0
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
  stage_env
  build_app
  publish "$OUT_DIR" "$sig" "$COMMIT"
  say "Live: https://${SITE_DOMAIN}/ -> ${COMMIT} \"${COMMIT_MSG}\" in $(($(date +%s) - started))s (release ${RELEASE})"
}

cmd_update() {
  local d self args=() ok=() failed=()
  pick_sites 1
  if ((${#PICKED[@]} == 1)); then
    update_site "${PICKED[0]}"
    return 0
  fi
  if [[ -n $NEW_BRANCH || -n $NEW_BUILD_DIR || -n $DIST ]]; then
    die "--branch, --build-dir and --dist change one site; pick it with --site."
  fi
  # each site in its own process, so one failing build does not stop the rest
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
    if FD_NO_LOG=1 bash "$self" --site "$d" ${args[@]+"${args[@]}"} < /dev/null; then
      ok+=("$d")
    else
      failed+=("$d")
    fi
    printf '\n'
  done
  say "Done: ${ok[*]:-none}"
  if ((${#failed[@]} > 0)); then
    die "Failed: ${failed[*]} (output above; those sites still serve their previous release)."
  fi
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
  switch_to "$target"
  say "${SITE_DOMAIN}: ${cur:-none} -> ${target}"
  if [[ $SITE_SOURCE != upload ]]; then
    say "Plain 'front-update' brings the latest commit back."
  fi
}

cmd_list() {
  local d cur n src names=()
  mapfile -t names < <(site_names)
  if ((${#names[@]} == 0)); then
    say "No sites yet. Set one up with front-deploy.sh."
    return 0
  fi
  for d in "${names[@]}"; do
    load_site "$d"
    cur=$(current_release || printf 'none')
    n=$(release_list | wc -l)
    if [[ $SITE_SOURCE == upload ]]; then
      src="uploads (front-update --dist <path>)"
    else
      src="$(mask_url "$SITE_REPO") (${SITE_BRANCH})"
    fi
    printf '%s\n' "https://${SITE_DOMAIN}/"
    printf '  source  : %s\n' "$src"
    printf '  live    : %s (%s releases kept)\n' "$cur" "$n"
    if [[ $SITE_SOURCE != upload ]]; then
      printf '  build   : %s -> %s\n' "${SITE_APP_DIR:-?}" "${SITE_BUILD_DIR:-?}"
    fi
    printf '  env     : %s%s\n' "$ENV_FILE" "$([[ -s $ENV_FILE ]] || printf ' (none)')"
    printf '  disk    : %s in %s\n' "$(du -sh "$SITE_ROOT" 2> /dev/null | cut -f1)" "$SITE_ROOT"
    if compgen -G "${MOUNT_DIR}/*.conf" > /dev/null; then
      printf '  backend : %s (back-deploy.sh)\n' "$(mounted_paths)"
    fi
  done
}

# "/api -> example.com+api, ..." from the back-deploy mounts of this site
mounted_paths() {
  sed -n 's|^# Managed by back-deploy -- [^/]*\(/[^ ]*\) -> \(.*\)$|\1 -> \2|p' "$MOUNT_DIR"/*.conf 2> /dev/null \
    | paste -sd ',' - | sed 's/,/, /g'
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
  printf '    ssl_session_cache shared:front_deploy_ssl:10m;\n'
  printf '    ssl_session_timeout 1d;\n'
  printf '    add_header Strict-Transport-Security "max-age=31536000" always;\n'
}

# The SPA itself: unknown paths fall back to index.html (client-side
# routing), fingerprinted bundles are cached for a year, index.html never.
site_body() {
  cat << EOF

    root ${SITE_ROOT}/current;
    index index.html;
    charset utf-8;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types text/css text/plain text/xml application/javascript application/json application/xml application/manifest+json image/svg+xml font/ttf font/otf;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    # dotfiles (.env, .git, ...) are never served
    location ~ /\.(?!well-known/) {
        deny all;
    }

    # fingerprinted bundles: Vite writes /assets, Create React App /static
    location ^~ /assets/ {
        expires 1y;
        access_log off;
        try_files \$uri =404;
    }
    location ^~ /static/ {
        expires 1y;
        access_log off;
        try_files \$uri =404;
    }

    location ~* \.(?:ico|png|jpe?g|gif|webp|avif|svg|woff2?|ttf|otf|eot|mp4|webm|mp3|wav)$ {
        expires 7d;
        access_log off;
        try_files \$uri =404;
    }

    # the app shell must be fresh so a new release shows up at once
    location = /index.html {
        expires -1;
    }

    # backends of back-deploy.sh under a path of this site (e.g. /api)
    include ${MOUNT_DIR}/*.conf;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
EOF
}

sync_sni_route() { # http | https
  if [[ $1 == https ]] && relay_active; then
    install -d -m 755 "$SNI_ROUTES_DIR"
    {
      printf '# Managed by front-deploy -- SNI route for the dns-setup.sh relay\n'
      printf '"%s" 127.0.0.1:%s;\n' "$SITE_DOMAIN" "$SITE_TLS_PORT"
      if [[ $SITE_WWW == 1 ]]; then
        printf '"www.%s" 127.0.0.1:%s;\n' "$SITE_DOMAIN" "$SITE_TLS_PORT"
      fi
    } > "$SNI_MAP"
  else
    rm -f "$SNI_MAP"
  fi
}

# Without a certificate yet, port 80 serves the site (and the ACME
# challenge); with one, port 80 only redirects.
render_site_nginx() {
  local mode=http names=$SITE_DOMAIN
  cert_valid && mode=https
  [[ $SITE_WWW == 1 ]] && names+=" www.${SITE_DOMAIN}"
  H2_LISTEN=""
  H2_LINE=""
  if nginx_version_ge 1.25.1; then
    H2_LINE='    http2 on;'
  else
    H2_LISTEN=' http2'
  fi
  install -d -m 755 "$NGINX_DIR" "${ACME_ROOT}/.well-known/acme-challenge" "$MOUNT_DIR"
  {
    printf '# Managed by front-deploy -- run "front-update nginx" instead of editing by hand\n'
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
      site_body
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
      site_body
      printf '}\n'
    fi
  } > "$NGINX_CONF"
  sync_sni_route "$mode"
  RENDERED_MODE=$mode
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

# Renders every site (or --site) for the current :443 layout. dns-setup.sh
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
    say "No front-deploy sites."
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
  local ans=""
  pick_sites 0
  load_site "${PICKED[0]}"
  lock_site
  if compgen -G "${MOUNT_DIR}/*.conf" > /dev/null; then
    die "Backends of back-deploy.sh run under ${SITE_DOMAIN} ($(mounted_paths)); remove them first with: back-update remove"
  fi
  if [[ $YES -eq 0 ]]; then
    [[ -t 0 ]] || die "Pass --yes to remove ${SITE_DOMAIN} without a prompt."
    printf 'This deletes %s: nginx config, %s, its certificate and deploy key. Type "yes": ' "$SITE_DOMAIN" "$SITE_ROOT"
    read -r ans || true
    [[ $ans == yes ]] || die "Aborted."
  fi
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
  rm -rf "${WWW_ROOT:?}/${SITE_DOMAIN:?}"
  rm -f "${SITES_DIR}/${SITE_DOMAIN}.conf" "${LOCK_DIR}/front-deploy-${SITE_DOMAIN}.lock"
  rmdir "$MOUNT_DIR" 2> /dev/null || true
  say "${SITE_DOMAIN} removed. nginx, certbot and Node.js stay installed."
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
      --dist)
        (($# >= 2)) || die "Option $1 needs a value."
        DIST="$2"
        shift 2
        ;;
      --branch)
        (($# >= 2)) || die "Option $1 needs a value."
        NEW_BRANCH="$2"
        shift 2
        ;;
      --build-dir)
        (($# >= 2)) || die "Option $1 needs a value."
        NEW_BUILD_DIR="${2#./}"
        NEW_BUILD_DIR=${NEW_BUILD_DIR%/}
        FORCE=1
        shift 2
        ;;
      --to)
        (($# >= 2)) || die "Option $1 needs a value."
        ROLLBACK_TO="$2"
        shift 2
        ;;
      --no-reload)
        NO_RELOAD=1
        shift
        ;;
      --yes)
        YES=1
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
  if [[ -n $NEW_BUILD_DIR ]] && ! safe_rel_dir "$NEW_BUILD_DIR"; then
    die "Invalid --build-dir '${NEW_BUILD_DIR}' (a folder inside the project, e.g. dist)."
  fi
  if [[ $ALL -eq 1 && -n $DIST ]]; then
    die "--dist publishes one build; use it with --site, not --all."
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
    update | rollback | list | nginx | remove)
      cmd=$1
      shift
      ;;
  esac
  parse_args "$@"
  setup_logging
  trap '_on_err $LINENO' ERR
  trap _cleanup EXIT
  "cmd_${cmd}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
