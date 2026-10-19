# 3x-ui Auto Installer (Panel + Let's Encrypt + VLESS Inbounds)

Unattended installer for [3x-ui](https://github.com/MHSanaei/3x-ui) on Ubuntu / Debian.
It installs the panel, secures it with a Let's Encrypt certificate for your
subdomain, creates three ready-to-use VLESS inbounds through the panel API, and
prints one subscription link plus a terminal QR code for it.

## Features

- Fully unattended: answers every `install.sh` question with sane defaults
- Pins 3x-ui to `v3.10.2` (override with `XUI_VERSION`)
- SQLite database, random panel port (20000–39999), random username/password/WebBasePath
- Let's Encrypt certificate for your subdomain, applied to the panel and subscription server
- Stops before installing if DNS or TCP/80 is not ready
- Creates VLESS inbounds: **XHTTP 8080/TCP** (`/ananas`), **WS 8585/TCP**
  (`/popcorn`), **mKCP 8443/UDP** (with `mkcp-legacy` finalmask)
- Client name is a random `pineapple-XXXXXXXX` prefix (unique per transport)
- Prints a single subscription URL, its QR code, and per-inbound links
- Saves panel credentials and the subscription ID to `/root/3xui-info.env` (mode 600)
- Safe to re-run: existing inbounds on the same port are skipped

## Quick start

Run as **root** (on a fresh server). Replace `YOUR_GITHUB_USER/YOUR_REPO` after
you publish this repository.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/3xui-setup.sh) panel.example.com
```

Or let it ask for the subdomain once:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/3xui-setup.sh)
```

> If you are not logged in as root yet, run `sudo -i` first. The script needs
> root and, when run through `bash <(curl ...)`, it cannot re-exec itself with sudo.

If you prefer to inspect the script before running it:

```bash
curl -fsSLo /root/3xui-setup.sh https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/3xui-setup.sh
bash /root/3xui-setup.sh panel.example.com
```

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 (Debian and similar should work)
- Root access
- A DNS **A record** for the subdomain pointing to the server's IPv4, e.g.
  `panel.example.com A 203.0.113.10`
- Cloudflare users: **Proxy must be OFF (DNS only / grey cloud)** — HTTP-01
  validation cannot work through the orange-cloud proxy
- TCP **80** free on the server (no nginx/apache on it) and open from the internet
- Open in your provider firewall/security group: TCP **80**,
  the random **panel port**, TCP **8080**, TCP **8585**, TCP **2096**
  (subscription) and UDP **8443**

## What you get

| Item | Value |
|---|---|
| Panel | `https://panel.example.com:<random-port>/<random-path>/` |
| Panel credentials | random, printed and saved to `/root/3xui-info.env` |
| Certificate | `/root/cert/panel.example.com/fullchain.pem` |
| Subscription | `https://panel.example.com:2096/sub/<subId>` + QR code |
| Client name | `pineapple-XXXXXXXX` (one client per inbound, same prefix) |
| VLESS XHTTP | TCP 8080, path `/ananas`, host = subdomain |
| VLESS WebSocket | TCP 8585, path `/popcorn`, host = subdomain |
| VLESS mKCP | UDP 8443, `finalmask.udp: mkcp-legacy` |

The generated inbounds use `security: none`, `sniffing: {enabled: false}`, and
the tags `in-8080-tcp`, `in-8585-tcp`, `in-8443-udp`. The `host` fields default
to the subdomain; override them with `XHTTP_HOST` / `WS_HOST` if you need a
different Host header (for example the comma-separated value from a manual
panel config).

The three inbounds are created through the authenticated panel HTTP API
(`/panel/api/inbounds/add`), because the `x-ui` management menu has no
"create inbound" option. All three clients share the same subscription ID, so
the single subscription link lists all of them.

## Options

