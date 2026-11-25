# my-scripts

Standalone scripts for setting up Linux VPS servers. Run them as root.

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
| `rv` | REALITY Vision (main) | TCP 443 |
| `rx` | REALITY XHTTP | TCP 8443 |
| `ro` | REALITY XHTTP with extra (obfuscated padding) | TCP 2443 |
| `rp` | REALITY XHTTP packet-up | TCP 3443 |
| `rg` | REALITY gRPC | TCP 4443 |
| `tv` | TLS Vision, plus Fragment and IPv6 links | TCP 9443 |
| `tx` | TLS XHTTP, plus Fragment and IPv6 links (and a CDN link with `--cdn`) | TCP 2087 |
| `hy` | Hysteria2 with Salamander | UDP 443 |
| `th` | TLS XHTTP over HTTP/3 (QUIC) | UDP 8443 |
| `pq` | VLESS Encryption (post-quantum) with Sudoku | TCP 10443 |
| `ew` | VLESS Encryption over WebSocket, no TLS (plus a Cloudflare HTTP link with `--cdn`) | TCP 8880 |
| `ex` | VLESS Encryption over XHTTP, no TLS (plus a Cloudflare HTTP link with `--cdn`) | TCP 2052 |
| `tt` | Trojan TLS | TCP 14443 |
| `tr` | Trojan REALITY | TCP 14444 |
| `ss` | Shadowsocks-2022 | TCP+UDP 8080 |
| `ws` | Cloudflare CDN WebSocket, plus clean IPs | TCP 2053, only with `--cdn` |
| `hu` | Cloudflare CDN HTTPUpgrade | TCP 2083, only with `--cdn` |
| `cg` | Cloudflare CDN gRPC (turn gRPC on in Cloudflare > Network) | TCP 2096, only with `--cdn` |
| `kc` | VLESS Encryption over mKCP. Not part of `all`, because most networks block mKCP now; ask for it with `--configs` | UDP 9443 |

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
subscription through Iran. Install the panel with `3xui-setup.sh` on the
kharej first; its credentials are read from `/root/3xui-info.env`. Run this on the
**Iran** server. It logs in to the kharej server over SSH as root (it asks for
the password once, or uses your SSH key) and sets up both servers:

To keep certificate listeners off ports 80/443, first run on the kharej:

```bash
bash 3xui-setup.sh --no-inbounds --acme-port 18080 panel.example.com
```

HTTP-01 validation still arrives on public TCP/80; a temporary firewall
forward sends it to 18080 during issuance/renewal and is removed afterwards.
The selected listener is saved for later runs. No process binds TCP/80 or
443 in this mode. Existing HTTP traffic on port 80 is redirected for the
short validation window.

1. Tests the route: Iran -> kharej (ping, TCP/SSH) and kharej -> Iran (TCP,
   UDP, ping), plus GitHub access on both. The reverse tunnel is dialled by
   the kharej, so a failed kharej -> Iran UDP test skips `kcp`/`quic`, and a
   failed ping skips `xdi`.
2. Installs the latest BackPack release on both servers, checked against its
   `SHA256SUMS`. When Iran cannot reach GitHub, the files are copied from the
   kharej.
3. Adds one VLESS REALITY Vision inbound on `127.0.0.1` to the kharej's
   3x-ui and attaches its existing `3xui-setup` client (or creates one).
4. Makes one tunnel per BackPack transport, named `bpt-<transport>`, using
   BackPack's `turbo` preset: `tcp tcpmux stealth pck kcp quic ws wsmux wss
   wssmux xdi`.
5. Tests TLS forwarding, then real authenticated VLESS internet requests
   through the Iran ports. Each passing transport gets a 3x-ui Host. The
   panel's subscription is served from Iran (service `bpt-sub`) through
   those tunnels, with automatic fallback between them.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/backpack-setup.sh) <kharej-ip>
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/backpack-setup.sh) <kharej-ip>
```

| Option | |
| --- | --- |
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

- User ports start at 2101 (TCP). Tunnel ports start at 4101 (TCP, or UDP
  for `kcp`/`quic`). A busy port moves to the next free one. The script opens
  them in ufw / firewalld. Open them in the Iran provider firewall too.
- Forwarding uses dedicated ports; BackPack and `bpt-sub` do not bind
  ports 80 or 443. `--acme-port 18080` also keeps the panel's separate
  certificate listener on a dedicated port during renewal.
- Users, traffic limits and expiry are managed in 3x-ui. Every client
  attached to the "BackPack tunnel" inbound gets its tunnel Hosts.
- Run it again to rebuild. Tunnel tokens and ports are kept in
  `/root/backpack-tunnel-info.env`; client IDs and REALITY keys stay in
  the panel. A tunnel that failed the test may pass on the next run.
- The Iran subscription uses HTTP; its URL contains the client's access
  token, and filtering can block a VPN client's User-Agent. The script also
  prints the panel's HTTPS subscription when available; it contains the
  same Iran configs. Use HTTPS in front of `bpt-sub` when you have a domain
  for Iran.
- The tunnels use BackPack's own unit names (`backpack-bpt-*.service`), so
  `sudo backpack` shows and manages them.
- The `udp` transport is left out because it carries UDP only. The
  experimental Naive / XHTTP / REALITY helpers are left out because they need
  a source build.

