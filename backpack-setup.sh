#!/usr/bin/env bash
# =============================================================================
#  BackPack reverse tunnel, Iran -> kharej, managed from the kharej's 3x-ui
#
#  One command, run on the IRAN server. It reaches the kharej over SSH (root
#  password asked once, or your SSH key) and sets up both servers:
#    1. tests the route both ways (TCP, UDP, ICMP, SSH, GitHub access)
#       and, when 3x-ui is not on the kharej yet, runs 3xui-setup.sh there
#       (--kharej-domain); the panel login comes from /root/3xui-info.env
#    2. installs BackPack (github.com/AminMGMT/BackPack) on both servers;
#       when Iran cannot reach GitHub, the files come through the kharej
#    3. adds three VLESS Encryption inbounds on 127.0.0.1 to the panel, over
#       TCP, WS and XHTTP (no TLS, no SNI), and attaches the client to them
#    4. makes one tunnel per BackPack transport whose route passed step 1:
#       tcp tcpmux stealth pck kcp quic ws wsmux wss wssmux xdi
#    5. tests every tunnel end to end, adds one panel Host per working
#       transport (Iran IP + that tunnel's port), and serves the panel's
#       subscription from the Iran IP (it travels through the tunnels too)
#
#  Users, traffic and expiry stay in 3x-ui: every client attached to the
#  "BackPack TCP / WS / XHTTP" inbounds gets the tunnel links in its subscription.
#  With --domain the links and the subscription use an Iran domain, not the IP.
#  Run it again for a menu: update (newest BackPack, configs added since,
#  everything retested; ports and links are kept in
#  /root/backpack-tunnel-info.env) or uninstall.
#
#  Usage:
#    bash backpack-setup.sh --kharej-domain panel.example.com --domain ir.example.com <kharej-ip>
#    bash backpack-setup.sh                 (menu)
#    bash backpack-setup.sh update | uninstall
#
#  Based on BackPack by Amin Mohammadi (AminMGMT)
#  https://github.com/AminMGMT/BackPack
# =============================================================================
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

BP_REPO="${BP_REPO:-AminMGMT/BackPack}"
INFO_FILE="/root/backpack-tunnel-info.env"
LOG_FILE="/var/log/backpack-setup.log"
SUB_PY="/usr/local/lib/bpt-sub.py"
PREFIX="bpt" # tunnel names: bpt-tcp, bpt-kcp, ...
ALL_TRANSPORTS=(tcp tcpmux stealth pck kcp quic ws wsmux wss wssmux xdi)

XUI_SETUP_URL="${XUI_SETUP_URL:-https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh}"

ACTION=""
KH_IP=""
KH_DOMAIN=""
IR_DOMAIN=""
SSH_HOST=""
SSH_PORT=""
IRAN_IP=""
SUB_PORT=""
CTL="/root/.ssh/bpt-%r@%h:%p"
TEST_PID=""

say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
BackPack reverse tunnel (run on the Iran server), managed from the 3x-ui
panel that 3xui-setup.sh installed on the kharej.

Usage:
  bash backpack-setup.sh                      menu (update / uninstall)
  bash backpack-setup.sh [options] <kharej-ip>  install
  bash backpack-setup.sh update               newest BackPack, configs added
                                              since, everything retested
  bash backpack-setup.sh uninstall            remove the tunnels, the panel
                                              inbound and the subscription

Options:
  --domain <name>  Iran domain for the configs and the subscription (an A
                   record to this server; grey cloud on Cloudflare)
  --kharej-domain <name>
                   Panel domain for the kharej; when 3x-ui is not there yet,
                   3xui-setup.sh is run on the kharej with it
  --ssh-port <n>   SSH port of the kharej server (default 22, user root)
  --ssh-host <ip>  SSH management address when using a relay (default kharej-ip)
  --iran-ip <ip>   Public IP of this server for the configs (default: the
                   address the kharej sees)
  --sub-port <n>   Subscription port on this server (default 2095)
  -h, --help       Show this help
EOF
}

# --------------------------------------------------------------- shared ----
# The functions below also run on the kharej (shipped over SSH by kfn).

bp_install() { # <dir with backpack_linux_ARCH.tar.gz + SHA256SUMS> <arch>
  local dir=$1 asset="backpack_linux_$2.tar.gz"
  (cd "$dir" && grep -E "[ *]${asset}\$" SHA256SUMS | sha256sum -c --quiet -) ||
    { echo "[x] checksum mismatch for $asset" >&2; return 1; }
  mkdir -p /etc/backpack /root/BackPack/backups
  tar -xzf "$dir/$asset" -C "$dir" backpack
  install -m 0755 "$dir/backpack" /usr/local/bin/backpack
  rm -f "$dir/backpack"
  echo /root/BackPack > /etc/backpack/install_path
}

bp_clear() { # remove the tunnels an earlier run made
  local f n
  for f in /etc/backpack/bpt-*.toml; do
    [[ -e $f ]] || continue
    n=$(basename "$f" .toml)
    systemctl disable --now "backpack-$n.service" > /dev/null 2>&1 || true
    rm -f "$f" "/etc/systemd/system/backpack-$n.service"
  done
}

bp_apply() { # <name> <toml>; same unit BackPack writes, so its menu manages it
  local name=$1 conf="/etc/backpack/$1.toml"
  install -m 0600 /dev/null "$conf"
  printf '%s' "$2" > "$conf"
  if ! /usr/local/bin/backpack check -c "$conf" > /dev/null 2>&1; then
    echo "[!] $name: config rejected: $(/usr/local/bin/backpack check -c "$conf" 2>&1 | tail -n 3)" >&2
    rm -f "$conf"
    return 0
  fi
  cat > "/etc/systemd/system/backpack-$name.service" <<UNIT
[Unit]
Description=Backpack Tunnel ($name)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backpack -c $conf
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "backpack-$name.service" > /dev/null 2>&1
  systemctl restart "backpack-$name.service"
}

pkg_install() { # best effort: apt / dnf / yum
  if command -v apt-get > /dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=120 update -qq > /dev/null 2>&1 || true
    apt-get -o DPkg::Lock::Timeout=120 install -y -qq "$@" > /dev/null 2>&1 || true
  elif command -v dnf > /dev/null 2>&1; then
    dnf install -y -q "$@" > /dev/null 2>&1 || true
  elif command -v yum > /dev/null 2>&1; then
    yum install -y -q "$@" > /dev/null 2>&1 || true
  fi
}

bp_arch() {
  case $(uname -m) in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) echo "unsupported-$(uname -m)" ;;
  esac
}

# --------------------------------------------------------- kharej side ----