```text
-d, --domain <name>   panel subdomain (prompted once when omitted)
    --skip-dns-check  do not verify that the subdomain points to this server
    --force-install   reinstall/update even if 3x-ui is already installed
    --open-firewall   open panel, inbound and subscription ports in ufw/firewalld
    --no-inbounds     do not create the default VLESS inbounds
    --inbounds-tls    use the panel certificate for XHTTP/WS inbounds
-h, --help            show help
```

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `XUI_VERSION` | `v3.10.2` | 3x-ui release to install |
| `XUI_INSTALLER_URL` | upstream `master/install.sh` | installer script URL |
| `XUI_INFO_FILE` | `/root/3xui-info.env` | where panel credentials are saved |
| `XUI_LOG_FILE` | `/var/log/3xui-setup.log` | full setup log (mode 600) |
| `INBOUND_XHTTP_PORT` | `8080` | XHTTP inbound port |
| `INBOUND_WS_PORT` | `8585` | WebSocket inbound port |
| `INBOUND_MKCP_PORT` | `8443` | mKCP UDP port |
| `INBOUND_TLS` | `0` | `1` = TLS (panel cert) for XHTTP/WS |
| `SKIP_INBOUNDS` | `0` | `1` = create no inbounds |
| `SUB_PORT` | `2096` | subscription port (must match the panel setting) |
| `XUI_CLIENT_NAME` | random `pineapple-XXXXXXXX` | client name prefix |
| `XHTTP_PATH` | `/ananas` | XHTTP path |
| `WS_PATH` | `/popcorn` | WebSocket path |
| `XHTTP_HOST` | subdomain | XHTTP `host` field |
| `WS_HOST` | subdomain | WebSocket `host` field |

Examples:

```bash
# custom inbound ports
INBOUND_XHTTP_PORT=2087 INBOUND_WS_PORT=2086 bash /root/3xui-setup.sh panel.example.com

# TLS for XHTTP/WS (mKCP stays plain UDP)
bash /root/3xui-setup.sh --inbounds-tls panel.example.com

# panel only, no inbounds
bash /root/3xui-setup.sh --no-inbounds panel.example.com
```

## How the SSL step works

The installer's own unattended mode is used with `XUI_SSL_MODE=domain`, which
runs the same certificate routine as `x-ui → 20 → 1`. If the certificate is
still missing afterwards, the script drives the menu explicitly:

```text
20 → 1 → <subdomain> → 80 → n → y → 0 → 0
```

`n` keeps the default ACME reload command and `y` applies the certificate to
the panel. If the certificate cannot be issued, the script exits without
pretending the panel is secured.

## Re-running

- If 3x-ui is already installed, the install step is skipped (use
  `--force-install` to reinstall).
- The certificate is verified/repaired for the given subdomain.
- Inbounds whose port already exists are skipped, so no duplicates are created.
- The subscription ID is saved in `/root/3xui-info.env`, so re-running still
  prints the same subscription link when the inbounds already exist.
- If the panel credentials were changed externally, pass them again:
  `XUI_USERNAME=... XUI_PASSWORD=... bash /root/3xui-setup.sh panel.example.com`

## Output

