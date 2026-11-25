# my-scripts

Personal scripts for deploying apps and running services on a Linux VPS,
plus local generators for Flutter and React projects. Run the server setup
scripts as root. Use the generators from your development environment.

| Task | Setup | Day-to-day command |
| --- | --- | --- |
| Set up a 3x-ui panel and proxy configs | [3xui-setup.sh](#3xui-setupsh) | `x-ui` or re-run the setup script to add configs |
| Tunnel an Iran server to a kharej server with BackPack | [backpack-setup.sh](#backpack-setupsh) | re-run the script for its menu, or `sudo backpack` |
| Run AdGuard Home and a DNS relay | [dns-setup.sh](#dns-setupsh) | `dnsctl` |
| Run an AmneziaWG server for gaming | [game-setup.sh](#game-setupsh) | `gamectl` |
| Run n8n on a VPS, Linux desktop or WSL | [n8n-setup.sh](#n8n-setupsh) | `n8nctl` |
| Deploy a static frontend | [front-deploy.sh](#front-deploysh--front-updatesh) | `front-update` |
| Deploy a Node.js or Django backend | [back-deploy.sh](#back-deploysh--back-updatesh) | `back-update` |
| Diagnose a VPS or check download mirrors | [vps-check.sh and mirror-check.sh](#server-and-mirror-checks) | `bash vps-check.sh` / `bash mirror-check.sh` |
| Scaffold Flutter projects and features | [flutter-fgen](#flutter-fgen) | `fgen` |
| Scaffold React projects and features | [react-rgen](#react-rgen) | `rgen` |
| Check app configuration and run pre-push checks | [env-check.py and dev-check.py](#development-checks) | `python env-check.py` / `python dev-check.py` |

See [All three on one VPS](#all-three-on-one-vps) for the DNS, n8n and
3x-ui port layout.

## 3xui-setup.sh

Installs the latest 3x-ui release with a Let's Encrypt certificate, adds a
set of configs under one client, tests every config, and prints the
subscription links with a QR code. The config set is based on
[3x-ui-pro-configs](https://github.com/pdnczone/3x-ui-pro-configs).

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh)
```

The mirror fetches this script. A fresh install also needs the upstream
installer and release assets. Set `XUI_INSTALLER_URL` to use a different
URL for the upstream installer.

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh) --help
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh) --help
```

### Configs

Current Xray refuses VLESS without a security layer, so every config carries
REALITY, TLS or VLESS Encryption (Shadowsocks-2022 encrypts by itself).

| Key | Config | Default port |
| --- | --- | --- |
| `rv` | REALITY Vision (main) | TCP 2443 |
| `rx` | REALITY XHTTP | TCP 3443 |
| `ro` | REALITY XHTTP with extra (obfuscated padding) | TCP 5443 |
| `rp` | REALITY XHTTP packet-up | TCP 6443 |
| `rg` | REALITY gRPC | TCP 4443 |
| `tv` | TLS Vision, plus Fragment and IPv6 links | TCP 9443 |
| `tx` | TLS XHTTP, plus Fragment and IPv6 links (and a CDN link with `--cdn`) | TCP 2087 |
| `hy` | Hysteria2 with Salamander | UDP 7443 |
| `th` | TLS XHTTP over HTTP/3 (QUIC) | UDP 11443 |
| `pq` | VLESS Encryption (post-quantum) with Sudoku | TCP 10443 |
| `ew` | VLESS Encryption over WebSocket, no TLS (plus a Cloudflare HTTP link with `--cdn`) | TCP 8880 |
| `ex` | VLESS Encryption over XHTTP, no TLS (plus a Cloudflare HTTP link with `--cdn`) | TCP 2052 |
| `tt` | Trojan TLS | TCP 14443 |
| `tr` | Trojan REALITY | TCP 14444 |
| `ss` | Shadowsocks-2022 | TCP+UDP 8080 |
| `ws` | Cloudflare CDN WebSocket, plus clean IPs | TCP 2053, only with `--cdn` |
| `hu` | Cloudflare CDN HTTPUpgrade | TCP 2083, only with `--cdn` |
| `cg` | Cloudflare CDN gRPC (turn gRPC on in Cloudflare > Network) | TCP 8443, only with `--cdn` |
| `kc` | VLESS Encryption over mKCP. Not part of `all`, because most networks block mKCP now; ask for it with `--configs` | UDP 12443 |

- No config uses port 80 or 443, and no two configs share a port, TCP or
  UDP. Configs that an earlier version put on 443 keep their port on a
  re-run; delete them in the panel and re-run to move them.
- A busy port moves the config to the next free one. The final summary lists
  the ports that were really used; open them in the provider firewall
  (IPv4 and IPv6, UDP for Hysteria2 and HTTP/3).
- A config that Xray rejects is removed again. `ro`, `rp`, `cg`, `th`, `ew`,
  `ex`, `tt`, `tr` and `kc` are also removed when they fail the end-to-end
  test.
- Two links are printed: the normal subscription and the JSON subscription.
  Use the JSON one for the Fragment / FinalMask configs, with a client on
  Xray-core 26 or newer (recent v2rayNG / v2rayN).

### Updating a server

Run the same command again. The panel is not reinstalled and no existing
inbound, client or host is changed. The script finds the client it made
before and adds only the configs that client does not have yet, under the
same subscription link, so clients just refresh the subscription. It knows a
config by its inbound name, so a renamed inbound is added again.

`--add-configs` makes a second, separate set with a new client instead, and
`--force-install` also updates the panel itself to the newest release.

### Options

| Option | |
| --- | --- |
| `--cdn <name>` | Subdomain proxied by Cloudflare (orange cloud, SSL/TLS Full) to this server. Adds the CDN configs and clean-IP links |
| `--configs <list>` | `all` (default) or a comma list of keys, e.g. `rv,rx,tv,hy` |
| `--clean <n>` | Number of Cloudflare clean-IP links with `--cdn` (0-30, default 20) |
| `--add-configs` | Make a second, separate set (new client) instead of adding the missing configs to the existing client |
| `--no-inbounds` | Install the panel only, no configs |
| `--open-firewall` | Open the panel, config and subscription ports in ufw / firewalld |
| `--force-install` | Update an installed panel to the newest release |
| `--no-bbr` | Do not enable BBR (it is enabled by default) |
| `--no-test` | Skip the end-to-end test |
| `--skip-dns-check` | Do not verify that the subdomain points to this server |

`XUI_VERSION=v3.10.2` pins a panel version instead of the latest one.

Besides adding the configs, the script changes three panel settings: link
names come from Hosts (`remarkTemplate` = `{{HOST}}`), the JSON subscription
is turned on, and the subscription gets the panel certificate when it has
none. The panel database is backed up first to `/etc/x-ui/x-ui.db.bak-pro-*`.

## backpack-setup.sh

Builds a [BackPack](https://github.com/AminMGMT/BackPack) reverse tunnel
from an Iran server to a kharej server and serves the kharej's 3x-ui
subscription through Iran. It is one command, run on the **Iran** server.
It logs in to the kharej server over SSH as root (it asks for the password
once, or uses your SSH key) and sets up both servers:

1. Tests the route: Iran -> kharej (ping, TCP/SSH) and kharej -> Iran (TCP,
   UDP, ping), plus GitHub access on both. The reverse tunnel is dialled by
   the kharej, so a failed kharej -> Iran UDP test skips `kcp`/`quic`, and a
   failed ping skips `xdi`. When 3x-ui is not on the kharej yet, it runs
   `3xui-setup.sh --no-inbounds --acme-port 18080 <kharej-domain>` there
   (the panel domain must point to the kharej). The panel login is read
   from `/root/3xui-info.env` on the kharej.
2. Installs the latest BackPack release on both servers, checked against its
   `SHA256SUMS`. When Iran cannot reach GitHub, the files are copied from the
   kharej.
3. Adds three inbounds on `127.0.0.1` to the kharej's 3x-ui: VLESS
   Encryption over TCP, WS and XHTTP (no TLS and no SNI, like `ew`/`ex` in
   `3xui-setup.sh`). It attaches the existing `3xui-setup` client to them,
   or creates one.
4. Makes one tunnel per BackPack transport, named `bpt-<transport>`, using
   BackPack's `turbo` preset: `tcp tcpmux stealth pck kcp quic ws wsmux wss
   wssmux xdi`. Each tunnel forwards three Iran ports, one per inbound, so
   there are up to 33 links (11 transports x TCP / WS / XHTTP).
5. Waits for each tunnel to connect, then tests every link with a real VLESS
   client through its Iran port to the internet. Each passing link gets a
   3x-ui Host, named like `🎒 BP kcp · WS`. The panel's subscription is
   served from Iran (service `bpt-sub`) through those tunnels, with
   automatic fallback between them.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/backpack-setup.sh) --kharej-domain panel.example.com --domain ir.example.com <kharej-ip>
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/backpack-setup.sh) --kharej-domain panel.example.com --domain ir.example.com <kharej-ip>
```

Anything left out is asked for. Run it again with no arguments for a menu:

| Menu / command | |
| --- | --- |
| Update (`update`) | Install the newest BackPack on both servers, add configs that are new since the last run, and retest every link. Ports, tokens and the subscription link stay the same |
| Uninstall (`uninstall`) | Remove the `bpt-*` tunnels on both servers, `bpt-sub`, and the panel's BackPack inbounds with their Hosts. BackPack and 3x-ui stay installed |

The first version used one REALITY inbound ("🎒 BackPack tunnel"). The
update removes it with its Hosts and adds the TCP / WS / XHTTP inbounds in
its place, so clients only refresh the subscription.

| Option | |
| --- | --- |
| `--domain <name>` | Iran domain for the configs and the subscription, instead of the IP. Its A record must point to the Iran server (grey cloud on Cloudflare) |
| `--kharej-domain <name>` | Panel domain for the kharej. Only used when 3x-ui is not there yet |
| `--ssh-port <n>` | SSH port of the kharej server (default 22) |
| `--ssh-host <ip>` | SSH management address through a relay; the kharej IP stays unchanged |
| `--iran-ip <ip>` | Iran IP for the configs (default: the address the kharej sees) |
| `--sub-port <n>` | Subscription port on Iran (default 2095) |

If Iran cannot reach the kharej's SSH port, start a temporary management
relay on the **kharej** (leave it running until setup finishes):

```bash
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
  -R 127.0.0.1:22222:127.0.0.1:22 root@<iran-ip>
```

Then run on **Iran**:

```bash
bash backpack-setup.sh --ssh-host 127.0.0.1 --ssh-port 22222 \
  --iran-ip <iran-ip> <kharej-ip>
```

Close the management relay afterwards. BackPack connects the two VPSs
directly and keeps running without it.

- User ports start at 2101 (TCP, three per transport). Tunnel ports start at 4101 (TCP, or UDP
  for `kcp`/`quic`). A busy port moves to the next free one. The script opens
  them in ufw / firewalld. Open them in the Iran provider firewall too.
- Forwarding uses dedicated ports; BackPack and `bpt-sub` do not bind
  ports 80 or 443. `--acme-port 18080` also keeps the panel's separate
  certificate listener on a dedicated port during renewal: HTTP-01
  validation still arrives on TCP/80, and a temporary firewall forward
  sends it to 18080 while the certificate is issued or renewed.
- Users, traffic limits and expiry are managed in 3x-ui. Every client
  attached to the "🎒 BackPack TCP / WS / XHTTP" inbounds gets their tunnel
  Hosts. VLESS Encryption needs a client on a recent Xray-core (a recent
  v2rayNG / v2rayN); an old client shows the links but cannot connect.
- Tunnel tokens and ports are kept in `/root/backpack-tunnel-info.env`;
  client IDs and VLESS Encryption keys stay in the panel. A link that failed
  the test may pass on the next update.
- The Iran subscription uses HTTP; its URL contains the client's access
  token, and filtering can block a VPN client's User-Agent. The script also
  prints the panel's HTTPS subscription when available; it contains the
  same Iran configs.
- The tunnels use BackPack's own unit names (`backpack-bpt-*.service`), so
  `sudo backpack` shows and manages them.
- The `udp` transport is left out because it carries UDP only. The
  experimental Naive / XHTTP / REALITY helpers are left out because they need
  a source build.

Based on BackPack by Amin Mohammadi (AminMGMT)
https://github.com/AminMGMT/BackPack

## game-setup.sh

An [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
server for games, run on the **kharej** server. Games send most of their
traffic over UDP, which the DNS relay cannot carry and the BackPack tunnels
are not built for. Players connect straight to this server over UDP.
AmneziaWG is WireGuard with junk packets and random header values in the
handshake, which makes it harder for DPI to detect. Data packets stay
the same as WireGuard, so ping does not change.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/game-setup.sh)
gamectl add ali       # new player: prints the .conf and a QR code
gamectl list          # players, IPs, last handshake
gamectl show ali | remove ali | status | uninstall
```

- Installs `amneziawg` from the Amnezia PPA (Ubuntu, or Debian through the
  `focal` suite) and builds the kernel module with DKMS. It needs a KVM or
  dedicated VPS with the distribution kernel and its headers (not
  OpenVZ/LXC).
- It does not share anything with BackPack, 3x-ui, nginx or AdGuard Home.
  It uses its own interface (`awg-game`), subnet (`10.66.66.0/24`,
  `--subnet`) and unit (`awg-quick@awg-game`), plus its own NAT rules,
  tagged `game-setup`. The UDP port is a random free port from 20000-60000
  unless you pass `--port`, and a port in use is refused.
- Opens the UDP port in ufw/firewalld when active. Open it in your
  provider's firewall too.
- Players use AmneziaVPN or AmneziaWG: import
  `/etc/game-setup/clients/<name>.conf` or scan the QR code. Client MTU is
  1280, all IPv4 traffic goes through the tunnel, and DNS is
  `1.1.1.1, 8.8.8.8` (`--dns`).
- `--endpoint game.example.com` puts a domain in the player configs
  instead of the detected public IPv4.

### Through the Iran server

Players connect to an AmneziaWG server on the **Iran** server. Their
traffic goes through a separate AmneziaWG tunnel, `awg-link`, to the
kharej, which sends it out to the internet:

```text
players -> Iran (awg-game) -> awg-link -> kharej -> internet
```

The player-to-Iran leg stays domestic, and the international hop uses the
Iran datacenter's link, which is usually more stable than a home ISP's.
Each leg is encrypted once.

```bash
# 1. on the kharej: the link's server end; prints a one-line token
bash game-setup.sh link
# 2. on the Iran server (copy the script over if Iran cannot reach GitHub)
bash game-setup.sh bridge --token <token>
# 3. players are managed on Iran from now on
gamectl add ali
```

- The token carries the kharej address and port, both link keys and the
  AmneziaWG parameters, so no SSH is needed between the servers. It
  contains Iran's private key, so keep it private. `gamectl link` on the
  kharej prints it again.
- Separate from the direct layout and from BackPack: the link uses
  `10.67.67.0/30` and unit `awg-quick@awg-link`, and players on Iran use
  `10.68.68.0/24` (`--subnet` on `link`). Both ports are random free ports
  (`--port`).
- On Iran, policy routing (table and rule priority `6767`) sends only the
  players' subnet into the link. The Iran server's own traffic and
  BackPack keep the normal route. Iran does no NAT: if the link is down,
  players get no internet rather than leaking out of Iran.
- `bridge` waits for the link handshake and warns if it does not come
  (UDP blocked on the way, or the kharej firewall). `gamectl status` shows
  both tunnels.
- Iran needs the amneziawg package as well. When Launchpad is filtered
  there, set an apt/https proxy for the install step.
- Compare the ping with the direct layout, because the Iran route is not
  faster on every ISP. `gamectl uninstall` on each server removes its side.

## dns-setup.sh

Self-hosted anti-sanction DNS. Installs AdGuard Home (panel, DoH, DoT, DoQ,
cache, stats) with a Let's Encrypt certificate and puts nginx in front of it:

- `dns.example.com` on :443 goes to AdGuard Home (panel + DoH, TLS terminated
  there)
- domains in the relay list resolve to this server and are passed through by
  TLS SNI (no MITM: the client still validates the real certificate), so sites
  that geo-block Iranian IPs or are blocked by IP in Iran keep working
- everything else is dropped

The relay list ships with ~540 domains, grouped by category: package
registries and languages, AI/ML (OpenAI, Claude, Gemini, Grok, Cursor, Hugging
Face, ...), source hosts and CI, Google/Apple developer services,
containers/cloud/devops, developer SaaS, games and launchers (Steam, Epic, EA,
Ubisoft, Battle.net, Riot, PlayStation, Xbox, Nintendo, GOG, Roblox, ...),
hardware vendors, Microsoft/Adobe/Autodesk/JetBrains/Unity/NVIDIA, design and
productivity tools, WordPress plugins, learning platforms, freelancing and
payments. Right after the domain the installer asks whether to add this list
(default: yes); answer `n` to start with an empty list. It is managed with
`dnsctl` and is also visible in the panel's DNS rewrites page.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
DS_SELF_URL=https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh \
  bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh)
```

`DS_SELF_URL` also sends the download for the installed `dnsctl` through the mirror.

After the install:

```bash
dnsctl list                      # domains that go through the relay
dnsctl add registry.npmjs.org    # add one or more domains
dnsctl remove registry.npmjs.org
dnsctl import <file|url>         # bulk-add a community list (--force above 600)
dnsctl defaults                  # merge the built-in list (e.g. after an update)
dnsctl status                    # services, ports, certificate
dnsctl test                      # DoH, DoT, relay and rewrite checks
dnsctl info                      # client settings, DNS stamps, QR code
dnsctl allow 203.0.113.0/24      # restrict who may use the resolver
dnsctl uninstall                 # remove everything (see below)
```

Uninstall removes AdGuard Home, the Let's Encrypt certificate, the nginx relay
configs, the relay list, state, logs and `dnsctl`, and restores the system
resolver; nginx, certbot and the other packages stay installed. It also works
without `dnsctl`:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh) --uninstall
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh) --uninstall
```

Community lists you can feed to `dnsctl import`:

```bash
dnsctl import https://raw.githubusercontent.com/filteryab/ir-sanctioned-domain/main/data/ir-sanctioned-domain
dnsctl import https://ghfast.top/https://raw.githubusercontent.com/filteryab/ir-sanctioned-domain/main/data/ir-sanctioned-domain
dnsctl import https://raw.githubusercontent.com/MrDevAnony/DynX-AntiBan-Domains/main/DynX-AntiBan-list.lst --force
dnsctl import https://ghfast.top/https://raw.githubusercontent.com/MrDevAnony/DynX-AntiBan-Domains/main/DynX-AntiBan-list.lst --force
```

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh) --help
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh) --help
```

Ports: TCP 53/80/443/853 and UDP 53/853. The script keeps its own paths
(`/etc/dns-setup`, `/opt/AdGuardHome`, `/root/dns-info.env`). It can share a
server with `3xui-setup.sh` and `n8n-setup.sh`, see
[All three on one VPS](#all-three-on-one-vps).

## n8n-setup.sh

Installs [n8n](https://n8n.io) behind nginx with a Let's Encrypt certificate:

- installs Docker and the compose plugin (from download.docker.com, or from
  the distro packages if that repo is unreachable)
- runs n8n with docker compose in `/opt/n8n`, listening on 127.0.0.1 only.
  SQLite by default, or Postgres with `--postgres`
- sets up nginx for `https://<domain>/` with websockets, long timeouts and a
  100 MB upload limit, and gets a certificate that renews automatically
- adds a 2 GB swap file on servers with less than 2 GB of RAM, and rotates
  the container logs
- prints the login link at the end. Create the owner account right away, or
  pass `--owner-email` so the script creates it for you

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh)
```

Docker Hub and docker.n8n.io block Iranian IPs. When a pull fails the script
retries through Iranian mirrors (arvancloud, iranserver, docker.ir) on its own,
and apt / the Docker repo fall back to mirrors too. To pick the mirror yourself:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh) --registry-mirror https://docker.arvancloud.ir
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh) --registry-mirror https://docker.arvancloud.ir
```

**Local install** (WSL or your own Linux, no domain): press Enter at the
domain prompt, or pass `--local`. Docker and n8n are set up the same way,
without nginx or a certificate, and n8n opens at `http://localhost:5678`
(on WSL, from the Windows browser too). Webhooks are only reachable from
that machine. On WSL without systemd, Docker does not start by itself after
a WSL restart; run `n8nctl restart`.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh) --local
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh) --local
```

After the install:

```bash
n8nctl status          # containers, health, certificate
n8nctl info            # login link, owner account, encryption key
n8nctl logs -f
n8nctl backup          # data + .env + database -> /root/n8n-backups
n8nctl update          # backup, pull the latest image, restart
n8nctl update 1.2.3    # switch to a specific tag
n8nctl uninstall       # keeps /opt/n8n; --purge deletes it too
```

### Back up and restore n8n

`n8nctl backup` briefly stops n8n so its database and files are copied together.
The archive includes credentials and the key that decrypts them. Keep it private
and copy it off the server if you need to recover from a VPS failure.

```bash
n8nctl restore ./n8n-backup.tar.gz --check   # validate the archive before downtime
n8nctl restore ./n8n-backup.tar.gz           # prompt, restore and check local health
n8nctl restore ./n8n-backup.tar.gz --yes --tag 1.2.3  # use the source version's tag
```

Run the current installer once to refresh an older `n8nctl`. For a move, first set
up the destination using the same database type as the backup (SQLite by default
or `--postgres`). Restore replaces the destination's workflows, users, credentials,
uploaded files and encryption key. It uses the destination's domain, ports and
image settings, with an optional `--tag` override. Pick the source version when
recovering from a failed upgrade. Active workflows can resume when n8n starts,
so stop the old instance before switching over during a move. Use archives you
made or trust. If the import or local health check fails, the command attempts
to bring the previous data and containers back.

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh) --help
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh) --help
```

Ports: TCP 80/443. Back up `N8N_ENCRYPTION_KEY` from `/opt/n8n/.env`: saved
credentials cannot be decrypted without it. Next to `dns-setup.sh`, n8n
sits behind its relay on :443, see
[All three on one VPS](#all-three-on-one-vps).

## front-deploy.sh / front-update.sh

Deploys a React (or any static) frontend from its git repository behind nginx
with a Let's Encrypt certificate, and updates it with one command after each
push.

- asks for the domain and the repository. A public repository is cloned over
  HTTPS. For a private one the script creates a read-only deploy key, shows it
  (with the GitHub link where to add it) and waits until it works. GitHub over
  SSH port 443 is tried when port 22 is blocked
- instead of a repository you can give a path on the server to a ready build
  (folder, `.zip` or `.tar.gz`), for servers too small to build on
- picks the Node.js major from `.nvmrc` / `.node-version` / `engines.node`
  (default 24) and installs it from the official tarballs, with
  npmmirror and then the Iranian Runflare mirror as fallbacks (the same goes
  for the npm registry, and apt falls back to Runflare's Ubuntu/Debian mirror
  for that run). npm, pnpm or yarn is chosen from the lockfile; a
  frontend in a sub-folder (monorepo) is found automatically
- finds the build folder (`dist` for Vite, `build` for Create React App, or
  wherever the build wrote `index.html`) and asks you to confirm it once
- nginx: SPA routing (unknown paths go to `index.html`), gzip, a one-year cache
  for `/assets` and `/static`, no cache for `index.html`, www redirect when
  `www.<domain>` also points to the server
- dependencies and builds run as the unprivileged `frontdeploy` user. Each
  build goes to its own folder in `/var/www/<domain>/releases` and goes live
  with an atomic symlink switch, so a failed build never touches the site.
  The last 5 releases are kept

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/front-deploy.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
FD_UPDATE_URL=https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/front-update.sh \
  bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/front-deploy.sh)
```

`FD_UPDATE_URL` sends the `front-update` download through the same mirror.

After the install:

```bash
front-update                    # pull, build, publish (asks which site if there are several)
front-update --all              # every site
front-update --force            # rebuild the same commit, e.g. after editing .env
front-update --clean            # fresh node_modules
front-update rollback           # back to the previous release
front-update list               # sites, sources, live releases
front-update --dist /root/dist.zip   # publish a ready build
front-update remove             # delete a site
```

An update is fast when nothing changed: it stops if the commit is already
live, and skips the dependency install when the lockfile did not change.
Build-time variables (`VITE_*`, `REACT_APP_*`) go in
`/var/www/<domain>/shared/.env`; it is copied to `.env.production.local`
before each build. Re-run `front-deploy.sh` for a deployed domain to change
its repository, branch or folders.

Several sites on one server: run `front-deploy.sh` once per domain. Each site
has its own config (`/etc/front-deploy/sites/`), nginx file, certificate,
folder, deploy key and Node.js major. `front-update` asks which one to update,
`--all` updates them one after the other (a failed build does not stop the
rest), and only one build runs at a time so a small VPS does not run out of
memory. `front-update list` shows the disk use of each site.

### An admin panel on its own subdomain

For a panel that lives in its own repository but builds against the public
site's source (it imports `../site/src`) and talks to the same backend:

```bash
bash front-deploy.sh panel.example.com \
  --repo https://github.com/me/site-panel \
  --with-repo https://github.com/me/site --with-dir site \
  --backend api.example.com \
  --noindex \
  --env-file /root/panel.env
```

- `--with-repo` clones the second repository next to the checkout
  (`/var/www/<domain>/<dir>`, so `../<dir>` from the build) and pulls it
  before every build. A push to either repository makes `front-update`
  rebuild. A private one gets its own read-only deploy key (GitHub takes a
  key on one repository only); `--with-repo none` drops it.
- `--backend <app>` serves the panel's `/api/` from a backend already set up
  with `back-deploy.sh` on its own domain: one process and one database for
  site and panel. `/media/` serves the panel build's own files first and the
  backend's uploads otherwise. The backend has to accept the panel's host
  (Django: `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`; for GVB also
  `PANEL_HOSTS=panel.example.com`, so staff routes answer only there).
- `--noindex` adds `X-Robots-Tag: noindex, nofollow` (`--index` removes it).
- The panel's build settings go in its `--env-file`, e.g. for GVB:

  ```
  VITE_API_URL=/api
  VITE_SITE_URL=https://example.com
  PANEL_LOGIN_PATH=/a-long-secret-path
  ```

  `PANEL_LOGIN_PATH` is the sign-in page's address. Only its hash is in the
  bundle; every other address, the subdomain's root included, answers with a
  plain 404 page. Change it in `/var/www/<domain>/shared/.env`, then
  `front-update --force`.

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/front-deploy.sh) --help
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/front-deploy.sh) --help
```

Ports: TCP 80/443. Next to `dns-setup.sh`, the sites sit behind its relay on
`127.0.0.1:10444`, the same way as n8n.

## back-deploy.sh / back-update.sh

Deploys a Node.js (Express, Nest, Fastify, ...) or Django backend from its git
repository behind nginx with a Let's Encrypt certificate, run by systemd, and
updates it after each push without downtime.

- asks where to serve it: **on its own subdomain** (`api.example.com`, with
  its own certificate) or **under a path of a frontend** deployed with
  `front-deploy.sh` (`example.com/api`, same domain and certificate, so React
  calls `fetch("/api/...")` without CORS). For a path it lists the frontends on
  the server and asks whether the app's routes include the path
  (`app.get("/api/users")`, passed on as is) or not (`app.get("/users")`,
  nginx strips `/api`)
- then the repository (public over HTTPS, private with a read-only deploy key,
  like `front-deploy.sh`)
- the app's `.env` from the repository's `.env.example` (or `.env.sample`,
  `.env.template`, ...): it asks for each variable, showing the comment above
  it; Enter keeps the example value, `-` leaves it empty, and secrets
  (`JWT_SECRET`, `SESSION_SECRET`, ...) get a random value on Enter. `PORT` is
  not asked. Or copy a `.env` already on the server (`--env-file`), or skip and
  add it later with `back-update env`. Re-running the script asks only for
  variables added to `.env.example` since
- Node.js from `.nvmrc` / `engines`, npm / pnpm / yarn from the lockfile, the
  `build` script (TypeScript) when there is one. The start command comes from
  the `start:prod` / `start` script (watch-mode scripts such as nodemon are
  skipped), else `node <main>`, and is confirmed once
- **blue/green**: each app has two systemd instances on two local ports. A new
  release starts on the idle one; nginx switches to it only after it answers
  HTTP on the health path (any status below 500), then the old one stops after
  10 seconds. A release that crashes or does not answer never gets traffic
- `--release-cmd` runs once per new release before the switch, as the app user
  with its environment (e.g. `npx prisma migrate deploy`)
- each app runs as its own systemd `DynamicUser` with a read-only filesystem.
  The `.env` is read by systemd, so the app process cannot read the file (or
  another app's). Folders the app writes to (`--data-dir uploads`) live in
  `/var/lib/back-deploy/<app>` and survive releases
- nginx: websockets, `X-Forwarded-*` headers, 50 MB uploads (`--max-body`)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/back-deploy.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
BD_UPDATE_URL=https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/back-update.sh \
  bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/back-deploy.sh)
```

`BD_UPDATE_URL` sends the `back-update` download through the same mirror.

The app must listen on `process.env.PORT`; behind nginx, Express needs
`app.set("trust proxy", 1)` for the real client IP.

### Django

A repository with `manage.py` (at the root, or the only folder with one) is
deployed as Django, with the same questions and the same `back-update`:

- a virtualenv with system Python 3 and `requirements.txt`, plus gunicorn when
  it is not listed; the start command is
  `python -m gunicorn <project>.wsgi:application --bind 127.0.0.1:$PORT`
  (confirmed once). pypi.org blocked: a mirror is used (aliyun, then the
  Iranian Runflare mirror; pin one with `--pip-index`)
- every release runs `migrate` and `collectstatic` before it gets traffic
- **PostgreSQL** (requirements with `psycopg`): installed locally, with a
  database and user for the app and a random password. **Redis** (requirements
  with `celery`, `redis` or `django-redis`): installed on `127.0.0.1:6379`.
  While filling the `.env`, `DB_NAME` / `DB_USER` / `DB_PASSWORD` /
  `DB_HOST` / `DB_PORT` (or `POSTGRES_*`, `DATABASE_URL`), `REDIS_HOST` /
  `REDIS_PORT` / `REDIS_URL` / `CELERY_BROKER_URL`, `ALLOWED_HOSTS` and
  `DEBUG` come pre-filled; Enter takes them
- **Celery** (celery in the requirements and a `celery.py` next to the
  settings): `celery worker` as a service, and `celery beat` when the code has
  a beat schedule. Both restart after every deploy, `back-update env`,
  restart and rollback, and show up in `back-update logs` / `status`
- the server's paths stay out of the repository: Django runs with
  `DJANGO_SETTINGS_MODULE=_back_deploy_settings`, a file back-deploy adds to each
  release that imports the project's settings and sets `STATIC_ROOT`,
  `MEDIA_ROOT` (in `/var/lib/back-deploy/<app>`, kept across releases),
  `STATIC_URL=/static/`, `MEDIA_URL=/media/` and the `X-Forwarded-Proto` https
  header. nginx serves `/static/` and `/media/` itself (uploads sandboxed)
- the app runs as its own system user `bd-<app>` (not a DynamicUser, so nginx
  can read the static and media files); the `.env` is still read by systemd
  only

The project's settings read everything else from the environment
(`os.getenv`). Behind nginx there is exactly one proxy: if the project counts
proxies for the client IP (DRF `NUM_PROXIES`), set it to 1.

After the install:

```bash
back-update                 # pull, build, switch without downtime (asks which app if there are several)
back-update --all           # every app (a failed one does not stop the rest)
back-update env             # edit the .env, then restart without downtime
back-update restart         # same release on the other instance
back-update logs -f         # follow the app's log (journald)
back-update status          # instances, ports, health, certificate
back-update rollback        # back to the previous release (migrations are not undone)
back-update list            # all apps
back-update remove          # delete an app; --purge also deletes its data
```

Several backends on one server work the same way as the frontends: run
`back-deploy.sh` once per domain; each gets its own pair of ports (from 3100),
unit, user and certificate, and only one build runs at a time.

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/back-deploy.sh) --help
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/back-deploy.sh) --help
```

Ports: TCP 80/443, plus two app ports per backend (from 3100). `app.listen(PORT)`
binds them on all interfaces, so keep them closed in the firewall, or listen on
`127.0.0.1`. Next to `dns-setup.sh`, the backends sit behind its relay on
`127.0.0.1:10445`.

## All three on one VPS

`dns-setup.sh`, `n8n-setup.sh` and `3xui-setup.sh` can run on the same
server, in any order. Give each one its own subdomain (for example `dns.`,
`n8n.` and `panel.` of your domain), each with an A record to the server
(Cloudflare: DNS only). The scripts refuse a subdomain that another one
already uses. The smoothest order is dns-setup, then n8n, then 3x-ui.

| Port | Owner |
| --- | --- |
| TCP+UDP 53 | AdGuard Home (dns-setup) |
| TCP 80 | nginx: ACME challenges for all three, http to https redirects |
| TCP 443 | nginx SNI relay (dns-setup): the DNS domain goes to AdGuard, the n8n domain to n8n on `127.0.0.1:10443`, the relay list to the real sites. Without dns-setup, n8n's own nginx site |
| TCP+UDP 853 | DoT / DoQ (AdGuard Home) |
| random TCP 20000-40000 | 3x-ui panel |
| TCP 2096 | 3x-ui subscription |
| see the [config table](#configs) | 3x-ui configs, never on 80 or 443. Ports that are taken are skipped (TCP 10443 by n8n, for example, moves `pq` to 10444); the script prints the final list |
| loopback only | 3000 and 18443 (AdGuard), 5678 and 10443 (n8n) |

How the overlaps are handled:

- **443, DNS and n8n**: `dns-setup.sh` moves n8n behind its relay (it runs
  `n8nctl nginx`, which puts n8n on `127.0.0.1:10443` and adds its domain to
  `/etc/nginx/sni-routes.d/`). `dnsctl uninstall` moves n8n back to :443.
  Behind the relay, n8n sees `127.0.0.1` as the client address. Change the
  loopback port with `--tls-port`.
- **80 and 3x-ui certificates**: when nginx already owns TCP/80,
  `3xui-setup.sh` gets the panel certificate from certbot through a small
  nginx site (`/etc/nginx/conf.d/3xui-setup.conf`), and a renewal hook
  restarts x-ui. If 3x-ui was installed first (acme.sh on TCP/80), its
  renewals stop nginx for a few seconds and start it again. Re-run
  `3xui-setup.sh` after the others to move it to certbot. On such a server,
  do not use the certificate entries of the `x-ui` menu, because they need
  TCP/80 free.
- **Servers set up with older versions of these scripts**: first re-run the
  current version of the script that is already installed, then install the
  new one. Each script stops with that hint when the other one is too old.

## flutter-fgen

Python CLI for Flutter projects: generates feature folders (Clean / MVVM /
Simple x Riverpod / Bloc / Cubit / Provider / GetX), sets up a new project
(`fgen init`: Dio client, env, theme, router), adds routed screens
(`fgen page`), turns JSON into model classes (`fgen model`) and writes asset
constants (`fgen assets`). See
[flutter-fgen/README.md](flutter-fgen/README.md).

## react-rgen

Python CLI for React projects: sets up a Vite app with Tailwind, shadcn/ui,
React Router, TanStack Query, axios, zustand and react-hook-form + zod
(`rgen init`, with a header or sidebar layout, a fake API for development,
Vitest and CI), generates CRUD features with table, form, detail page,
search/pagination, fake API and tests (`rgen feature`), auth pages with
token refresh (`rgen auth`), pages, forms, models from JSON, Docker files,
and adds shadcn, React Bits and Magic UI components.
`AGENTS.md` / `CLAUDE.md` make AI assistants use it instead of writing
boilerplate. See [react-rgen/README.md](react-rgen/README.md).

## Server and mirror checks

```bash
sudo bash vps-check.sh                 # run on the VPS
sudo bash vps-check.sh --cert-days 30  # flag certificates expiring within 30 days
bash mirror-check.sh                   # check GitHub, npm, PyPI and Docker endpoints
bash mirror-check.sh npm --timeout 4   # run on the machine that will install packages
```

`vps-check.sh` reads service and container status, checks managed HTTPS sites
through local nginx, lists listening ports and reports disk usage and certificate
expiry. Exit code 1 flags failed checks, a filesystem at least 90% full, or a
certificate within the warning window. For HTTPS, a response below 500 confirms
the local route responds, including sites that require login.

`mirror-check.sh` sends small requests with curl and reports the HTTP status and
elapsed time. `AUTH` means the Docker endpoint returned an authentication
challenge. The Docker probes check registry reachability. Image downloads can
also depend on the token server and blob storage. Exit code 1 means a selected
group had no reachable endpoint.

## Development checks

Run from a project folder or pass its path. Both tools use Python 3.9+ and the
standard library, and run on Windows, Linux and macOS.

```bash
python /path/to/my-scripts/env-check.py ./frontend --mode development
python /path/to/my-scripts/env-check.py ./backend --strict
python /path/to/my-scripts/env-check.py ./mobile
python /path/to/my-scripts/dev-check.py ./frontend --build
python /path/to/my-scripts/dev-check.py ./mobile --dry-run
```

- `env-check.py` compares `.env` against `.env.example` or a similar template.
  With `--mode` it merges Vite's four env files in precedence order. For Flutter,
  it compares `env/dev.json` with the other JSON files in `env/`. Pass
  `--template` and `--file` to compare specific files. It reports missing,
  empty, duplicate and undocumented keys without printing values. Exit code 1
  means a required key is missing or empty, a key is repeated, or `--strict`
  found an undocumented key. Only file values are checked.
- `dev-check.py` runs the JavaScript project's `lint`, `typecheck` and `test:run`
  scripts when present, with `test` as a fallback. It detects the package manager
  and can also run `build`. For Flutter it checks formatting, runs `flutter analyze`
  and runs `flutter test` if tests exist. Use `--skip-tests` for a watch-only test
  script and `--dry-run` to see the commands first.
