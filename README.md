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

The relay list ships with ~215 domains, grouped by category: package
registries, AI/ML, source hosts and CI, containers/cloud, games and launchers
(Steam, Epic, EA, Ubisoft, Battle.net, Riot, PlayStation, Xbox, Nintendo, GOG,
Roblox, ...), Microsoft/Adobe/JetBrains/Unity/NVIDIA, design and productivity
tools, learning platforms and payments. It is managed with `dnsctl` and is
also visible in the panel's DNS rewrites page.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/dns-setup.sh)
```

After the install:

```bash
dnsctl list                      # domains that go through the relay
dnsctl add registry.npmjs.org    # add one or more domains
dnsctl remove registry.npmjs.org
dnsctl import <file|url>         # bulk-add a community list (--force above 600)
dnsctl status                    # services, ports, certificate
dnsctl test                      # DoH, DoT, relay and rewrite checks
dnsctl info                      # client settings, DNS stamps, QR code
dnsctl allow 203.0.113.0/24      # restrict who may use the resolver
dnsctl uninstall
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
(`/etc/dns-setup`, `/opt/AdGuardHome`, `/root/dns-info.env`) and shares nothing
with `3xui-setup.sh`, so both can live on the same server as long as their
ports do not collide.

## flutter-fgen

Python CLI that generates Flutter feature folders (Clean / MVVM / Simple x
Riverpod / Bloc / Cubit / Provider / GetX). See
[flutter-fgen/README.md](flutter-fgen/README.md).
