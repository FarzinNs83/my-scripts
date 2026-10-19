# my-scripts

Standalone scripts for setting up Linux VPS servers. Run them as root.

## 3xui-setup.sh

Installs the 3x-ui panel with a Let's Encrypt certificate, creates three VLESS
inbounds (XHTTP, WebSocket, mKCP) with a client, and prints a subscription link
with a QR code.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh) panel.example.com
```

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/my-scripts/main/3xui-setup.sh) --help
```
