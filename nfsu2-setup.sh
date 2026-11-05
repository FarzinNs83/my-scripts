#!/usr/bin/env bash
# =============================================================================
#  nfsu2-setup.sh -- Need for Speed: Underground 2 in the browser
#                    (github.com/th0mk/nfsu2-web) on its own VPS, behind
#                    nginx with a Let's Encrypt certificate
#
#  Asks for the domain only. Everything else is done here:
#    1. packages (apt, an Iranian mirror when the normal sources are cut),
#       swap for the build on small servers
#    2. the game folder: it must be your own copy (v1.2 NA SPEED2.EXE). It is
#       looked for on this server; when it is not here, the script says where
#       to upload it and waits
#    3. the toolchain: wasi-sdk 34, Python venv (capstone, pefile), Node.js 24,
#       Rust; each from its own site, else a mirror
#    4. the project, cloned to /opt/nfsu2-web, built with its own scripts:
#       web/gen.sh (lift), web/build.sh (wasm), node build.mjs (page),
#       web/server-rs/build.sh (server)
#    5. the server as the project's systemd unit (nfsu2-web), nginx in front
#       (websockets, HTTPS) with an auto-renewed certificate
#
#  Run it again to update: it pulls the project, rebuilds what changed and
#  restarts the server.
#
#  Usage:
#    bash nfsu2-setup.sh          (asks for the domain)
#    bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/nfsu2-setup.sh)
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
# rustup, the build caches (~/.cache/nsfu2-web) and cargo all live in root's home
export HOME=/root

REPO_URL="https://github.com/th0mk/nfsu2-web.git"
APP_DIR="/opt/nfsu2-web"
GAME_DIR="/srv/nfsu2/game"
NODE_ROOT="/opt/nfsu2-node"
NODE_MAJOR=24
WASI_VER=34
EXE_SIZE=4800512
EXE_SHA256="f9dd86c054878ce6276beb07c1fd61874f7a1e4bf1f241b084c65b73e24168a7"
HTTP_PORT=8080
DOMAIN_FILE="/etc/nfsu2-web.domain"
NGINX_CONF="/etc/nginx/conf.d/nfsu2-web.conf"
ACME_ROOT="/var/www/nfsu2-acme"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/nfsu2-reload.sh"
LOG_FILE="/var/log/nfsu2-setup.log"

APT_MIRROR="http://mirror-linux.runflare.com" # Iranian; apt checks signatures, so http is fine
# tried in order; the Iranian mirrors (runflare) last
NODE_MIRRORS=(https://nodejs.org/dist https://npmmirror.com/mirrors/node https://mirror-nodejs.runflare.com/dist)
NPM_REGISTRY_FALLBACKS=(https://registry.npmmirror.com https://mirror-npm.runflare.com)
PIP_INDEX_FALLBACKS=(https://mirrors.aliyun.com/pypi/simple/ https://mirror-pypi.runflare.com/simple/)
# GitHub proxies, for release downloads and the clone when github.com is slow or cut
GH_PROXIES=("" https://ghfast.top/ https://gh-proxy.com/)

DOMAIN=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] Setup failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}
trap '_on_err $LINENO' ERR

case "${1:-}" in
  -h | --help) sed -n '2,27p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
esac

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo -i first)."

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# apt, with the Iranian mirror when the configured sources are unreachable
# ---------------------------------------------------------------------------
APT_OPTS=(-o DPkg::Lock::Timeout=180)

