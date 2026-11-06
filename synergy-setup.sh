#!/usr/bin/env bash
# =============================================================================
#  synergy-setup.sh -- Synergy (Half-Life 2 co-op) dedicated server on a VPS
#
#  Asks for the server name, password, max players, start map, game port and
#  your Steam username. Everything else is done here:
#    1. packages: steamcmd, the 32-bit libraries, a "steam" user
#    2. Steam login: you type your password and Steam Guard code yourself;
#       steamcmd caches the login, the script never sees the password
#    3. Synergy (app 17520, free) and Half-Life 2 (app 220, includes
#       Episode One and Two) -- the account must own Half-Life 2
#    4. server.cfg, a systemd unit (synergy), the game port in the firewall,
#       and synergyctl: synergyctl start | stop | restart | status | log
#
#  Other game servers on the same VPS: the port must be free (the first free
#  one from 27015 is offered), SourceTV is off, and apt does not restart
#  running services.
#
#  Run it again to change the settings or update the game.
#  The downloads are ~12 GB; run it inside screen so a dropped SSH session
#  does not stop it (screen -S synergy, then re-attach: screen -r synergy).
#  A stalled download: Ctrl-C and run again; it resumes on another CDN server.
#
#  Usage:
#    bash synergy-setup.sh
#    bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/synergy-setup.sh)
# =============================================================================
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
# list only: restarting services after apt would kick players off other game servers
export NEEDRESTART_MODE=l

STEAM_USER=steam
STEAM_HOME=/home/steam
SYN_DIR="${STEAM_HOME}/synergy"
HL2_DIR="${STEAM_HOME}/hl2"
STEAMCMD=/usr/games/steamcmd
SERVICE=/etc/systemd/system/synergy.service
CTL=/usr/local/bin/synergyctl
CONF_FILE=/etc/synergy-setup.conf
LOG_FILE=/var/log/synergy-setup.log

# chapter starts: "map|title"
MAPS=(
  "d1_trainstation_01|HL2 - Point Insertion"
  "d1_trainstation_06|HL2 - A Red Letter Day"
  "d1_canals_01|HL2 - Route Kanal"
  "d1_canals_07|HL2 - Water Hazard"
  "d1_eli_01|HL2 - Black Mesa East"
  "d1_town_01|HL2 - We Don't Go To Ravenholm"
  "d2_coast_01|HL2 - Highway 17"
  "d2_coast_07|HL2 - Sandtraps"
  "d2_prison_01|HL2 - Nova Prospekt"
  "d2_prison_06|HL2 - Entanglement"
  "d3_c17_01|HL2 - Anticitizen One"
  "d3_c17_09|HL2 - Follow Freeman!"
  "d3_citadel_01|HL2 - Our Benefactors"
  "d3_breen_01|HL2 - Dark Energy"
  "ep1_citadel_00|Episode One - Undue Alarm"
  "ep1_citadel_03|Episode One - Direct Intervention"
  "ep1_c17_00|Episode One - Lowlife"
  "ep1_c17_01|Episode One - Urban Flight"
  "ep1_c17_06|Episode One - Exit 17"
  "ep2_outland_01|Episode Two - To the White Forest"
  "ep2_outland_03|Episode Two - This Vortal Coil"
  "ep2_outland_05|Episode Two - Freeman Pontifex"
  "ep2_outland_06a|Episode Two - Riding Shotgun"
  "ep2_outland_09|Episode Two - Under the Radar"
  "ep2_outland_11|Episode Two - Our Mutual Fiend"
  "ep2_outland_12a|Episode Two - T-Minus One"
)

SV_NAME="" SV_PASS="" SV_MAX="" SV_MAP="" PORT="" STEAM_LOGIN=""

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
  -h | --help) sed -n '2,26p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
esac

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo -i first)."
[[ $(uname -m) == x86_64 ]] || die "Synergy's server is x86 only (found $(uname -m))."

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

as_steam() { runuser -u "$STEAM_USER" -- env HOME="$STEAM_HOME" "$@"; }