```text
==============================================================
 3x-ui is ready
==============================================================
 Panel URL   : https://panel.example.com:28471/8f3c1a9d5e2b7c40/
 Username    : xui1a2b3c
 Password    : 9f8e7d6c5b4a39281706f5e4d3c2b1a0
 Certificate : /root/cert/panel.example.com/fullchain.pem
 Expires     : Nov 17 12:34:56 2026 GMT
 Info file   : /root/3xui-info.env
--------------------------------------------------------------
 Inbounds:
   VLESS XHTTP : TCP 8080  (path /ananas)
   VLESS WS    : TCP 8585  (path /popcorn)
   VLESS mKCP  : UDP 8443

 Connection links:
   vless://...@panel.example.com:8080?type=xhttp&security=none&path=%2Fananas&host=panel.example.com&mode=auto#VLESS-XHTTP-8080
   vless://...@panel.example.com:8585?type=ws&security=none&path=%2Fpopcorn&host=panel.example.com#VLESS-WS-8585
   vless://...@panel.example.com:8443?type=kcp&security=none&headerType=none#VLESS-mKCP-8443
==============================================================

==============================================================
 Subscription
==============================================================
 (QR code, rendered with qrencode)

 Subscription link:
   https://panel.example.com:2096/sub/8ef7cc30768e0585
==============================================================
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `DNS mismatch for ...` | A record points elsewhere, or Cloudflare proxy is on | fix the A record / use DNS-only |
| `No A record found` | record not created yet | create it and wait for propagation |
| `TCP/80 is already in use` | nginx/apache on port 80 | stop it and re-run |
| `ufw is active but TCP/80 is not allowed` | local firewall | `ufw allow 80/tcp` or `--open-firewall` |
| `Could not obtain a valid certificate` | port 80 blocked externally / DNS not propagated | check security group and DNS; log: `/root/.acme.sh/acme.sh.log` |
| `Panel login failed` (inbound step) | 2FA enabled or wrong password | disable 2FA for automation, or reset via `x-ui` → option 7 |
| `The panel rejected the ... inbound` | port already used / invalid settings | change the port with `INBOUND_*_PORT` |
| Subscription link 404 / empty | subscriptions disabled, sub port blocked, or `subId` missing | enable Subscription in panel settings, open TCP 2096 |
| QR not printed | `qrencode` could not be installed | `apt-get install -y qrencode`, then re-run |
| `x-ui` does not start | service error | `systemctl status x-ui`, `x-ui log` |
| GitHub download fails | GitHub blocked on the server | mirror `install.sh`/release, or set `XUI_INSTALLER_URL` |

## Security notes

- The default inbounds are **plain VLESS without TLS**. That is convenient
  behind a CDN/reverse proxy, but direct traffic is not encrypted by VLESS
  itself. Use `--inbounds-tls` or a TLS-terminating CDN/reverse proxy if you
  connect directly.
- mKCP is UDP-only; make sure UDP 8443 is open. It does not use the TLS
  certificate.
- The subscription URL is a **secret**: anyone who has it can fetch your
  configs. Treat it like a password and do not post the QR/link publicly.
- The subscription server uses the same certificate (`subCertFile`/`subKeyFile`)
  that `x-ui cert` sets, so the link is HTTPS. If the panel was configured in a
  way that leaves the subscription certificate empty, the script prints an HTTP
  warning.
- Panel credentials, port and WebBasePath are random. `/root/3xui-info.env`
  and `/var/log/3xui-setup.log` are mode 600.
- XHTTP links require a reasonably recent client (Xray 24.9.30+ / recent
  v2rayN, NekoBox, etc.).
- Enabling panel 2FA breaks API-based inbound creation; use
  `--no-inbounds` and create them in the UI instead.

## Publish this on GitHub

```bash
git init
git add 3xui-setup.sh README.md
git commit -m "3x-ui auto installer with SSL and VLESS inbounds"
git branch -M main
git remote add origin https://github.com/YOUR_GITHUB_USER/YOUR_REPO.git
git push -u origin main
```

Then the one-liner becomes:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/3xui-setup.sh) panel.example.com
```

GitHub's raw endpoint may cache for a few minutes after a push. For a frozen
version, use a commit SHA instead of `main`.

---

## فارسی

### این اسکریپت چه می‌کند؟

نصب کاملاً بدون سؤال 3x-ui نسخه `v3.10.2` روی اوبونتو/دبیان، گرفتن گواهی
Let's Encrypt برای ساب‌دامین، تنظیم پنل روی HTTPS، ساخت سه inbound آماده، و
چاپ یک لینک ساب‌سکریپشن به‌همراه QR آن:

| Inbound | پورت | مسیر |
|---|---|---|
| VLESS + XHTTP | TCP 8080 | `/ananas` |
| VLESS + WS | TCP 8585 | `/popcorn` |
| VLESS + mKCP | UDP 8443 | — (با `finalmask: mkcp-legacy`) |
| Subscription | TCP 2096 | `/sub/<subId>` |