Based on BackPack by Amin Mohammadi (AminMGMT)
https://github.com/AminMGMT/BackPack

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
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh)
```

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
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/front-deploy.sh)
```

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
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/back-deploy.sh)
```

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

## nfsu2-setup.sh

Installs [nfsu2-web](https://github.com/th0mk/nfsu2-web) (Need for Speed:
Underground 2 in the browser) on its own VPS. It asks only for the domain:

- installs the packages, wasi-sdk 34, Python (the lifter), Node.js 24 and
  Rust. Each comes from its own site, or from a mirror when that site is
  blocked (runflare apt/npm/pypi, npmmirror, rsproxy.cn, GitHub proxies)
- finds your game folder on the server (`SPEED2.EXE` v1.2 NA, checked by its
  SHA-256). If the folder isn't there, it shows how to upload it to
  `/srv/nfsu2/game` and waits. The game is never downloaded: bring your own copy
- clones the project to `/opt/nfsu2-web` and builds it with its own scripts
  (`web/gen.sh`, `web/build.sh`, the page and the Rust server). The first
  build can take an hour, and small VPSes get a 4 GB swap file for it
- runs the server with the project's systemd unit (`nfsu2-web`) behind nginx,
  with websockets and a Let's Encrypt certificate that renews automatically

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/nfsu2-setup.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/nfsu2-setup.sh)
```

Run it again to update: it pulls the project, rebuilds what changed and
restarts the server. Log: `journalctl -u nfsu2-web -f`.

Needs 15 GB of free disk. Ports: TCP 80/443. Anyone who can open the site
can play and download the game files from it.

## synergy-setup.sh

Synergy (Half-Life 2 co-op) dedicated server on an x86_64 VPS. It asks for
the server name, password, max players, the start map (a numbered list of
every chapter of HL2, Episode One and Episode Two, or any map name), the game
port and your Steam username:

- installs steamcmd and the 32-bit libraries, and creates a `steam` user
- Steam login: you type your password and Steam Guard code into steamcmd
  yourself; the login is cached for later runs
- downloads Synergy (app 17520, free) and Half-Life 2 (app 220, includes both
  episodes). The account must own Half-Life 2
- writes `server.cfg` and runs the server as a systemd unit (`synergy`)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/synergy-setup.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/synergy-setup.sh)
```

The downloads are ~12 GB, so run it inside `screen -S synergy` in case SSH
drops. If a download stalls, press Ctrl-C and run it again: it resumes,
usually from a faster CDN server. Run it again later to change the settings
or update the game.

```bash
synergyctl start     # start, and start at boot
synergyctl stop      # stop, and stay off after a reboot
synergyctl restart
synergyctl status
synergyctl log       # follow the server log
synergyctl save [name]      # save the running game (default name: coop)
synergyctl load [name]      # load it; players who were in it get their state back
synergyctl saves            # list the saves
synergyctl export [file]    # save, then pack all saves into a .tar.gz
synergyctl import <file>    # unpack an export, e.g. from the old server
synergyctl cmd changelevel d1_canals_01   # any server console command
```

Moving to another VPS: `synergyctl export` on the old one, copy the file
(`scp`), run this script on the new one, then `synergyctl import <file>` and
`synergyctl load export`. The commands go through rcon on this server only;
its password is random and the TCP port is not opened in the firewall.

Other game servers can run on the same VPS: the script offers the first free
port from 27015 and refuses one that another program holds, SourceTV (27020)
is off, and apt does not restart running services.

Needs 15 GB of free disk. Port: UDP 27015 by default.

## lan-setup.sh

Your own Radmin VPN / Hamachi / ZeroTier on a VPS, for games that have only a
LAN mode. Players connect with the SoftEther VPN Client and end up on one
virtual LAN (`10.77.77.0/24`); one of them hosts the game as usual and the
others find it in the LAN list or join its `10.77.77.x` address. The game
still runs on the host's PC, but the traffic goes player → VPS → player
instead of through Radmin's relays abroad, so with a VPS in Iran the ping
stays low. It asks for the port and the players' password:

- installs SoftEther VPN Server from apt (Ubuntu 22.04+ / Debian 12+)
- one listener on your port; the default ones (TCP and UDP 443, 992, 1194,
  5555), SSTP, OpenVPN and VPN Azure are off
- a hub `LAN` with one shared user `player`, and DHCP without a gateway, so
  only LAN traffic goes through the VPS, not the players' internet

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/lan-setup.sh)
```

Iran / GitHub blocked (ghfast.top mirror):

```bash
bash <(curl -Ls https://ghfast.top/https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/lan-setup.sh)
```

At the end it prints what each player enters in the client, and one
PowerShell line to run once on each PC: it makes the game's LAN list use the
VPN adapter and lets the host's firewall take players in. Run the script
again to change the port or the password.

```bash
lanctl start     # start, and start at boot
lanctl stop      # stop, and stay off after a reboot
lanctl restart
lanctl status
lanctl who       # the players' 10.77.77.x addresses
```

Port: TCP 5555 by default (the first free one from there). If ufw or
firewalld is on, the local UDP port range is opened too: SoftEther's UDP
acceleration sends the game packets over UDP from a random port, and
without it they go over TCP.

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
| see the [config table](#configs) | 3x-ui configs. Ports that are taken (TCP 443 by nginx, for example) are skipped, so REALITY Vision lands on TCP 2443 here; the script prints the final list |
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
