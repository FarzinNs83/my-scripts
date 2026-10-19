# my-scripts

A collection of standalone scripts for setting up and managing Linux VPS
servers. Each script is self-contained and can be inspected before running.

## Scripts

| Script | What it does |
|---|---|
| `3xui-setup.sh` | Installs 3x-ui, secures it with Let's Encrypt, creates three VLESS inbounds, and prints a subscription link + QR code |

More scripts will be added here over time.

---

## 3x-ui: panel + SSL + VLESS inbounds

Unattended installer for [3x-ui](https://github.com/MHSanaei/3x-ui). It installs
the panel, secures it with a Let's Encrypt certificate for your subdomain,
creates three VLESS inbounds through the panel API, adds a client, and prints a
single subscription link with a terminal QR code.

### What it does

- Installs **3x-ui v3.10.2** with SQLite, a random panel port, and random
  username/password/WebBasePath
- Obtains a **Let's Encrypt certificate** for the subdomain and applies it to
  the panel and the subscription server
- Creates three **VLESS** inbounds through the panel API
- Creates one client per inbound with a random `pineapple-XXXXXXXX` name and a
  shared subscription ID
- Prints the panel URL, credentials, per-inbound links, and the **subscription
  link + QR code** (`qrencode` is installed automatically if missing)
- Saves credentials and the subscription ID to `/root/3xui-info.env` (mode 600)
- Checks DNS and TCP/80 before installing, so a failed certificate does not
  leave a half-installed panel

### Inbounds created

| Transport | Port | Path |
|---|---|---|
| VLESS + XHTTP | TCP 8080 | `/ananas` |
| VLESS + WebSocket | TCP 8585 | `/popcorn` |
| VLESS + mKCP | UDP 8443 | — (`mkcp-legacy` finalmask) |
| Subscription | TCP 2096 | `/sub/<subId>` |

The inbounds use `security: none` and `sniffing: {enabled: false}`. The `host`
field is the subdomain; override it with `XHTTP_HOST` / `WS_HOST` if needed.

### Requirements

- Ubuntu 20.04+ / Debian (root access)
- A DNS **A record** for the subdomain pointing to the server's IPv4
- Cloudflare users: **Proxy OFF (DNS only / grey cloud)**
- TCP **80** free on the server (for the ACME HTTP-01 challenge)
- Open in the provider firewall/security group: the random **panel port**,
  TCP **8080**, TCP **8585**, TCP **2096**, UDP **8443**

### Usage

Omit the domain and the script asks for it once:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh)
```

Prefer to inspect the script before running it:

```bash
curl -fsSLo 3xui-setup.sh https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh
bash 3xui-setup.sh panel.example.com
```

### Options

| Option | Description |
|---|---|
| `--no-inbounds` | Install the panel only (no inbounds, no subscription) |
| `--inbounds-tls` | Use the panel certificate for XHTTP/WS inbounds |
| `--open-firewall` | Open the required ports in ufw or firewalld |
| `--skip-dns-check` | Skip the DNS pre-check |
| `--force-install` | Reinstall even if 3x-ui is already installed |

Run `bash 3xui-setup.sh --help` for all environment variables (ports, paths,
client name, etc.).

### Notes

- XHTTP and WebSocket are created **without TLS** by default (suitable for a
  CDN or reverse proxy). Use `--inbounds-tls` to serve them with the panel
  certificate.
- mKCP is UDP-only and does not use the TLS certificate.
- The subscription link is a secret: anyone who has it can fetch the configs.
- If panel 2FA is enabled, API-based inbound creation fails; use
  `--no-inbounds` and create the inbounds in the panel UI.
- Re-running is safe: existing inbounds on the same ports are skipped.

---

## فارسی

### `3xui-setup.sh` — نصب 3x-ui + گواهی SSL + سه inbound

نصب خودکار پنل 3x-ui، گرفتن گواهی Let's Encrypt برای ساب‌دامین، ساخت سه
inbound (XHTTP روی TCP 8080 با مسیر `/ananas`، WebSocket روی TCP 8585 با مسیر
`/popcorn`، mKCP روی UDP 8443)، ساخت یک کاربر با اسم تصادفی و چاپ لینک
ساب‌سکریپشن به‌همراه QR.

```bash
sudo -i
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh) panel.example.com
```

پیش‌نیازها: رکورد A ساب‌دامین به IP سرور، خاموش بودن Proxy کلادفلر، آزاد بودن
پورت 80، و باز بودن پورت پنل، TCP 8080، TCP 8585، TCP 2096 و UDP 8443.

برای دیدن همه گزینه‌ها:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh) --help
```