# ---------------------------------------------------------------------------
# Questions (the last answers are the defaults)
# ---------------------------------------------------------------------------
# ask <prompt> <default>: one line from the terminal
ask() {
  local v
  read -rp "$1${2:+ [$2]}: " v < /dev/tty || die "Cancelled."
  printf '%s' "${v:-$2}"
}

# port_users <port>: what listens on it (TCP or UDP), leaving out this server's own unit
port_users() {
  local line pid
  ss -Hlntup "sport = :$1" 2> /dev/null | while read -r line; do
    pid=$(grep -o 'pid=[0-9]*' <<< "$line" | head -n 1 | cut -d= -f2) || true
    [[ -n $pid ]] && grep -qs '/synergy\.service' "/proc/${pid}/cgroup" && continue
    printf '%s\n' "$line"
  done
}

ask_all() {
  local c="" i n v
  # shellcheck disable=SC1090
  [[ -f $CONF_FILE ]] && . "$CONF_FILE"
  while :; do
    SV_NAME=$(ask "Server name" "${SV_NAME:-Synergy Server}")
    [[ -n $SV_NAME && $SV_NAME != *'"'* ]] && break
    warn "The name must not be empty or contain a double quote."
  done
  while :; do
    SV_PASS=$(ask "Server password (empty = no password)" "$SV_PASS")
    [[ $SV_PASS != *[\"[:space:]]* ]] && break
    warn "The password must not contain spaces or a double quote."
  done
  while :; do
    SV_MAX=$(ask "Max players (1-32)" "${SV_MAX:-4}")
    [[ $SV_MAX =~ ^[0-9]+$ ]] && ((SV_MAX >= 1 && SV_MAX <= 32)) && break
    warn "Enter a number from 1 to 32."
  done

  printf '\nStart map:\n'
  for i in "${!MAPS[@]}"; do
    printf '  %2d) %-18s %s\n' $((i + 1)) "${MAPS[i]%%|*}" "${MAPS[i]#*|}"
    [[ ${MAPS[i]%%|*} == "${SV_MAP:-d1_trainstation_01}" ]] && c=$((i + 1))
  done
  n=${#MAPS[@]}
  while :; do
    v=$(ask "Number, or any map name" "${c:-$SV_MAP}")
    if [[ $v =~ ^[0-9]+$ ]] && ((v >= 1 && v <= n)); then
      SV_MAP=${MAPS[v - 1]%%|*}
      break
    elif [[ $v =~ ^[A-Za-z0-9_]+$ && ! $v =~ ^[0-9]+$ ]]; then
      SV_MAP=$v
      break
    fi
    warn "Pick 1-${n}, or type a map name (letters, digits, _)."
  done

  if [[ -z $PORT ]]; then
    PORT=27015
    while [[ -n $(port_users "$PORT") ]]; do PORT=$((PORT + 1)); done
  fi
  while :; do
    v=$(ask "Game port (UDP+TCP; each game server on this VPS needs its own)" "$PORT")
    if ! [[ $v =~ ^[0-9]+$ ]] || ((v < 1024 || v > 65535)); then
      warn "Enter a port from 1024 to 65535."
    elif [[ -n $(port_users "$v") ]]; then
      warn "Port ${v} is taken:"
      port_users "$v" >&2
    else
      PORT=$v
      break
    fi
  done

  while :; do
    STEAM_LOGIN=$(ask "Steam username (the account that owns Half-Life 2)" "$STEAM_LOGIN")
    [[ $STEAM_LOGIN =~ ^[A-Za-z0-9_]+$ ]] && break
    warn "A Steam username has only letters, digits and _."
  done

  # printf %q: the values are sourced back on the next run
  {
    printf 'SV_NAME=%q\n' "$SV_NAME"
    printf 'SV_PASS=%q\n' "$SV_PASS"
    printf 'SV_MAX=%q\n' "$SV_MAX"
    printf 'SV_MAP=%q\n' "$SV_MAP"
    printf 'PORT=%q\n' "$PORT"
    printf 'STEAM_LOGIN=%q\n' "$STEAM_LOGIN"
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

# ---------------------------------------------------------------------------
# Packages and the steam user
# ---------------------------------------------------------------------------
ensure_packages() {
  local pkgs=(steamcmd:i386 lib32gcc-s1 lib32stdc++6 libc6-i386 libtinfo6:i386 libncurses6:i386 libatomic1:i386)
  local missing=() p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" > /dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    say "Installing packages: ${missing[*]}"
    dpkg --add-architecture i386
    command -v add-apt-repository > /dev/null || apt-get install -y -qq software-properties-common
    add-apt-repository -y multiverse > /dev/null
    apt-get -o DPkg::Lock::Timeout=180 update -qq
    printf 'steam steam/question select I AGREE\nsteam steam/license note \n' | debconf-set-selections
    apt-get -o DPkg::Lock::Timeout=180 install -y -qq "${missing[@]}" || die "Could not install: ${missing[*]}"
  fi
  id "$STEAM_USER" > /dev/null 2>&1 || useradd -m -s /bin/bash "$STEAM_USER"
}

check_disk() {
  local avail
  avail=$(df -Pk "$STEAM_HOME" | awk 'NR == 2 {print $4}')
  # Synergy ~1 GB, Half-Life 2 with both episodes ~11 GB, plus room for updates
  [[ -d ${HL2_DIR}/hl2 ]] || ((avail >= 15 * 1024 * 1024)) \
    || die "At least 15 GB of free disk is needed (found $((avail / 1024 / 1024)) GB)."
}

# ---------------------------------------------------------------------------
# Steam
# ---------------------------------------------------------------------------
# a cached login goes through without a prompt
steam_cached() {
  local out
  out=$(as_steam "$STEAMCMD" +login "$STEAM_LOGIN" +quit < /dev/null 2>&1) || true
  [[ $out == *"Logging in using cached credentials"* && $out != *FAILED* ]]
}

steam_login() {
  if steam_cached; then
    say "Steam: cached login for ${STEAM_LOGIN}."
    return 0
  fi
  cat << EOF

[!] Steam login for ${STEAM_LOGIN}: type your Steam password, then the Steam
    Guard code (app or e-mail) when steamcmd asks. It is cached for later runs.

EOF
  as_steam "$STEAMCMD" +login "$STEAM_LOGIN" +app_license_request 17520 +quit < /dev/tty || true
  steam_cached || die "Steam login did not work. Run the script again."
}

# app_install <app id> <dir>: with retries (steamcmd fails now and then mid-download)
app_install() {
  local i out
  for i in 1 2 3; do
    say "Installing app $1 to $2 (try ${i}/3) ..."
    out=$(as_steam "$STEAMCMD" +@sSteamCmdForcePlatformType linux +force_install_dir "$2" \
      +login "$STEAM_LOGIN" +app_update "$1" +quit < /dev/null 2>&1 | tee /dev/stderr) || true
    [[ $out == *"Success! App '$1'"* ]] && return 0
    warn "steamcmd did not finish app $1."
  done
  die "Could not install app $1. Does ${STEAM_LOGIN} own it? Run the script again to resume."
}

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
write_config() {
  # Synergy's gameinfo.txt mounts Half-Life 2 from ../../Half-Life 2
  ln -sfn "$HL2_DIR" "${STEAM_HOME}/Half-Life 2"
  chown -h "$STEAM_USER:$STEAM_USER" "${STEAM_HOME}/Half-Life 2"
  # srcds segfaults without the Steam client library where it looks for it
  as_steam mkdir -p "${STEAM_HOME}/.steam/sdk32"
  as_steam ln -sfn "${STEAM_HOME}/.local/share/Steam/steamcmd/linux32/steamclient.so" "${STEAM_HOME}/.steam/sdk32/steamclient.so"
  cat > "${SYN_DIR}/synergy/cfg/server.cfg" << EOF
// Written by synergy-setup.sh; run it again to change these
hostname "${SV_NAME}"
sv_password "${SV_PASS}"
sv_lan 0
sv_region 255
EOF
  chown "$STEAM_USER:$STEAM_USER" "${SYN_DIR}/synergy/cfg/server.cfg"

  cat > "$SERVICE" << EOF
[Unit]
Description=Synergy dedicated server
After=network-online.target
Wants=network-online.target

[Service]
User=${STEAM_USER}
WorkingDirectory=${SYN_DIR}
# -nohltv: SourceTV would take 27020, which other Source servers use too
ExecStart=${SYN_DIR}/srcds_run -game synergy -console -norestart -nohltv -port ${PORT} +maxplayers ${SV_MAX} +map ${SV_MAP}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q synergy

  cat > "$CTL" << 'EOF'
#!/bin/sh
# Written by synergy-setup.sh
case "$1" in
  start) systemctl enable -q --now synergy && echo "Synergy started (also starts at boot)." ;;
  stop) systemctl disable -q --now synergy && echo "Synergy stopped (stays off after a reboot)." ;;
  restart) systemctl restart synergy && echo "Synergy restarted." ;;
  status) systemctl status synergy --no-pager -n 0 ;;
  log) journalctl -u synergy -f ;;
  *) echo "Usage: synergyctl start | stop | restart | status | log"; exit 1 ;;
esac
EOF
  chmod 755 "$CTL"
}

