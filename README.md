<div align="center">

<img src="https://img.shields.io/badge/Version-3.1.0-2080ff?style=for-the-badge&logo=linux" alt="Version">
<img src="https://img.shields.io/badge/Port-7777-00c97a?style=for-the-badge" alt="Port">
<img src="https://img.shields.io/badge/Python-3.8+-yellow?style=for-the-badge&logo=python" alt="Python">
<img src="https://img.shields.io/badge/License-MIT-blueviolet?style=for-the-badge" alt="License">

# 🌐 Erisrtg Packet Tunnel — Web Panel

**A full-featured web management panel for [Erisrtg Packet Tunnel](https://github.com/eris4444/packet-tunnel)**

*KCP-based raw socket tunnel for firewall / DPI bypass*

[فارسی](./Readme.fa.md) · [Telegram](https://t.me/erisrttg) · [Report Bug](https://github.com/eris4444/packet-tunnel/issues)

</div>

---

## 🆕 What's new in v3.1.0

- **🔔 Telegram now has its own page** — token, Chat ID and an optional **SOCKS5 proxy** live under a dedicated **Telegram** entry in the sidebar, not in Settings. The proxy exists because `api.telegram.org` is blocked from Iran: point it at a SOCKS5 proxy and every call to Telegram (DNS included) goes through it. A **Send Test Message** button confirms the setup works before you rely on it. Setup:
  1. Message [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, and copy the bot token it gives you.
  2. Message your new bot once (anything), then open `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and copy the `chat.id` value — that's your Chat ID.
  3. Paste both into the **Telegram** page. If Telegram isn't reachable directly from your server, also fill in a SOCKS5 proxy host/port. Save, then hit **Send Test Message**.
- **🔒 HTTPS + changeable port from Settings** — a new "Panel Network / HTTPS" card lets you paste a TLS certificate and private key, or just change the port. The pair is validated (`ssl.SSLContext.load_cert_chain`) **before** anything is written or the panel restarts, so a mismatched or malformed cert can't take the panel down. Saving restarts the panel service automatically.
- **🔐 bcrypt password hashing** — passwords are now stored with bcrypt instead of unsalted SHA-256. **Migration is automatic**: the first time you log in after upgrading, your existing password is silently re-hashed with bcrypt and saved — no action needed, nothing to run by hand.
- **📊 7-day traffic history** — a new chart on the dashboard shows download/upload throughput over the past week, sampled every 60 seconds into a local SQLite database (`data/traffic.db`).
- **🔔 Telegram alerts** — get a message the instant any node goes offline (see above for setup).
- **📱 Mobile-responsive layout** — the sidebar collapses behind a hamburger menu below 768px, and dashboard cards, the two-column layout sections, and the Nodes grid all stack cleanly on phone-sized screens.

---

## ✨ Features

| Feature | Description |
|---|---|
| 🌐 **Web UI** | Runs on port **7777**, listens on all IPs (`0.0.0.0`) |
| 🔐 **Authentication** | Username + password login, change credentials from panel |
| 🌙 **Dark / Light Theme** | Deep dark-blue tones · instant toggle |
| 🌍 **Bilingual** | English & Persian (فارسی) — switchable in one click |
| 📊 **Live Dashboard** | CPU, RAM, disk, uptime, load, public IP, Paqet version |
| ⚙️ **Service Management** | Start · stop · restart · delete — one service or all at once |
| ➕ **Add Server (Kharej)** | Full form with auto-generated secret key |
| 🔌 **Add Client (Iran)** | Port forwarding or SOCKS5 proxy, per-port protocol selection |
| 📝 **Config Editor** | Edit YAML live in browser, save & restart in one click |
| 📜 **Log Viewer** | Color-coded live logs streamed from journalctl |
| ⏰ **Cron Auto-Restart** | Set restart interval (1 min → 1 day) per service |
| 🚀 **systemd Integration** | Auto-start on boot, managed by systemd |
| 📦 **Paqet Installer** | Install / update Paqet binary directly from the UI |
| 🔧 **Network Optimizer** | sysctl tuning + BBR congestion control — one click |
| 🖥 **Nodes** | Watch every panel's CPU, RAM and traffic from one panel, over a read-only token |
| 📊 **Traffic History** | 7-day download/upload chart, sampled every 60s into SQLite |
| 🔔 **Telegram Alerts** | Its own page — token, Chat ID, optional SOCKS5 proxy, test button |
| 🔒 **HTTPS / Port** | Paste a cert + key or change the panel port, straight from Settings |

---

## 🚀 Quick Install

Run this on your server **as root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/packet-tunnel/main/install.sh)
```

The installer's very first step asks you to choose a **username and password**; the rest runs unattended. When it finishes you'll see:

```
╔══════════════════════════════════════════════════════════════╗
║         ✅  Installation Complete!                           ║
╚══════════════════════════════════════════════════════════════╝

  📌 Panel Access
  ┌──────────────────────────────────────────────────────────┐
  │  URL           : http://<YOUR-IP>:7777                   │
  │  Username      : admin                                   │
  │  Password      : (the one you chose)                     │
  └──────────────────────────────────────────────────────────┘
```

> **Unattended install** (no prompts): `PANEL_USERNAME=admin PANEL_PASSWORD=yourpassword bash install.sh` — without a terminal available at all, a random password is generated and printed once instead.

---

## 🗂 File Structure

All source files are **flat** in the root of the repository — no subdirectories:

```
packet-tunnel/
├── install.sh           ← one-command installer
├── app.py               ← Flask backend (template_folder = same dir)
├── requirements.txt     ← flask · pyyaml · gunicorn · bcrypt · requests · PySocks
├── base.html            ← shared layout: sidebar + header
├── login.html
├── dashboard.html
├── services.html
├── service_detail.html
├── add_server.html
├── add_client.html
├── settings.html
├── nodes.html            ← fleet monitoring UI
├── telegram.html         ← Telegram alert + SOCKS5 proxy settings
├── README.md            ← this file (English)
└── README.fa.md         ← Persian version
```

After installation, panel files are copied to `/opt/paqet-panel/`. A `data/` subdirectory is created there at runtime for the traffic-history database — it isn't part of the installer bundle:

```
/opt/paqet-panel/         ← panel files (flat)
└── data/
    └── traffic.db        ← 7-day traffic history (created at runtime)
/etc/paqet-panel/
├── config.json           ← credentials, theme/language, node token, Telegram settings
└── nodes.json            ← nodes this panel is watching (as a hub)
/etc/paqet/
└── <name>.yaml           ← tunnel configs
/etc/systemd/system/
├── paqet-panel.service   ← web panel service
└── paqet-<name>.service  ← tunnel services
```

---

## ⚙️ How It Works

```
Browser  ──────►  gunicorn (0.0.0.0:7777)
                      │
                   app.py (Flask)
                      │
          ┌───────────┼───────────────┐
          │           │               │
     /etc/paqet/   systemctl      journalctl
      *.yaml       start/stop       logs
                   restart
```

- **Flask** serves all HTML pages from the same flat directory (`template_folder='.'`)
- **systemd** starts `start.sh`, a small wrapper that reads the port and HTTPS settings out of `config.json` before launching **gunicorn** (2 workers) — so a port change or HTTPS toggle from Settings takes effect on the next restart without editing the systemd unit
- **systemd** manages both the panel service and all tunnel services
- **Credentials** are stored in `/etc/paqet-panel/config.json` as a bcrypt hash

---

## 🛠 Service Commands

```bash
# Panel status
systemctl status paqet-panel

# Restart panel
systemctl restart paqet-panel

# Live panel logs
journalctl -u paqet-panel -f

# Stop panel
systemctl stop paqet-panel
```

---

## 🔄 Update Panel

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/packet-tunnel/main/install.sh)
```

Re-running the installer updates the panel files and restarts the service.  
Your credentials and tunnel configs are **not affected**.

---

## ❌ Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/packet-tunnel/main/install.sh) uninstall
```

This removes the panel service, `/opt/paqet-panel/`, and `/etc/paqet-panel/`.  
Tunnel configs in `/etc/paqet/` and tunnel services are **left intact**.

---

## 📋 Requirements

| Requirement | Minimum |
|---|---|
| OS | Ubuntu 20.04 / Debian 11 / CentOS 8 or newer |
| Python | 3.8+ |
| RAM | 128 MB free |
| Disk | 200 MB free |
| Access | Root |
| Paqet | Installed via UI or manually |

---

## 🗝 Credentials

The installer asks you to choose a username and password during setup (step "Panel Credentials") — nothing is auto-generated unless the install is unattended (no terminal), in which case a random password is generated and printed once.

For a scripted install without prompts:
```bash
PANEL_USERNAME=admin PANEL_PASSWORD=yourpassword bash install.sh
```

Change either one later from **Settings → Security** inside the panel.

---

## 🧩 Tunnel Quick Reference

### Server (Kharej — external VPN endpoint)

Open **Add Server** in the panel and fill in:

- **Service Name** — any identifier (e.g. `kharej1`)
- **Listen Port** — the port Paqet will accept connections on (e.g. `8888`)
- **Secret Key** — auto-generated; copy it to the client
- **KCP Mode** — `fast` is recommended for most setups
- **Encryption** — `aes-128-gcm` recommended

### Client (Iran — domestic entry point)

Open **Add Client** and fill in:

- **Kharej Server IP** — public IP of the server above
- **Server Port** — same port you set on the server
- **Secret Key** — the key copied from the server
- **Traffic Type** — Port Forwarding (for V2Ray / Xray) or SOCKS5 Proxy
- **Forward Ports** — comma-separated ports, e.g. `443,80,8443`

---

## 💖 Support

If this project helped you, consider donating:

| Network | Address |
|---|---|
| **Tron (TRC20)** | `TQrfzgZbBDDJSFWd7E1YBoeHXH58MUWVqE` |
| **BEP20** | `0xef225De05Ea167e6a93e92D4298F987e524645f8` |

---

## 📞 Contact

- **Telegram:** [@erisrttg](https://t.me/erisrttg)
- **GitHub:** [eris4444/packet-tunnel](https://github.com/eris4444/packet-tunnel)

---

<div align="center">
Made by <a href="https://t.me/erisrttg">@erisrttg</a>
</div>