# Sources and lists live in a temp dir, so /etc/apt stays untouched.
apt_use_mirror() {
  local id="" code="" dir kr opt="" s
  [[ ${APT_OPTS[*]} != *SourceList* ]] || return 1
  id=$(. /etc/os-release && printf '%s' "${ID:-}") || id=""
  code=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}") || code=""
  [[ -n $code ]] || return 1
  kr="/usr/share/keyrings/${id}-archive-keyring.gpg"
  [[ -f $kr ]] && opt="[signed-by=${kr}] "
  dir=$(mktemp -d)
  chmod 755 "$dir"
  mkdir -p "${dir}/parts" "${dir}/lists/partial"
  chown _apt "${dir}/lists/partial" 2> /dev/null || true
  case $id in
    ubuntu)
      # shortcut: amd64 only (other arches live in ubuntu-ports); add ports if arm VPSes need it
      [[ $(dpkg --print-architecture) == amd64 ]] || { rm -rf "$dir"; return 1; }
      for s in "$code" "${code}-updates" "${code}-security"; do
        printf 'deb %s%s/ubuntu %s main restricted universe multiverse\n' "$opt" "$APT_MIRROR" "$s"
      done > "${dir}/sources.list"
      ;;
    debian)
      {
        printf 'deb %s%s/debian %s main\n' "$opt" "$APT_MIRROR" "$code" "$opt" "$APT_MIRROR" "${code}-updates"
        printf 'deb %s%s/debian-security %s-security main\n' "$opt" "$APT_MIRROR" "$code"
      } > "${dir}/sources.list"
      ;;
    *) rm -rf "$dir"; return 1 ;;
  esac
  APT_OPTS+=(-o "Dir::Etc::SourceList=${dir}/sources.list" -o "Dir::Etc::SourceParts=${dir}/parts"
    -o "Dir::State::Lists=${dir}/lists")
  warn "apt sources are unreachable; using ${APT_MIRROR} for this run."
}