open_ports() {
  local p
  if command -v ufw > /dev/null && ufw status 2> /dev/null | grep -q 'Status: active'; then
    for p in "${PORT}/tcp" "${PORT}/udp"; do ufw allow "$p" > /dev/null; done
  fi
  if command -v firewall-cmd > /dev/null && [[ $(firewall-cmd --state 2> /dev/null) == running ]]; then
    for p in "${PORT}/tcp" "${PORT}/udp"; do firewall-cmd -q --permanent --add-port="$p" || true; done
    firewall-cmd -q --reload || true
  fi
}

start_server() {
  local i
  systemctl restart synergy
  say "Waiting for the server to load ${SV_MAP} ..."
  for i in $(seq 1 60); do
    if ss -Hlun "sport = :${PORT}" | grep -q .; then
      sleep 5
      systemctl is-active -q synergy && return 0
    fi
    systemctl is-active -q synergy || break
    sleep 2
  done
  journalctl -u synergy -n 40 --no-pager || true
  die "The server did not come up (journalctl -u synergy)."
}

# the interface's public address first: the outgoing IP can be a provider NAT that changes per request
public_ipv4() {
  local u ip
  ip=$(ip -4 -o addr show scope global | awk '{split($4, a, "/"); print a[1]}' \
    | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' | head -n 1) || true
  [[ -n $ip ]] && { printf '%s\n' "$ip"; return 0; }
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 10 "$u" 2> /dev/null | tr -d '[:space:]') || continue
    [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { printf '%s\n' "$ip"; return 0; }
  done
  hostname -I | awk '{print $1}'
}

main() {
  say "synergy-setup.sh -- log: ${LOG_FILE}"
  [[ -r /etc/os-release ]] && say "OS: $(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
  ask_all
  ensure_packages
  check_disk
  steam_login
  app_install 17520 "$SYN_DIR"
  app_install 220 "$HL2_DIR"
  write_config
  open_ports
  start_server
  local ip
  ip=$(public_ipv4)
  cat << EOF

[+] Done. In the game: open the console (~) and type
      ${SV_PASS:+password ${SV_PASS}; }connect ${ip}:${PORT}
    or Synergy > Find Servers > Favorites > add ${ip}:${PORT}

    Name       : ${SV_NAME}
    Players    : ${SV_MAX}
    Start map  : ${SV_MAP}
    Port       : ${PORT} (UDP+TCP)
    Start/stop : synergyctl start | stop | restart | status | log
    Change map : run this script again; the game also moves on by itself
    Update     : run this script again
    Open UDP/TCP ${PORT} in your provider's firewall too, if it has one.
EOF
}

main "$@"