این inboundها با `security: none`، `sniffing: {enabled: false}` و tagهای
`in-8080-tcp`، `in-8585-tcp` و `in-8443-udp` ساخته می‌شوند. فیلد `host` به‌طور
پیش‌فرض همان ساب‌دامین است و با `XHTTP_HOST` / `WS_HOST` قابل تغییر است.

برای هر inbound یک کلاینت با اسم تصادفی `pineapple-XXXXXXXX` ساخته می‌شود
(یک اسم پایه برای هر سه، با پسوند نوع ترنسپورت) و هر سه در یک لینک
ساب‌سکریپشن جمع می‌شوند.

### اجرا

```bash
sudo -i
bash <(curl -Ls https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/3xui-setup.sh) panel.example.com
```

اگر دامنه را ندهید، فقط یک بار همان اول می‌پرسد. بقیهٔ سؤال‌های نصب‌کننده
خودکار جواب داده می‌شوند (SQLite، پورت تصادفی، SSL دامنه).

### پیش‌نیازها

- رکورد A ساب‌دامین به IPv4 سرور
- در Cloudflare، Proxy خاموش (DNS only)
- پورت 80 آزاد و باز از اینترنت
- باز بودن TCP 80، پورت پنل، TCP 8080، TCP 8585، TCP 2096 و UDP 8443
  در فایروال/Security Group

### نکته‌ها

- این سه inbound به‌صورت پیش‌فرض **بدون TLS** هستند؛ مناسب CDN یا reverse
  proxy. برای TLS روی XHTTP/WS از `--inbounds-tls` استفاده کنید (mKCP همیشه
  بدون TLS است).
- لینک ساب‌سکریپشن مثل پسورد است؛ هر کسی آن را داشته باشد به کانفیگ‌ها دسترسی
  دارد. QR و لینک را عمومی نکنید.
- QR با بسته `qrencode` ساخته می‌شود؛ اگر نصب نباشد اسکریپت خودش نصبش می‌کند و
  اگر نشد، فقط لینک را چاپ می‌کند.
- اطلاعات ورود و `subId` در `/root/3xui-info.env` (دسترسی 600) و لاگ در
  `/var/log/3xui-setup.log` ذخیره می‌شود.
- اسکریپت را می‌توان دوباره اجرا کرد؛ inboundهای موجود با همان پورت دوباره
  ساخته نمی‌شوند و لینک ساب از `subId` ذخیره‌شده بازسازی می‌شود.
- برای پنل بدون inbound: `--no-inbounds`.
- اگر 2FA پنل روشن باشد، ساخت inbound از طریق API انجام نمی‌شود؛ در آن حالت
  با `--no-inbounds` نصب کنید و inboundها را از خود پنل بسازید.

### عیب‌یابی سریع

| پیام | راه‌حل |
|---|---|
| `DNS mismatch` | رکورد A را درست کنید / Proxy کلادفلر را خاموش کنید |
| `TCP/80 is already in use` | nginx/apache را روی 80 متوقف کنید |
| `Could not obtain a valid certificate` | باز بودن پورت 80 از بیرون و DNS را چک کنید |
| `Login failed` در مرحله inbound | پسورد را از منوی `x-ui` گزینه 7 ریست کنید |
| `Panel rejected the ... inbound` | پورت با `INBOUND_*_PORT` عوض کنید |
| لینک ساب 404 یا خالی | سرویس Subscription در تنظیمات پنل خاموش است یا TCP 2096 بسته است |
| QR چاپ نشد | `apt-get install -y qrencode` و اجرای مجدد |

برای انتشار روی گیت‌هاب، دستورهای بخش **Publish this on GitHub** را اجرا
کنید و `YOUR_GITHUB_USER/YOUR_REPO` را با نام خودتان جایگزین کنید.
