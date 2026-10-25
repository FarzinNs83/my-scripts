# my-scripts

Standalone scripts for setting up Linux VPS servers. Run them as root.

## 3xui-setup.sh

Installs the 3x-ui panel with a Let's Encrypt certificate, creates three VLESS
inbounds (XHTTP, WebSocket, mKCP) with a client, and prints a subscription link
with a QR code.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh)
```

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh) --help
```

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

Community lists you can feed to `dnsctl import`:

```bash
dnsctl import https://raw.githubusercontent.com/filteryab/ir-sanctioned-domain/main/data/ir-sanctioned-domain
dnsctl import https://raw.githubusercontent.com/MrDevAnony/DynX-AntiBan-Domains/main/DynX-AntiBan-list.lst --force
```

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh) --help
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

Docker Hub and docker.n8n.io block Iranian IPs. On a server in Iran, pull
through a mirror:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/n8n-setup.sh) --registry-mirror https://docker.arvancloud.ir
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
  npmmirror as a fallback. npm, pnpm or yarn is chosen from the lockfile; a
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

Ports: TCP 80/443. Next to `dns-setup.sh`, the sites sit behind its relay on
`127.0.0.1:10444`, the same way as n8n.

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
| TCP 8080, 8585, 2096, UDP 8443 | 3x-ui inbounds and subscription |
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