k_prep() { # prints: ARCH=… GH=0|1 XUI=0|1 IRAN_SEEN=…
  local need=() c
  for c in curl iptables python3; do command -v "$c" > /dev/null 2>&1 || need+=("$c"); done
  [[ ${#need[@]} -eq 0 ]] || pkg_install "${need[@]}"
  echo "ARCH=$(bp_arch)"
  if curl -fsSI -m 15 https://github.com > /dev/null 2>&1; then echo GH=1; else echo GH=0; fi
  if [[ -r /root/3xui-info.env ]] && command -v python3 > /dev/null 2>&1; then echo XUI=1; else echo XUI=0; fi
  local seen=${SSH_CLIENT:-}
  echo "IRAN_SEEN=${seen%% *}"
}

k_probe() { # <iran-ip> <port>: can the kharej reach Iran? (what a reverse tunnel needs)
  local ip=$1 port=$2 x=""
  if timeout 6 bash -c "exec 3<>/dev/tcp/$ip/$port" 2> /dev/null; then echo K2I_TCP=1; else echo K2I_TCP=0; fi
  # the Iran listener echoes "bp" back on UDP; head reads the whole datagram
  x=$(timeout 6 bash -c "exec 3<>/dev/udp/$ip/$port; printf bp >&3; timeout 4 head -c 2 <&3" 2> /dev/null || true)
  if [[ $x == bp ]]; then echo K2I_UDP=1; else echo K2I_UDP=0; fi
  if ping -c 3 -W 2 "$ip" > /dev/null 2>&1; then echo K2I_ICMP=1; else echo K2I_ICMP=0; fi
}

k_download() { # <arch>...: release files into /root/BackPack
  local a url="https://github.com/$BP_REPO/releases/latest/download"
  mkdir -p /root/BackPack
  curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 20 -m 120 -o /root/BackPack/SHA256SUMS "$url/SHA256SUMS"
  for a in "$@"; do
    curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 20 -m 300 -o "/root/BackPack/backpack_linux_$a.tar.gz" "$url/backpack_linux_$a.tar.gz"
  done
}

KFUNCS=(bp_install bp_clear bp_apply pkg_install bp_arch k_prep k_probe k_download)

# Runs on the kharej through the 3x-ui API (same login flow as 3xui-setup.sh).
#   prep                          -> TCP / WS / XHTTP inbounds + client; prints KEY=VALUE
#   hosts ADDR t:kind:port..      -> one Host per working link (transport x inbound)
#   test SUBID ADDR t:kind:port.. -> real VLESS clients through each Iran port
#   remove                        -> the Hosts and the inbounds (uninstall)
read -r -d '' PANEL_PY << 'PYEOF' || true
import concurrent.futures, glob, json, os, re, secrets, socket, string, subprocess, sys, tempfile, time
from urllib.parse import quote
MARK = "3xui-setup"
def die(*a): print("[x]", *a, file=sys.stderr, flush=True); sys.exit(1)
def warn(*a): print("[!]", *a, file=sys.stderr, flush=True)
def sh(cmd, t=60):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t, stdin=subprocess.DEVNULL).stdout.strip()
    except Exception:
        return ""
def curl(args, data=None, t=40):
    try:
        return subprocess.run(["curl", "-sk", "-m", str(t)] + args, input=data or "", capture_output=True,
                              text=True, timeout=t + 15).stdout
    except Exception:
        return ""
env = {}
for l in open("/root/3xui-info.env", encoding="utf-8"):
    m = re.match(r"^(\w+)='(.*)'$", l.strip())
    if m:
        env[m.group(1)] = m.group(2)
DOMAIN, PPORT = env.get("XUI_DOMAIN", ""), env.get("XUI_PANEL_PORT", "")
PPATH = env.get("XUI_WEB_BASE_PATH", "").strip("/")
if not (DOMAIN and PPORT):
    die("/root/3xui-info.env has no panel domain/port; run 3xui-setup.sh on the kharej first")
RES = ["--resolve", f"{DOMAIN}:{PPORT}:127.0.0.1"]
PANEL = ""
for scheme in ("https", "http"):
    u = f"{scheme}://{DOMAIN}:{PPORT}" + (f"/{PPATH}" if PPATH else "")
    if curl(RES + ["-o", "/dev/null", "-w", "%{http_code}", u + "/csrf-token"], t=6) not in ("", "000"):
        PANEL = u
        break
if not PANEL:
    die(f"the 3x-ui panel is not reachable on 127.0.0.1:{PPORT}")
TOKEN, TOKEN_ID = "", None
def api(path, body=None, post=False, t=40):
    a = RES + ["-H", f"Authorization: Bearer {TOKEN}"]
    if body is not None:
        a += ["-H", "Content-Type: application/json", "-X", "POST", "--data-binary", "@-"]
    elif post:
        a += ["-X", "POST"]
    out = curl(a + [PANEL + path], json.dumps(body) if body is not None else None, t)
    try:
        r = json.loads(out)
        return r if isinstance(r, dict) else {"success": False, "msg": out[:200]}
    except Exception:
        return {"success": False, "msg": out[:200]}
fd, cookie = tempfile.mkstemp(prefix=".bpt-panel.")
os.close(fd)
try:
    bc = RES + ["-c", cookie, "-b", cookie]
    def bpost(path, body):
        try:
            csrf = json.loads(curl(bc + [PANEL + "/csrf-token"], t=20)).get("obj", "") or ""
        except Exception:
            csrf = ""
        return curl(bc + ["-H", f"X-CSRF-Token: {csrf}", "-H", "Content-Type: application/json", "-X", "POST",
                          "--data-binary", "@-", PANEL + path], json.dumps(body), 20)
    if '"success":true' not in re.sub(r"\s", "", bpost("/login", {"username": env.get("XUI_USERNAME", ""),
                                                                  "password": env.get("XUI_PASSWORD", "")})):
        die("3x-ui login failed with the credentials in /root/3xui-info.env")
    try:
        o = json.loads(bpost("/panel/api/setting/apiTokens/create", {"name": f"backpack-setup-{int(time.time())}"}))["obj"]
        TOKEN, TOKEN_ID = o["token"], o["id"]
    except Exception:
        die("logged in, but could not create an API token (update the panel with 3xui-setup.sh --force-install)")
finally:
    os.remove(cookie)
import atexit
atexit.register(lambda: api(f"/panel/api/setting/apiTokens/delete/{TOKEN_ID}", post=True))
for need in ("/panel/api/clients/list", "/panel/api/hosts/list"):
    if not api(need).get("success"):
        die("this 3x-ui is too old (no Clients/Hosts); run 3xui-setup.sh --force-install on the kharej")

def field(ib, k):  # panels return these as a JSON string or already parsed
    v = ib.get(k)
    try:
        return (json.loads(v) if isinstance(v, str) and v else v) or {}
    except ValueError:
        return {}
def emails_of(ib):
    return [x.get("email") for x in field(ib, "settings").get("clients", []) if isinstance(x, dict)]
LEGACY = "🎒 BackPack tunnel"  # the REALITY inbound of earlier versions; replaced on update
KINDS = {"tcp": "🎒 BackPack TCP", "ws": "🎒 BackPack WS", "xh": "🎒 BackPack XHTTP"}
LABEL = {"tcp": "TCP", "ws": "WS", "xh": "XHTTP"}
XRAY = (glob.glob("/usr/local/x-ui/bin/xray-linux-*") or [""])[0]
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"], "metadataOnly": False, "routeOnly": True}
def inbounds():
    r = api("/panel/api/inbounds/list")
    if not r.get("success"):
        die("could not list inbounds:", r.get("msg"))
    return [i for i in r.get("obj") or [] if isinstance(i, dict)]
def by_remark():
    return {i.get("remark"): i for i in inbounds()}
def listening(pt):
    return "xray" in sh(f"ss -Htlnp 'sport = :{pt}'")
def vlessenc():
    out = sh(f"{XRAY} vlessenc").splitlines()
    for n, l in enumerate(out):
        if "X25519" in l and n + 2 < len(out):
            return out[n + 1].split('"')[3], out[n + 2].split('"')[3]
    die("the panel's Xray has no 'vlessenc'; update Xray-core in the panel")
def stream(kind):  # no TLS: VLESS Encryption is the security layer, as for ew/ex in 3xui-setup.sh
    s = {"network": {"tcp": "tcp", "ws": "ws", "xh": "xhttp"}[kind], "security": "none", "externalProxy": []}
    if kind == "tcp":
        s["tcpSettings"] = {"acceptProxyProtocol": False, "header": {"type": "none"}}
    elif kind == "ws":
        s["wsSettings"] = {"acceptProxyProtocol": False, "path": "/" + secrets.token_hex(5), "host": "",
                           "headers": {}, "heartbeatPeriod": 30}
    else:
        s["xhttpSettings"] = {"path": "/" + secrets.token_hex(5), "host": "", "mode": "auto",
                              "xPaddingBytes": "100-1000", "noSSEHeader": False,
                              "scMaxEachPostBytes": "1000000", "scMaxBufferedPosts": 30}
    return s

def drop_hosts(iid):
    old = api(f"/panel/api/hosts/byInbound/{iid}").get("obj") or []
    for gid in {h.get("groupId") for h in old if isinstance(h, dict) and str(h.get("remark", "")).startswith("🎒 BP ")}:
        if gid:
            r = api(f"/panel/api/hosts/del/{gid}", post=True)
            if not r.get("success"):
                die("could not remove an old tunnel Host:", r.get("msg"))

def drop(ib):  # one of our inbounds with its Hosts; clients keep their other inbounds
    drop_hosts(ib["id"])
    for e in emails_of(ib):
        if e:
            api(f"/panel/api/clients/{quote(e, safe='')}/detach", {"inboundIds": [ib["id"]]})
    r = api(f"/panel/api/inbounds/del/{ib['id']}", post=True)
    if not r.get("success"):
        die(f"could not delete inbound '{ib.get('remark')}':", r.get("msg"))

def prep():
    have = by_remark()
    if LEGACY in have:
        drop(have.pop(LEGACY))
        warn("removed the old REALITY tunnel inbound and its Hosts")
    used = {i.get("port") for i in have.values()}
    for kind, remark in KINDS.items():
        if remark in have:
            continue
        port = next(p for p in range(20443, 60000, 7) if p not in used and not sh(f"ss -Htln 'sport = :{p}'"))
        used.add(port)
        dec, enc = vlessenc()
        r = api("/panel/api/inbounds/add", {"up": 0, "down": 0, "total": 0, "remark": remark, "enable": True,
                                            "expiryTime": 0, "listen": "127.0.0.1", "port": port, "protocol": "vless",
                                            "settings": {"clients": [], "decryption": dec, "encryption": enc},
                                            "streamSettings": stream(kind), "sniffing": SNIFF})
        if not r.get("success"):
            die(f"the panel refused the {LABEL[kind]} tunnel inbound:", r.get("msg"))
    have = by_remark()
    mine = {k: have.get(r) for k, r in KINDS.items()}
    if not all(mine.values()):
        die("the tunnel inbounds were added but are not listed")
    clients = [c for c in api("/panel/api/clients/list").get("obj") or [] if isinstance(c, dict)]
    c = next((c for c in clients if c.get("comment") == MARK and c.get("subId")), None) or \
        next((c for c in clients if c.get("comment") == "backpack-setup" and c.get("subId")), None)
    ids = [ib["id"] for ib in mine.values()]
    if c:
        missing = [ib["id"] for ib in mine.values() if c["email"] not in emails_of(ib)]
        if missing:
            r = api(f"/panel/api/clients/{quote(c['email'], safe='')}/attach", {"inboundIds": missing})
            if not r.get("success"):  # e.g. attached already; the client test catches a real miss
                warn("attach client:", r.get("msg"))
    else:
        c = {"email": f"backpack-{secrets.token_hex(4)}", "flow": "xtls-rprx-vision",
             "subId": "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(16)),
             "totalGB": 0, "expiryTime": 0, "limitIp": 0, "enable": True, "tgId": 0, "comment": "backpack-setup"}
        r = api("/panel/api/clients/add", {"client": c, "inboundIds": ids})
        if not r.get("success"):
            die("could not create a client:", r.get("msg"))
    api("/panel/api/server/restartXrayService", post=True)
    for _ in range(12):
        time.sleep(1.5)
        if all(listening(ib["port"]) for ib in mine.values()):
            break
    else:
        die("Xray is not listening on the tunnel inbounds after the restart:",
            ", ".join(str(ib["port"]) for ib in mine.values()))
    r = api("/panel/api/setting/all", post=True)
    if not r.get("success"):
        die("could not read subscription settings:", r.get("msg"))
    s = r.get("obj") or {}
    if not s.get("subEnable") or not s.get("subJsonEnable") or "{{HOST}}" not in (s.get("remarkTemplate") or ""):
        s.update(subEnable=True, subJsonEnable=True)
        s["remarkTemplate"] = "{{HOST}}"
        r = api("/panel/api/setting/update", s)
        if not r.get("success"):
            die("could not enable subscriptions:", r.get("msg"))
        api("/panel/api/setting/restartPanel", post=True)
        time.sleep(8)
    norm = lambda p, d: "/" + (p or d).strip("/") + "/"
    out = {f"XP_{k}": ib["port"] for k, ib in mine.items()}
    out.update({"KDOMAIN": DOMAIN, "KSUB_PORT": int(s.get("subPort") or 2096),
                "KSUB_TLS": int(bool(s.get("subCertFile") and s.get("subKeyFile"))),
                "KSUB_PATH": norm(s.get("subPath"), "/sub/"), "SUB_ID": c["subId"], "CLIENT": c["email"]})
    for k, v in out.items():
        print(f"{k}={v}")

def remove():
    have, n = by_remark(), 0
    for remark in [LEGACY, *KINDS.values()]:
        if remark in have:
            drop(have[remark])
            n += 1
    if n:
        api("/panel/api/server/restartXrayService", post=True)
    print(f"REMOVED={n}")

def hosts(ip, pairs):  # pairs: transport:kind:port
    have = by_remark()
    mine = {k: have.get(r) for k, r in KINDS.items()}
    if not all(mine.values()):
        die("a tunnel inbound is gone; run the update again")
    for ib in mine.values():
        drop_hosts(ib["id"])
    n = 0
    for i, pair in enumerate(pairs):
        t, k, pt = pair.split(":")
        r = api("/panel/api/hosts/add", {"inboundIds": [mine[k]["id"]], "remark": f"🎒 BP {t} · {LABEL[k]}",
                                         "hosts": [ip], "port": int(pt), "security": "same", "sortOrder": i})
        n += bool(r.get("success"))
        if not r.get("success"):
            die(f"host {t} {LABEL[k]}: {r.get('msg')}")
    print(f"HOSTS={n}")

def test_clients(subid, ip, pairs):
    s = api("/panel/api/setting/all", post=True).get("obj") or {}
    port = int(s.get("subPort") or 2096)
    scheme = "https" if s.get("subCertFile") and s.get("subKeyFile") else "http"
    path = "/" + (s.get("subJsonPath") or "/json/").strip("/") + "/"
    try:
        configs = json.loads(curl(["--resolve", f"{DOMAIN}:{port}:127.0.0.1",
                                   f"{scheme}://{DOMAIN}:{port}{path}{subid}"]))
    except ValueError:
        die("could not read the JSON subscription for the client test")
    wanted = {int(p.split(":")[2]): "_".join(p.split(":")[:2]) for p in pairs}  # port -> transport_kind
    ins, outs, rules, meta, sockets = [], [], [], [], []
    proc = None
    try:
        for cfg in configs if isinstance(configs, list) else [configs]:
            out = next((o for o in cfg.get("outbounds", []) if o.get("tag") == "proxy"), {})
            settings = out.get("settings", {})
            server = next(iter(settings.get("vnext", [])), settings)
            if server.get("address") != ip or server.get("port") not in wanted:
                continue
            sock = socket.socket(); sock.bind(("127.0.0.1", 0)); sockets.append(sock)
            pt, tag = sock.getsockname()[1], f"test{len(outs)}"
            out["tag"] = tag; outs.append(out)
            ins.append({"tag": tag, "listen": "127.0.0.1", "port": pt, "protocol": "socks"})
            rules.append({"type": "field", "inboundTag": [tag], "outboundTag": tag})
            meta.append((wanted[server["port"]], pt))
        if len(meta) != len(pairs):
            die("the JSON subscription is missing tunnel configs")
        xray = glob.glob("/usr/local/x-ui/bin/xray-linux-*")[0]
        with tempfile.TemporaryDirectory(prefix="bpt-test-") as tmp:
            conf = os.path.join(tmp, "client.json")
            with open(conf, "w") as f:
                json.dump({"log": {"loglevel": "error"}, "inbounds": ins, "outbounds": outs,
                           "routing": {"rules": rules}}, f)
            for sock in sockets: sock.close()
            with open(os.path.join(tmp, "xray.log"), "w+") as log:
                proc = subprocess.Popen([xray, "run", "-c", conf], stdout=log, stderr=log)
                time.sleep(2)
                if proc.poll() is not None:
                    log.seek(0); die("test Xray failed:", log.read()[-1500:])
                def probe(item):
                    name, pt = item
                    code = curl(["--no-insecure", "--socks5-hostname", f"127.0.0.1:{pt}", "-o", "/dev/null",
                                 "-w", "%{http_code}", "https://www.google.com/generate_204"], t=20)
                    return name, code == "204"
                with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                    for name, ok in pool.map(probe, meta):
                        print(f"E2E_{name}={'ok' if ok else 'FAIL'}", flush=True)
    finally:
        for sock in sockets: sock.close()
        if proc and proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()

if sys.argv[1] == "prep":
    prep()
elif sys.argv[1] == "hosts":
    hosts(sys.argv[2], sys.argv[3:])
elif sys.argv[1] == "test":
    test_clients(sys.argv[2], sys.argv[3], sys.argv[4:])
elif sys.argv[1] == "remove":
    remove()
PYEOF

# Iran: serves the panel's subscription, fetched through any working tunnel.
read -r -d '' SUB_PROXY_PY << 'PYEOF' || true
import http.client, http.server, re, socket, ssl, sys
from urllib.parse import urlsplit
PORT, HOST, TLS, UPS = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1", [int(p) for p in sys.argv[4].split(",") if p]
PATH = sys.argv[5]
CTX = ssl.create_default_context()
CTX.check_hostname, CTX.verify_mode = False, ssl.CERT_NONE  # the hop is inside the tunnel
SKIP = {"content-length", "connection", "transfer-encoding", "keep-alive", "date", "server"}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        target = urlsplit(self.path)
        if target.scheme or target.netloc or not re.fullmatch(re.escape(PATH) + r"[A-Za-z0-9_-]+/?", target.path):
            self.send_error(404)
            return
        for up in UPS:
            c = None
            try:
                if TLS:
                    c = http.client.HTTPSConnection(HOST, up, timeout=15, context=CTX)
                else:
                    c = http.client.HTTPConnection(HOST, up, timeout=15)
                c._create_connection = lambda a, *x, up=up, **k: socket.create_connection(("127.0.0.1", up), *x, **k)
                c.request("GET", self.path, headers={"Host": HOST, "User-Agent": self.headers.get("User-Agent", ""),
                                                     "Accept": self.headers.get("Accept", "*/*")})
                r = c.getresponse()
                body = r.read()
                if r.status >= 500:
                    continue
            except Exception:
                continue
            finally:
                if c:
                    c.close()
            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() not in SKIP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(502, "no tunnel reached the panel")
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF

# ------------------------------------------------------------ Iran side ----

_on_err() {
  local rc=$? line=$1
  trap - ERR
  printf '\n[x] Setup failed at line %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}

cleanup() {
  [[ -n $TEST_PID ]] && kill "$TEST_PID" 2> /dev/null
  [[ -n $KH_IP ]] && ssh -o ControlPath="$CTL" -O exit -p "$SSH_PORT" "root@${SSH_HOST:-$KH_IP}" > /dev/null 2>&1
  return 0
}

kh() { ssh -o ControlPath="$CTL" -o BatchMode=yes -p "$SSH_PORT" "root@${SSH_HOST:-$KH_IP}" "$@"; }

kfn() { # run one of KFUNCS on the kharej with these arguments
  kh "bash -s" <<< "set -Eeuo pipefail; export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
$(declare -p BP_REPO)
$(declare -f "${KFUNCS[@]}")
$(printf '%q ' "$@") < /dev/null"
}

kpanel() { kh "python3 - $(printf '%q ' "$@")" <<< "$PANEL_PY"; } # 3x-ui API on the kharej

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --ssh-port) SSH_PORT=${2:?}; shift 2 ;;
      --ssh-host) SSH_HOST=${2:?}; shift 2 ;;
      --iran-ip) IRAN_IP=${2:?}; shift 2 ;;
      --sub-port) SUB_PORT=${2:?}; shift 2 ;;
      --domain) IR_DOMAIN=${2:?}; shift 2 ;;
      --kharej-domain) KH_DOMAIN=${2:?}; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      install | update | uninstall) ACTION=$1; shift ;;
      -*) die "Unknown option: $1 (see --help)" ;;
      *) KH_IP=$1; ACTION=${ACTION:-install}; shift ;;
    esac
  done
  [[ -z $KH_IP || $KH_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Not an IPv4 address: $KH_IP"
  is_domain "$IR_DOMAIN" || die "Not a domain: $IR_DOMAIN"
  is_domain "$KH_DOMAIN" || die "Not a domain: $KH_DOMAIN"
  [[ -z $SSH_HOST || $SSH_HOST =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Not an IPv4 SSH address: $SSH_HOST"
  [[ -z $IRAN_IP || $IRAN_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Not an IPv4 address: $IRAN_IP"
  FIXED_IRAN_IP=$IRAN_IP # only a given one is saved; otherwise it is re-detected each run
  [[ -z $SSH_PORT || ( $SSH_PORT =~ ^[0-9]{1,5}$ && $((10#$SSH_PORT)) -ge 1 && $((10#$SSH_PORT)) -le 65535 ) ]] || die "Invalid SSH port"
  [[ -z $SUB_PORT || ( $SUB_PORT =~ ^[0-9]{1,5}$ && $((10#$SUB_PORT)) -ge 1 && $((10#$SUB_PORT)) -le 65535 ) ]] || die "Invalid subscription port"
}

is_domain() { [[ -z $1 || $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; } # empty is fine

ask() { # <var> <prompt>: read from the terminal; empty when there is none
  [[ -r /dev/tty ]] || return 0
  read -rp "$2" "$1" < /dev/tty || true
}

port_busy() { ss -Htuln 2> /dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }

free_port() { # <var> <start>: first port from start that nothing uses and we did not take
  local -n _out=$1
  local p=$2
  while port_busy "$p" || [[ " $TAKEN " == *" $p "* ]]; do p=$((p + 1)); done
  TAKEN+=" $p"
  _out=$p
}

token_for() { printf '%s-%s' "$TOKEN_BASE" "$1" | sha256sum | cut -c1-32; }

open_port() { # <port> <tcp|udp>
  if command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q '^Status: active'; then
    ufw allow "$1/$2" > /dev/null
  elif command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1; then
    firewall-cmd -q --permanent --add-port="$1/$2" && firewall-cmd -q --reload
  fi
}

kv() { sed -n "s/^$1=//p" <<< "$2"; } # <key> <KEY=VALUE lines>

ssh_connect() {
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  say "SSH to root@${SSH_HOST:-$KH_IP}:$SSH_PORT (enter the kharej root password if asked)"
  ssh -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=30m \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 -p "$SSH_PORT" -fN "root@${SSH_HOST:-$KH_IP}" ||
    die "SSH login to the kharej failed (password, port, or a changed host key: ssh-keygen -R $KH_IP)"
}

start_probe_listener() { # TCP accept + UDP echo on this port, for 60 s
  python3 - "$1" > /dev/null 2>&1 <<'PY' &
import socket, sys, threading
p = int(sys.argv[1])
t = socket.socket(); t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
t.bind(("", p)); t.listen(8); t.settimeout(60)
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("", p)); u.settimeout(60)
def tcp():
    try:
        while True: t.accept()[0].close()
    except Exception: pass
threading.Thread(target=tcp, daemon=True).start()
try:
    while True:
        d, a = u.recvfrom(64); u.sendto(d, a)
except Exception: pass
PY
  TEST_PID=$!
  sleep 1
}

mark() { [[ $1 == 1 ]] && echo ok || echo FAIL; }

run_tests() {
  say "Step 1: route tests"
  local i2k_icmp=0 i2k_tcp=0 out seen probe t
  ping -c 3 -W 2 "$KH_IP" > /dev/null 2>&1 && i2k_icmp=1
  timeout 6 bash -c "exec 3<>/dev/tcp/${SSH_HOST:-$KH_IP}/$SSH_PORT" 2> /dev/null && i2k_tcp=1
  [[ $i2k_tcp == 1 ]] || die "Iran cannot open TCP to ${SSH_HOST:-$KH_IP}:$SSH_PORT. Check the SSH address/port and firewall."
  IR_GH=0
  curl -fsSI -m 15 https://github.com > /dev/null 2>&1 && IR_GH=1

  ssh_connect
  out=$(kfn k_prep)
  KH_ARCH=$(kv ARCH "$out")
  seen=$(kv IRAN_SEEN "$out")
  [[ -n $IRAN_IP ]] || IRAN_IP=$seen
  [[ $IRAN_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Could not tell this server's public IPv4; pass --iran-ip"
  IR_ARCH=$(bp_arch)
  [[ $KH_ARCH != unsupported-* && $IR_ARCH != unsupported-* ]] || die "BackPack ships amd64 and arm64 only (Iran: $IR_ARCH, kharej: $KH_ARCH)"
  [[ $(kv GH "$out") == 1 ]] || die "The kharej server cannot reach GitHub, so nothing can be downloaded."
  XUI=$(kv XUI "$out")

  # The reverse tunnel is dialled by the kharej, so this direction decides.
  free_port probe 4100
  open_port "$probe" tcp
  open_port "$probe" udp
  start_probe_listener "$probe"
  out=$(kfn k_probe "$IRAN_IP" "$probe")
  kill "$TEST_PID" 2> /dev/null || true
  TEST_PID=""
  K2I_TCP=$(kv K2I_TCP "$out")
  K2I_UDP=$(kv K2I_UDP "$out")
  K2I_ICMP=$(kv K2I_ICMP "$out")

  printf '\n  %-34s %s\n' "Iran -> kharej ping (ICMP)" "$(mark $i2k_icmp)"
  printf '  %-34s %s\n' "Iran -> kharej TCP / SSH" ok
  printf '  %-34s %s\n' "kharej -> Iran TCP :$probe" "$(mark "$K2I_TCP")"
  printf '  %-34s %s\n' "kharej -> Iran UDP :$probe" "$(mark "$K2I_UDP")"
  printf '  %-34s %s\n' "kharej -> Iran ping (ICMP)" "$(mark "$K2I_ICMP")"
  printf '  %-34s %s\n' "Iran -> GitHub" "$(mark "$IR_GH")"
  printf '  %-34s %s\n' "kharej -> GitHub" ok
  printf '  %-34s %s\n\n' "3x-ui on the kharej" "$([[ $XUI == 1 ]] && echo found || echo "not yet (3xui-setup.sh runs next)")"
  [[ $K2I_TCP == 1 ]] || die "The kharej cannot open TCP to this server; the subscription and every TCP transport need it. Check the Iran provider firewall."
  [[ $K2I_UDP == 1 ]] || warn "UDP to Iran failed (also check the provider firewall): kcp and quic are skipped."
  [[ $K2I_ICMP == 1 ]] || warn "Ping to Iran failed: xdi is skipped."

  TRANSPORTS=()
  for t in "${ALL_TRANSPORTS[@]}"; do
    case $t in
      kcp | quic) [[ $K2I_UDP == 1 ]] && TRANSPORTS+=("$t") ;;
      xdi) [[ $K2I_ICMP == 1 ]] && TRANSPORTS+=("$t") ;;
      *) TRANSPORTS+=("$t") ;;
    esac
  done
  return 0
}

install_xui() { # the direct-method script, run on the kharej over the same SSH
  [[ -n $KH_DOMAIN ]] || ask KH_DOMAIN "3x-ui is not on the kharej. Its panel domain (A record -> $KH_IP): "
  [[ -n $KH_DOMAIN ]] || die "3x-ui is not on the kharej; pass --kharej-domain <panel domain>"
  is_domain "$KH_DOMAIN" || die "Not a domain: $KH_DOMAIN"
  # the tunnel flow from the README: no direct configs, certificates off 80/443
  say "Installing 3x-ui on the kharej: 3xui-setup.sh --no-inbounds --acme-port 18080 $KH_DOMAIN"
  kh "curl -fsSL -m 60 $(printf '%q' "$XUI_SETUP_URL") -o /root/3xui-setup.sh && bash /root/3xui-setup.sh --no-inbounds --acme-port 18080 $(printf '%q' "$KH_DOMAIN")" < /dev/null ||
    die "3xui-setup.sh failed on the kharej (its log: /var/log/3xui-setup.log there)"
  [[ $(kv XUI "$(kfn k_prep)") == 1 ]] || die "3xui-setup.sh finished, but /root/3xui-info.env is missing on the kharej"
}

check_domain() { # the configs only work when the Iran domain points here
  [[ -n $IR_DOMAIN ]] || return 0
  local ip
  ip=$(getent ahostsv4 "$IR_DOMAIN" 2> /dev/null | awk 'NR == 1 {print $1}' || true)
  [[ $ip == "$IRAN_IP" ]] ||
    die "$IR_DOMAIN points to ${ip:-nothing}, not this server ($IRAN_IP). Set an A record (grey cloud on Cloudflare) and re-run."
}

install_backpack() {
  say "Step 2: BackPack on both servers"
  local archs=("$KH_ARCH") url="https://github.com/$BP_REPO/releases/latest/download" got=0
  [[ $IR_ARCH == "$KH_ARCH" ]] || archs+=("$IR_ARCH")
  kfn k_download "${archs[@]}"
  kfn bp_install /root/BackPack "$KH_ARCH"

  mkdir -p /root/BackPack
  if [[ $IR_GH == 1 ]] &&
    curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 20 -m 120 -o /root/BackPack/SHA256SUMS "$url/SHA256SUMS" &&
    curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 20 -m 300 -o "/root/BackPack/backpack_linux_$IR_ARCH.tar.gz" "$url/backpack_linux_$IR_ARCH.tar.gz"; then
    got=1
  fi
  if [[ $got == 0 ]]; then
    say "Copying the BackPack release from the kharej"
    kh cat /root/BackPack/SHA256SUMS > /root/BackPack/SHA256SUMS
    kh cat "/root/BackPack/backpack_linux_$IR_ARCH.tar.gz" > "/root/BackPack/backpack_linux_$IR_ARCH.tar.gz"
  fi
  bp_install /root/BackPack "$IR_ARCH"
  say "BackPack $(/usr/local/bin/backpack version 2> /dev/null | head -n 1)"
}

load_saved() {
  [[ -f $INFO_FILE ]] || return 0
  local saved_kh cli_ip=$IRAN_IP cli_sub=$SUB_PORT cli_dom=$IR_DOMAIN cli_sp=$SSH_PORT cli_sh=$SSH_HOST
  saved_kh=$(sed -n 's/^KH_IP=//p' "$INFO_FILE")
  if [[ -n $KH_IP && $saved_kh != "$KH_IP" ]]; then
    warn "Saved settings are for kharej $saved_kh; starting fresh for $KH_IP."
    return 0
  fi
  # shellcheck disable=SC1090
  . "$INFO_FILE"
  IRAN_IP=${cli_ip:-${FIXED_IRAN_IP:-}} # the address the kharej sees now, unless one was given
  FIXED_IRAN_IP=$IRAN_IP
  [[ -n $cli_sub ]] && SUB_PORT=$cli_sub
  [[ -n $cli_dom ]] && IR_DOMAIN=$cli_dom
  [[ -n $cli_sp ]] && SSH_PORT=$cli_sp
  [[ -n $cli_sh ]] && SSH_HOST=$cli_sh
  # old REALITY ports (PUB_<transport>) are free again once the tunnels are rebuilt
  TAKEN+=" $(grep -E '^(TUN_|SFW_|PUB_(tcp|ws|xh)_)' "$INFO_FILE" | cut -d= -f2 | tr '\n' ' ')"
  say "Reusing the tunnel ports and subscription port from $INFO_FILE"
}

KINDS=(tcp ws xh) # panel inbounds every tunnel forwards to: VLESS Encryption over TCP, WS, XHTTP

kind_label() { case $1 in tcp) echo TCP ;; ws) echo WS ;; xh) echo XHTTP ;; esac; }

setup_panel() {
  say "Step 3: TCP, WS and XHTTP tunnel inbounds in the kharej's 3x-ui"
  local out k
  out=$(kpanel prep)
  for k in XP_tcp XP_ws XP_xh KDOMAIN KSUB_PORT KSUB_TLS KSUB_PATH SUB_ID CLIENT; do
    printf -v "$k" '%s' "$(kv "$k" "$out")"
    [[ -n ${!k} ]] || die "The panel step returned no $k"
  done
  local scheme=http
  [[ $KSUB_TLS == 1 ]] && scheme=https
  PANEL_SUB_URL="$scheme://$KDOMAIN:$KSUB_PORT$KSUB_PATH$SUB_ID"
  say "Inbounds on kharej 127.0.0.1 (VLESS Encryption): TCP $XP_tcp, WS $XP_ws, XHTTP $XP_xh; client $CLIENT"
}

# Tuning: the values BackPack's own "turbo" preset writes.
render() { # <server|client> <transport>
  local role=$1 t=$2 tun_var="TUN_$2" sfw_var="SFW_$2" k v x
  printf '# Generated by backpack-setup.sh (bpt)\n# name = "%s-%s"\n\n' "$PREFIX" "$t"
  if [[ $role == server ]]; then
    printf '[server]\nbind_addr = "0.0.0.0:%s"\n' "${!tun_var}"
  else
    printf '[client]\nremote_addr = "%s:%s"\n' "$IRAN_IP" "${!tun_var}"
  fi
  printf 'transport = "%s"\npreset = "turbo"\ntoken = "%s"\n' "$t" "$(token_for "$t")"
  case $t in tcp | tcpmux | ws | wsmux) [[ $role == client ]] && printf 'peer_auth = "required"\n' ;; esac
  printf 'keepalive_period = 75\nnodelay = true\nlog_level = "info"\n'
  if [[ $role == server ]]; then
    printf 'channel_size = 4096\nheartbeat = 40\naccept_udp = false\n'
  else
    printf 'connection_pool = 8\naggressive_pool = false\nretry_interval = 3\ndial_timeout = 10\n'
  fi
  case $t in
    kcp | quic | pck | xdi) printf 'so_rcvbuf = 8388608\nso_sndbuf = 8388608\n' ;;
  esac
  case $t in
    kcp | pck | xdi)
      printf 'kcp_mtu = 1250\nkcp_interval = 10\nkcp_resend = 2\nkcp_nodelay = 1\nkcp_nocongestion = 1\n'
      printf 'kcp_sndwnd = 1024\nkcp_rcvwnd = 1024\nkcp_acknodelay = true\nkcp_datashards = 10\nkcp_parityshards = 3\n'
      ;;
  esac
  case $t in
    tcpmux | wsmux | wssmux)
      if [[ $role == server ]]; then printf 'mux_con = 8\n'; else printf 'mux_session = 8\n'; fi
      printf 'mux_version = 2\nmux_framesize = 32768\nmux_recievebuffer = 16777216\nmux_streambuffer = 2097152\n'
      ;;
  esac
  printf 'sniffer = false\n'
  if [[ $role == server ]]; then
    # users -> the TCP / WS / XHTTP inbounds; loopback -> the panel's subscription (for bpt-sub)
    printf 'ports = [\n'
    for k in "${KINDS[@]}"; do
      v="PUB_${k}_$t" x="XP_$k"
      printf '    "%s=127.0.0.1:%s",\n' "${!v}" "${!x}"
    done
    printf '    "127.0.0.1:%s=127.0.0.1:%s",\n]\n' "${!sfw_var}" "$KSUB_PORT"
  fi
  return 0
}

setup_tunnels() {
  say "Step 4: tunnels (${TRANSPORTS[*]})"
  command -v iptables > /dev/null 2>&1 || warn "iptables is missing on Iran: pck will be unreliable."
  bp_clear
  kfn bp_clear
  local t k v tun_var sfw_var
  for t in "${TRANSPORTS[@]}"; do
    tun_var="TUN_$t" sfw_var="SFW_$t"
    [[ -n ${!tun_var:-} ]] || free_port "$tun_var" 4101
    [[ -n ${!sfw_var:-} ]] || free_port "$sfw_var" 4201
    for k in "${KINDS[@]}"; do
      v="PUB_${k}_$t"
      [[ -n ${!v:-} ]] || free_port "$v" 2101
      open_port "${!v}" tcp
    done
    case $t in
      kcp | quic) open_port "${!tun_var}" udp ;;
      xdi) ;;
      *) open_port "${!tun_var}" tcp ;;
    esac
    bp_apply "$PREFIX-$t" "$(render server "$t")"
    kfn bp_apply "$PREFIX-$t" "$(render client "$t")"
  done
}

# The panel's subscription server answers through each tunnel's loopback
# forward, so any HTTP answer there means Iran -> tunnel -> kharej works.
tunnel_up() { # <loopback forward port>
  local code scheme=http
  [[ $KSUB_TLS == 1 ]] && scheme=https
  code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$scheme://127.0.0.1:$1/" 2> /dev/null || true)
  [[ -n $code && $code != 000 ]]
}

test_tunnels() {
  say "Step 5: waiting for the tunnels to connect (up to 90 s)"
  UP=() WORKING=()
  local pending=("${TRANSPORTS[@]}") left t sfw_var deadline=$((SECONDS + 90))
  declare -gA RESULT=() LINK=()
  while [[ ${#pending[@]} -gt 0 && $SECONDS -lt $deadline ]]; do
    sleep 5
    left=()
    for t in "${pending[@]}"; do
      sfw_var="SFW_$t"
      if tunnel_up "${!sfw_var}"; then RESULT[$t]=up; else left+=("$t"); fi
    done
    pending=("${left[@]}")
  done
  for t in "${TRANSPORTS[@]}"; do
    [[ ${RESULT[$t]:-} == up ]] && UP+=("$t")
  done
  return 0
}

setup_hosts_and_sub() {
  local t k v p pairs=() ups="" out
  if [[ ${#UP[@]} -eq 0 ]]; then
    warn "No tunnel connected, so the panel Hosts and the subscription are left as they were."
    return 0
  fi
  for t in "${UP[@]}"; do
    v="SFW_$t"
    ups+="${ups:+,}${!v}"
    for k in "${KINDS[@]}"; do
      v="PUB_${k}_$t"
      pairs+=("$t:$k:${!v}")
    done
  done
  out=$(kpanel hosts "$ADDR" "${pairs[@]}")
  [[ $(kv HOSTS "$out") == "${#pairs[@]}" ]] || die "Not all tunnel Hosts were added"
  say "Testing ${#pairs[@]} links with real VLESS clients through the Iran ports to the internet"
  out=$(kpanel test "$SUB_ID" "$ADDR" "${pairs[@]}")
  for p in "${pairs[@]}"; do
    IFS=: read -r t k _ <<< "$p"
    LINK[${t}_$k]=$(kv "E2E_${t}_$k" "$out")
    [[ ${LINK[${t}_$k]} == ok ]] && WORKING+=("$p")
  done
  [[ ${#WORKING[@]} -gt 0 ]] || die "No VLESS client passed the internet test"
  out=$(kpanel hosts "$ADDR" "${WORKING[@]}")
  [[ $(kv HOSTS "$out") == "${#WORKING[@]}" ]] || die "Could not refresh the tested tunnel Hosts"
  say "Panel Hosts: ${#WORKING[@]} working links"

  [[ -n ${SUB_PORT:-} ]] || free_port SUB_PORT 2095
  mkdir -p "$(dirname "$SUB_PY")"
  printf '%s\n' "$SUB_PROXY_PY" > "$SUB_PY"
  cat > /etc/systemd/system/bpt-sub.service <<UNIT
[Unit]
Description=3x-ui subscription through the BackPack tunnels (bpt)
After=network.target

[Service]
ExecStart=/usr/bin/env python3 $SUB_PY $SUB_PORT $KDOMAIN $KSUB_TLS $ups $KSUB_PATH
DynamicUser=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable bpt-sub.service > /dev/null 2>&1
  systemctl restart bpt-sub.service
  open_port "$SUB_PORT" tcp
  SUB_URL="http://$ADDR:$SUB_PORT$KSUB_PATH$SUB_ID"

  # the subscription must come back through the tunnel with the Iran links in it
  local raw body="" i
  for i in 1 2 3 4 5; do
    sleep 2
    raw=$(curl -fs -m 15 "http://127.0.0.1:$SUB_PORT$KSUB_PATH$SUB_ID" 2> /dev/null || true)
    body=$(base64 -d <<< "$raw" 2> /dev/null || true)
    [[ $body == *"://"* ]] || body=$raw # the panel can serve it without base64
    [[ -n $body ]] && break
  done
  SUB_LINKS=$(grep -c "@$ADDR:" <<< "$body" || true)
  [[ $SUB_LINKS -ge ${#WORKING[@]} ]] || die "The subscription is missing tunnel links (journalctl -u bpt-sub)"
}

write_info() {
  local t k v
  install -m 0600 /dev/null "$INFO_FILE"
  {
    printf 'KH_IP=%s\nTOKEN_BASE=%s\nSUB_PORT=%s\n' "$KH_IP" "$TOKEN_BASE" "${SUB_PORT:-}"
    printf 'SSH_PORT=%s\nSSH_HOST=%s\nIR_DOMAIN=%s\nFIXED_IRAN_IP=%s\n' "$SSH_PORT" "$SSH_HOST" "$IR_DOMAIN" "$FIXED_IRAN_IP"
    printf 'SUB_URL=%q\nPANEL_SUB_URL=%q\n' "${SUB_URL:-}" "${PANEL_SUB_URL:-}"
    for t in "${ALL_TRANSPORTS[@]}"; do
      for v in "TUN_$t" "SFW_$t" "PUB_tcp_$t" "PUB_ws_$t" "PUB_xh_$t"; do
        [[ -n ${!v:-} ]] && printf '%s=%s\n' "$v" "${!v}"
      done
    done
  } > "$INFO_FILE"
  return 0
}

print_summary() {
  local t k v tun_var cells
  printf '\n==============================================================\n'
  printf ' BackPack tunnels  (Iran %s  <-  kharej %s)\n' "$IRAN_IP" "$KH_IP"
  printf '==============================================================\n'
  printf ' %-9s %-7s %-11s %-11s %s\n' transport tunnel TCP WS XHTTP
  for t in "${ALL_TRANSPORTS[@]}"; do
    tun_var="TUN_$t"
    if [[ " ${TRANSPORTS[*]} " != *" $t "* ]]; then
      printf ' %-9s skipped (route test)\n' "$t"
    elif [[ ${RESULT[$t]:-} != up ]]; then
      printf ' %-9s %-7s did not connect\n' "$t" "${!tun_var}"
    else
      cells=()
      for k in "${KINDS[@]}"; do
        v="PUB_${k}_$t"
        cells+=("${!v} ${LINK[${t}_$k]:-FAIL}")
      done
      printf ' %-9s %-7s %-11s %-11s %s\n' "$t" "${!tun_var}" "${cells[@]}"
    fi
  done
  if [[ ${#WORKING[@]} -gt 0 ]]; then
    printf '\n 3x-ui: inbounds "🎒 BackPack TCP / WS / XHTTP" with %s Hosts (one per working link).\n' "${#WORKING[@]}"
    printf ' Every client attached to these inbounds gets the links; client %s is.\n' "$CLIENT"
    printf ' Tunnel links in the subscription: %s\n' "${SUB_LINKS:-0}"
    command -v qrencode > /dev/null 2>&1 || pkg_install qrencode
    command -v qrencode > /dev/null 2>&1 && qrencode -t UTF8 -m 2 -l M "$SUB_URL"
    printf '\n Subscription via Iran (%s):\n   %s\n' "$CLIENT" "$SUB_URL"
    if [[ $KSUB_TLS == 1 ]]; then
      printf ' HTTPS subscription (same Iran configs, useful when HTTP is filtered):\n   %s\n' "$PANEL_SUB_URL"
    fi
    printf ' For any other client: http://%s:%s%s<its subId>\n' "$ADDR" "$SUB_PORT" "$KSUB_PATH"
  else
    warn "No link passed the end-to-end test. Logs: journalctl -u backpack-$PREFIX-tcp -n 50 (on both servers)"
  fi
  printf '\n Settings: %s   Manage tunnels: backpack tunnel list, sudo backpack\n' "$INFO_FILE"
  printf ' Open the user ports (TCP) and tunnel ports (TCP, UDP for kcp/quic)\n'
  printf ' in the Iran provider firewall too. A FAIL link may still come up;\n'
  printf ' run the update to retest and refresh the panel Hosts.\n'
  printf '==============================================================\n'
}

do_install() { # install, or update: newest BackPack, configs added since, everything retested
  [[ -n $KH_IP ]] || ask KH_IP "Kharej server IP: "
  [[ $KH_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Give the kharej IP: bash backpack-setup.sh <kharej-ip>"
  if [[ ! -f $INFO_FILE && -z $IR_DOMAIN ]]; then
    ask IR_DOMAIN "Iran domain for the configs (A record -> this server; Enter = use the IP): "
    is_domain "$IR_DOMAIN" || die "Not a domain: $IR_DOMAIN"
  fi
  say "$(date -Is) $ACTION -> kharej $KH_IP"
  [[ -n ${TOKEN_BASE:-} ]] || TOKEN_BASE=$(openssl rand -hex 16)
  run_tests
  check_domain
  ADDR=${IR_DOMAIN:-$IRAN_IP}
  [[ $XUI == 1 ]] || install_xui
  install_backpack
  setup_panel
  setup_tunnels
  write_info
  test_tunnels
  setup_hosts_and_sub
  write_info
  print_summary
  [[ ${#WORKING[@]} -gt 0 ]] || die "No working link"
}

do_uninstall() {
  [[ -n $KH_IP ]] || die "Nothing to uninstall ($INFO_FILE is missing)."
  local a=""
  ask a "Remove the bpt tunnels on both servers, the subscription service and the panel's BackPack inbounds? [y/N] "
  [[ $a == [yY]* ]] || die "Cancelled."
  say "$(date -Is) uninstall -> kharej $KH_IP"
  bp_clear
  systemctl disable --now bpt-sub.service > /dev/null 2>&1 || true
  rm -f /etc/systemd/system/bpt-sub.service "$SUB_PY"
  systemctl daemon-reload
  ssh_connect
  if [[ $(kv XUI "$(kfn k_prep)") == 1 ]]; then
    say "Panel: $(kv REMOVED "$(kpanel remove)") BackPack inbound(s) and their Hosts removed (clients keep their other inbounds)"
  fi
  kfn bp_clear
  rm -f "$INFO_FILE" # last, so a failed run can be repeated
  say "Done. BackPack and 3x-ui stay installed (sudo backpack -> Uninstall removes BackPack)."
}

choose_action() {
  if [[ ! -f $INFO_FILE ]]; then
    ACTION=install
    return 0
  fi
  printf '\n BackPack tunnels (kharej %s)\n' "$KH_IP"
  printf '  1) Update: newest BackPack, new configs, retest everything\n  2) Uninstall\n'
  local c=""
  ask c "Choose [1-2]: "
  case $c in
    1) ACTION=update ;;
    2) ACTION=uninstall ;;
    *) die "Nothing chosen." ;;
  esac
}

main() {
  parse_args "$@"
  [[ $EUID -eq 0 ]] || die "Run as root (sudo -i first)."
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap '_on_err $LINENO' ERR
  trap cleanup EXIT

  local need=() c
  for c in curl ssh python3 openssl iptables; do command -v "$c" > /dev/null 2>&1 || need+=("$c"); done
  if [[ ${#need[@]} -gt 0 ]]; then
    say "Installing: ${need[*]}"
    pkg_install curl openssh-client python3 openssl iptables
  fi
  for c in curl ssh python3 openssl; do command -v "$c" > /dev/null 2>&1 || die "$c is missing and could not be installed"; done

  TAKEN=""
  load_saved
  : "${SSH_PORT:=22}"
  # through a relay the kharej sees the relay's address, not this server's
  [[ -z $SSH_HOST || -n $IRAN_IP ]] || die "--ssh-host needs --iran-ip as well"
  [[ -n $ACTION ]] || choose_action
  case $ACTION in
    install | update) do_install ;;
    uninstall) do_uninstall ;;
  esac
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi # also when piped to bash
