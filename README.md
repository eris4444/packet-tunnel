<div align="center">

<img src="https://img.shields.io/badge/Version-2.0.0-2080ff?style=for-the-badge&logo=linux" alt="Version">
<img src="https://img.shields.io/badge/Port-7777-00c97a?style=for-the-badge" alt="Port">
<img src="https://img.shields.io/badge/Python-3.8+-yellow?style=for-the-badge&logo=python" alt="Python">
<img src="https://img.shields.io/badge/License-MIT-blueviolet?style=for-the-badge" alt="License">

# 🌐 Erisrtg Packet Tunnel — Web Panel

**A full-featured web management panel for [Erisrtg Packet Tunnel](https://github.com/eris4444/packet-tunnel)**

*KCP-based raw socket tunnel for firewall / DPI bypass*

[فارسی](./Readme.fa.md) · [Telegram](https://t.me/erisrttg) · [Report Bug](https://github.com/eris4444/packet-tunnel/issues)

</div>

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

---

## 🚀 Quick Install

Run this on your server **as root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/packet-tunnel/main/install.sh)
```

After installation you will see:

```
╔══════════════════════════════════════════════════════════════╗
║         ✅  Installation Complete!                           ║
╚══════════════════════════════════════════════════════════════╝

  📌 Panel Access
  ┌──────────────────────────────────────────────────────────┐
  │  URL           : http://<YOUR-IP>:7777                   │
  │  Username      : admin                                   │
  │  Password      : xK9#mR2!pL7vQ4nJ                       │
  └──────────────────────────────────────────────────────────┘

  ⚠️  Save your password — it won't be shown again!
```

> **Note:** The password is randomly generated at install time. Save it immediately.

---

## 🗂 File Structure

All files are **flat** in the root of the repository — no subdirectories:

```
packet-tunnel/
├── install.sh           ← one-command installer
├── app.py               ← Flask backend (template_folder = same dir)
├── requirements.txt     ← flask · pyyaml · gunicorn
├── base.html            ← shared layout: sidebar + header
├── login.html
├── dashboard.html
├── services.html
├── service_detail.html
├── add_server.html
├── add_client.html
├── settings.html
├── README.md            ← this file (English)
└── README.fa.md         ← Persian version
```

After installation, all files are copied to `/opt/paqet-panel/` on your server:

```
/opt/paqet-panel/         ← panel files (flat)
/etc/paqet-panel/
└── config.json           ← credentials & theme/language settings
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
- **Gunicorn** with 2 workers binds to `0.0.0.0:7777` (accessible from any IP)
- **systemd** manages both the panel service and all tunnel services
- **Credentials** are stored in `/etc/paqet-panel/config.json` as a SHA-256 hash

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

## 🗝 Default Credentials

| Field | Value |
|---|---|
| Username | `admin` |
| Password | *Auto-generated at install — shown once in terminal* |

Change both from **Settings → Security** inside the panel after first login.

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