ensure_packages() {
  local pkgs=(curl ca-certificates git build-essential perl python3 python3-venv python3-pip
    xz-utils rsync nginx certbot)
  local missing=() p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" > /dev/null 2>&1 || missing+=("$p")
  done
  ((${#missing[@]} == 0)) && return 0
  say "Installing packages: ${missing[*]}"
  if ! apt-get "${APT_OPTS[@]}" update -qq; then
    apt_use_mirror && apt-get "${APT_OPTS[@]}" update -qq || true
  fi
  # apt update only warns on network errors, so a failed install also retries through the mirror
  apt-get "${APT_OPTS[@]}" install -y -qq "${missing[@]}" \
    || { apt_use_mirror && apt-get "${APT_OPTS[@]}" update -qq && apt-get "${APT_OPTS[@]}" install -y -qq "${missing[@]}"; } \
    || die "Could not install: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
ask_domain() {
  local saved="" d
  [[ -f $DOMAIN_FILE ]] && saved=$(cat "$DOMAIN_FILE")
  while :; do
    read -rp "Domain for the game${saved:+ [${saved}]}: " d < /dev/tty || die "No domain given."
    d=${d:-$saved}
    d=${d#*://}; d=${d%%/*}; d=${d%.}
    d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
      DOMAIN=$d
      break
    fi
    warn "'${d}' is not a domain name (e.g. game.example.com)."
  done
  printf '%s\n' "$DOMAIN" > "$DOMAIN_FILE"
}

public_ipv4() {
  local u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 10 "$u" 2> /dev/null | tr -d '[:space:]') || continue
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { printf '%s\n' "$ip"; return 0; }
  done
  return 1
}

check_dns() {
  local mine resolved
  resolved=$(getent ahostsv4 "$DOMAIN" 2> /dev/null | awk 'NR == 1 {print $1}') || true
  [[ -n $resolved ]] || die "No A record for ${DOMAIN}. Point it to this server (Cloudflare: grey cloud) and re-run."
  # an address of this server's own interfaces: the outgoing IP can differ (provider NAT, a proxy)
  if ip -4 -o addr show | awk '{split($4, a, "/"); print a[1]}' | grep -qxF "$resolved"; then
    say "DNS OK: ${DOMAIN} -> ${resolved}"
    return 0
  fi
  mine=$(public_ipv4) || mine=""
  if [[ $resolved == "$mine" ]]; then
    say "DNS OK: ${DOMAIN} -> ${resolved}"
    return 0
  fi
  # behind 1:1 NAT neither matches; the certificate (next step) is the real check
  warn "${DOMAIN} points to ${resolved}, not an address of this server (outgoing IP: ${mine:-unknown}). Continuing; the certificate step fails if it is wrong."
}

check_system() {
  local arch avail
  arch=$(uname -m)
  case $arch in
    x86_64) WASI_ARCH=x86_64 NODE_ARCH=x64 ;;
    aarch64) WASI_ARCH=arm64 NODE_ARCH=arm64 ;;
    *) die "Unsupported CPU: ${arch} (x86_64 or aarch64)." ;;
  esac
  avail=$(df -Pk / | awk 'NR == 2 {print $4}')
  # the game (~3 GB), the lifted C, the objects and their cache, the Rust build
  ((avail >= 15 * 1024 * 1024)) || die "At least 15 GB of free disk is needed (found $((avail / 1024 / 1024)) GB)."
}

# Compiling the lifted shards at -O3 takes ~2 GB per clang; small VPSes get swap
ensure_swap() {
  local mem_kb swap_kb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  ((mem_kb < 8000000 && swap_kb == 0)) || return 0
  [[ -e /swapfile ]] && { warn "/swapfile exists but is not active; leaving it alone."; return 0; }
  say "Only $((mem_kb / 1024)) MB RAM and no swap: adding a 4 GB swap file for the build ..."
  if { fallocate -l 4G /swapfile 2> /dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none; } \
    && chmod 600 /swapfile && mkswap /swapfile > /dev/null && swapon /swapfile; then
    grep -qs '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  else
    rm -f /swapfile
    warn "This server does not allow swap; the build runs fewer jobs at once."
  fi
}

# ---------------------------------------------------------------------------
# The game folder (your own copy; never downloaded)
# ---------------------------------------------------------------------------
find_exe() {
  local d
  for d in "$GAME_DIR" /srv /root /home /opt /mnt /media /tmp /var/tmp; do
    [[ -d $d ]] || continue
    find "$d" -path "$APP_DIR" -prune -o -type f -iname speed2.exe -size "${EXE_SIZE}c" -print 2> /dev/null | head -n 1
  done | head -n 1
}

ensure_game() {
  local exe src
  while :; do
    exe=$(find_exe || true) # head closing early makes find exit with SIGPIPE
    [[ -n $exe ]] && break
    cat << EOF

[!] The game is not on this server yet. Upload your own NFS Underground 2
    folder (the one with SPEED2.EXE, patched to v1.2 NA) to ${GAME_DIR}
    From Windows (PowerShell), inside the game folder:
      ssh root@${DOMAIN} mkdir -p ${GAME_DIR}
      scp -r * root@${DOMAIN}:${GAME_DIR}/
    or with WinSCP / FileZilla (SFTP) into ${GAME_DIR}

EOF
    read -rp "Press Enter when the upload is done (Ctrl-C to quit) " _ < /dev/tty || die "Cancelled."
  done
  say "Checking ${exe} ..."
  [[ $(sha256sum "$exe" | awk '{print $1}') == "$EXE_SHA256" ]] \
    || die "${exe} is not the v1.2 North America SPEED2.EXE (SHA-256 differs); other versions do not work."
  src=$(dirname "$exe")
  if [[ $src != "$GAME_DIR" ]]; then
    # the service cannot read /root or /home (ProtectHome); copy, leave the original alone
    say "Copying the game from ${src} to ${GAME_DIR} ..."
    mkdir -p "$GAME_DIR"
    rsync -a "${src}/" "${GAME_DIR}/"
  fi
  chmod -R u=rwX,go=rX "$GAME_DIR"
  chmod 755 /srv/nfsu2
  GAME_EXE="${GAME_DIR}/$(basename "$exe")"
  say "Game OK: ${GAME_DIR}"
}

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
# github_get <url> <out>: the URL, else through each GitHub proxy
github_get() {
  local p
  for p in "${GH_PROXIES[@]}"; do
    curl -fSL --retry 2 --connect-timeout 20 --max-time 1800 -o "$2" "${p}$1" && return 0
    warn "Download failed${p:+ through ${p}}: $1"
  done
  return 1
}

ensure_project() {
  local p ok=0
  if [[ -d ${APP_DIR}/.git ]]; then
    say "Updating the project in ${APP_DIR} ..."
    for p in "${GH_PROXIES[@]}"; do
      git -C "$APP_DIR" fetch -q --depth 1 "${p}${REPO_URL}" HEAD && { ok=1; break; }
      warn "git fetch failed${p:+ through ${p}}."
    done
    ((ok)) || die "Could not fetch ${REPO_URL}."
    git -C "$APP_DIR" reset -q --hard FETCH_HEAD
  else
    say "Cloning ${REPO_URL} to ${APP_DIR} ..."
    for p in "${GH_PROXIES[@]}"; do
      rm -rf "$APP_DIR"
      git clone -q --depth 1 "${p}${REPO_URL}" "$APP_DIR" && break
      warn "git clone failed${p:+ through ${p}}."
    done
    [[ -d ${APP_DIR}/.git ]] || die "Could not clone ${REPO_URL}."
    # the remote stays github.com, whatever proxy cloned it
    git -C "$APP_DIR" remote set-url origin "$REPO_URL"
  fi
  say "Project at $(git -C "$APP_DIR" rev-parse --short HEAD)"
}

ensure_wasi() {
  local name="wasi-sdk-${WASI_VER}.0-${WASI_ARCH}-linux" tmp
  export WASI="${APP_DIR}/deps/${name}"
  [[ -x ${WASI}/bin/clang ]] && return 0
  say "Downloading wasi-sdk ${WASI_VER} ..."
  tmp=$(mktemp -d)
  github_get "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_VER}/${name}.tar.gz" "${tmp}/w.tgz" \
    || die "Could not download wasi-sdk."
  mkdir -p "${APP_DIR}/deps"
  tar -xzf "${tmp}/w.tgz" -C "${APP_DIR}/deps" --no-same-owner
  rm -rf "$tmp"
  "${WASI}/bin/clang" --version > /dev/null || die "wasi-sdk does not run on this server."
}

ensure_python() {
  local args=() i
  if ! curl -fsS -o /dev/null --max-time 10 https://pypi.org/simple/pip/; then
    for i in "${PIP_INDEX_FALLBACKS[@]}"; do
      curl -fsS -o /dev/null --max-time 10 "${i}pip/" && { args=(-i "$i"); warn "pypi.org is unreachable; using ${i}"; break; }
    done
  fi
  [[ -x ${APP_DIR}/.venv/bin/python ]] || python3 -m venv "${APP_DIR}/.venv"
  say "Installing the lifter's Python packages ..."
  "${APP_DIR}/.venv/bin/pip" install -q "${args[@]}" -r "${APP_DIR}/requirements.txt"
}

ensure_node() {
  local mirror ver file tmp sum
  if [[ ! -x ${NODE_ROOT}/current/bin/node ]]; then
    for mirror in "${NODE_MIRRORS[@]}"; do
      ver=$(curl -fsSL --max-time 30 "${mirror}/index.json" 2> /dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r["version"].startswith("v%s." % sys.argv[1]) and ("linux-%s" % sys.argv[2]) in r.get("files", []):
        print(r["version"]); break
' "$NODE_MAJOR" "$NODE_ARCH" 2> /dev/null) || ver=""
      [[ -n $ver ]] || { warn "No Node.js ${NODE_MAJOR} list from ${mirror}."; continue; }
      file="node-${ver}-linux-${NODE_ARCH}.tar.gz"
      tmp=$(mktemp -d)
      say "Downloading Node.js ${ver} from ${mirror} ..."
      if curl -fsSL --max-time 900 -o "${tmp}/${file}" "${mirror}/${ver}/${file}" \
        && curl -fsSL --max-time 60 -o "${tmp}/SHASUMS256.txt" "${mirror}/${ver}/SHASUMS256.txt" \
        && sum=$(awk -v f="$file" '$2 == f {print $1}' "${tmp}/SHASUMS256.txt") && [[ -n $sum ]] \
        && [[ $(sha256sum "${tmp}/${file}" | awk '{print $1}') == "$sum" ]]; then
        rm -rf "${NODE_ROOT:?}/${ver}"
        install -d -m 755 "${NODE_ROOT}/${ver}"
        tar -xzf "${tmp}/${file}" -C "${NODE_ROOT}/${ver}" --strip-components=1 --no-same-owner
        ln -sfn "$ver" "${NODE_ROOT}/current"
        rm -rf "$tmp"
        break
      fi
      rm -rf "$tmp"
      warn "Downloading Node.js from ${mirror} failed."
    done
    [[ -x ${NODE_ROOT}/current/bin/node ]] || die "Could not install Node.js ${NODE_MAJOR}."
  fi
  export PATH="${NODE_ROOT}/current/bin:${PATH}"
  export npm_config_update_notifier=false PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  if ! curl -fsS -o /dev/null --max-time 10 https://registry.npmjs.org/-/ping; then
    local r
    for r in "${NPM_REGISTRY_FALLBACKS[@]}"; do
      curl -fsS -o /dev/null --max-time 10 "${r}/is-number" && { export npm_config_registry=$r; warn "registry.npmjs.org is unreachable; using ${r}"; break; }
    done
  fi
}

rust_ok() {
  local v
  v=$(rustc --version 2> /dev/null | awk '{print $2}') || return 1
  [[ -n $v ]] && printf '1.85.0\n%s\n' "$v" | sort -VC
}

ensure_rust() {
  export PATH="${HOME}/.cargo/bin:${PATH}"
  # the server is edition 2024: Rust 1.85 or newer (a distro's cargo is often older)
  if command -v rustup > /dev/null 2>&1 && ! rust_ok; then
    rustup toolchain install stable --profile minimal && rustup default stable
  fi
  if ! rust_ok; then
    export RUSTUP_INIT_SKIP_PATH_CHECK=yes
    local init=https://sh.rustup.rs
    if ! curl -fsS -o /dev/null --max-time 15 https://static.rust-lang.org/rustup/release-stable.toml; then
      warn "static.rust-lang.org is unreachable; installing Rust from rsproxy.cn"
      export RUSTUP_DIST_SERVER=https://rsproxy.cn RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup
      init=https://rsproxy.cn/rustup-init.sh
    fi
    say "Installing Rust ..."
    curl --proto '=https' --tlsv1.2 -fsSL "$init" | sh -s -- -y -q --profile minimal --default-toolchain stable
    rust_ok || die "Rust 1.85 or newer could not be installed."
  fi
  # crates through rsproxy when crates.io is cut (a dedicated VPS: the setting stays)
  if ! curl -fsS -o /dev/null --max-time 15 https://index.crates.io/config.json \
    && ! grep -qs replace-with "${HOME}/.cargo/config.toml"; then
    warn "crates.io is unreachable; using rsproxy.cn for crates"
    cat >> "${HOME}/.cargo/config.toml" << 'EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
EOF
  fi
}

# ---------------------------------------------------------------------------
# Build (the project's own scripts)
# ---------------------------------------------------------------------------
build_all() {
  local mem_mb
  cd "$APP_DIR"
  # shortcut: ~2 GB of RAM+swap per clang job; lower J by hand if the OOM killer still shows up
  mem_mb=$(awk '/^(MemTotal|SwapTotal):/ {s += $2} END {print int(s / 1024)}' /proc/meminfo)
  J=$((mem_mb / 2048))
  ((J > $(nproc))) && J=$(nproc)
  ((J < 1)) && J=1
  export J

  say "Lifting SPEED2.EXE to C (web/gen.sh; the first time takes a while) ..."
  web/gen.sh "$GAME_EXE"
  say "Compiling the game module (web/build.sh, ${J} jobs; the first time can take an hour) ..."
  web/build.sh
  say "Building the page ..."
  (cd web && npm ci --no-audit --no-fund && node build.mjs)
  say "Building the server ..."
  web/server-rs/build.sh
  [[ -f out/web/nfsu2.wasm && -f web/dist/main.js && -x out/web/server-rs/nfsu2-server ]] \
    || die "The build finished without the module, the page or the server."
}

# ---------------------------------------------------------------------------
# Service, nginx, certificate
# ---------------------------------------------------------------------------
install_service() {
  local holder
  holder=$(ss -Hltnp "sport = :${HTTP_PORT}" 2> /dev/null | grep -v nfsu2-server || true)
  [[ -z $holder ]] || die "Port ${HTTP_PORT} is used by something else: ${holder}"
  # the project's unit (variant A: behind a proxy), with this domain and the server where the build puts it
  sed -e "s|game\.example\.com|${DOMAIN}|g" \
    -e "s|/opt/nfsu2-web/nfsu2-server|${APP_DIR}/out/web/server-rs/nfsu2-server|g" \
    "${APP_DIR}/web/deploy/nfsu2-web.service" > /etc/systemd/system/nfsu2-web.service
  grep -q -- "--host ${DOMAIN} " /etc/systemd/system/nfsu2-web.service || die "Could not set the domain in the unit."
  systemctl daemon-reload
  systemctl enable -q nfsu2-web
  systemctl restart nfsu2-web
  local i
  for i in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${HTTP_PORT}/game.json" && { say "Server is up."; return 0; }
    sleep 2
  done
  journalctl -u nfsu2-web -n 30 --no-pager || true
  die "The server did not answer on 127.0.0.1:${HTTP_PORT} (journalctl -u nfsu2-web)."
}

write_nginx() { # http | https
  local cert="/etc/letsencrypt/live/${DOMAIN}" h2_listen="" h2_line=""
  mkdir -p "$ACME_ROOT"
  # http2 directive since nginx 1.25.1; older ones take it on the listen line
  if printf '%s\n%s\n' 1.25.1 "$(nginx -v 2>&1 | sed 's|.*/||')" | sort -VC; then h2_line="http2 on;"; else h2_listen=" http2"; fi
  {
    cat << EOF
# Written by nfsu2-setup.sh
map \$http_upgrade \$nfsu2_connection {
    default upgrade;
    ''      close;
}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root ${ACME_ROOT}; }
EOF
    if [[ $1 == http ]]; then
      printf '    location / { return 404; }\n}\n'
      return 0
    fi
    cat << EOF
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl${h2_listen};
    listen [::]:443 ssl${h2_listen};
    ${h2_line}
    server_name ${DOMAIN};
    ssl_certificate ${cert}/fullchain.pem;
    ssl_certificate_key ${cert}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$nfsu2_connection;
        # the address that connected, never one a client sent
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        # the game data is large: stream it, never spool it to disk
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
EOF
  } > "$NGINX_CONF"
}

reload_nginx() {
  nginx -t > /dev/null 2>&1 || { nginx -t; die "nginx config test failed (${NGINX_CONF})."; }
  systemctl enable -q nginx
  systemctl reload nginx 2> /dev/null || systemctl restart nginx
}

setup_https() {
  local p
  if command -v ufw > /dev/null && ufw status 2> /dev/null | grep -q 'Status: active'; then
    ufw allow 80/tcp > /dev/null && ufw allow 443/tcp > /dev/null
  fi
  if command -v firewall-cmd > /dev/null && [[ $(firewall-cmd --state 2> /dev/null) == running ]]; then
    for p in 80/tcp 443/tcp; do firewall-cmd -q --permanent --add-port="$p" || true; done
    firewall-cmd -q --reload || true
  fi
  if [[ ! -s /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]]; then
    write_nginx http
    reload_nginx
    say "Requesting a Let's Encrypt certificate for ${DOMAIN} ..."
    certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --cert-name "$DOMAIN" \
      --agree-tos --no-eff-email --register-unsafely-without-email --non-interactive --keep-until-expiring \
      || die "certbot failed. Check that ${DOMAIN} points here and TCP 80 is open in the provider's firewall."
  fi
  write_nginx https
  reload_nginx
  install -d -m 755 "$(dirname "$RENEW_HOOK")"
  printf '#!/bin/sh\nsystemctl reload nginx 2>/dev/null || true\n' > "$RENEW_HOOK"
  chmod 755 "$RENEW_HOOK"
  systemctl enable -q --now certbot.timer 2> /dev/null || true
}

main() {
  say "nfsu2-setup.sh -- log: ${LOG_FILE}"
  [[ -r /etc/os-release ]] && say "OS: $(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
  ask_domain
  check_system
  ensure_packages
  check_dns
  # the certificate before the long build: a wrong A record fails in a minute, not after an hour
  setup_https
  ensure_swap
  ensure_game
  ensure_project
  ensure_wasi
  ensure_python
  ensure_node
  ensure_rust
  build_all
  install_service
  curl -fsS -o /dev/null --max-time 15 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/game.json" \
    || warn "https://${DOMAIN}/ did not answer from this server; check nginx (journalctl -u nginx)."
  cat << EOF

[+] Done: https://${DOMAIN}/   (Chrome, or Firefox with WebGPU)

    Server log : journalctl -u nfsu2-web -f
    Restart    : systemctl restart nfsu2-web
    Update     : run this script again (pulls, rebuilds, restarts)
    Anyone who can open the site can play and download the game files from it.
EOF
}

main "$@"
