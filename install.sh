#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  Erisrtg Packet Tunnel — Web Panel Installer
#  github.com/eris4444/packet-tunnel
#  همه فایل‌ها flat (بدون زیرپوشه) در /opt/paqet-panel/
# ════════════════════════════════════════════════════════════════
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

PANEL_DIR="/opt/paqet-panel"
SERVICE_NAME="paqet-panel"
PANEL_PORT="7777"
PANEL_USER="admin"
PANEL_PASS="$(tr -dc 'A-Za-z0-9!@#' </dev/urandom 2>/dev/null | head -c 16 || echo "Admin$(date +%s)")"
GITHUB_RAW="https://raw.githubusercontent.com/eris4444/packet-tunnel/main"

# فایل‌هایی که باید دانلود بشن (همه flat در ریشه ریپو)
PANEL_FILES=(
    "app.py"
    "base.html"
    "login.html"
    "dashboard.html"
    "services.html"
    "service_detail.html"
    "add_server.html"
    "add_client.html"
    "settings.html"
    "requirements.txt"
)

print_banner() {
    clear
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Erisrtg Packet Tunnel — Web Panel Installer                 ║"
    echo "║  Port: 7777  |  github.com/eris4444/packet-tunnel            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${RED}[✗] Run as root${NC}"; exit 1; }
}

detect_os() {
    [ -f /etc/os-release ] && { . /etc/os-release; echo "$ID"; return; }
    uname -s | tr '[:upper:]' '[:lower:]'
}

install_deps() {
    echo -e "${CYAN}[*] Installing dependencies...${NC}"
    local os; os=$(detect_os)
    case $os in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y python3 python3-pip python3-venv curl wget \
                libpcap-dev iptables iproute2 cron dnsutils >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y python3 python3-pip curl wget \
                libpcap-devel iptables iproute cronie bind-utils >/dev/null 2>&1
            ;;
        *)
            apt-get install -y python3 python3-pip python3-venv curl wget 2>/dev/null || \
            yum install -y python3 python3-pip curl wget 2>/dev/null || true
            ;;
    esac
    echo -e "${GREEN}[✓] Dependencies installed${NC}"
}

download_panel() {
    echo -e "${CYAN}[*] Downloading panel files to ${PANEL_DIR}/ ...${NC}"
    mkdir -p "$PANEL_DIR"

    local failed=0
    for file in "${PANEL_FILES[@]}"; do
        echo -n "    ↳ $file ... "
        if curl -fsSL "${GITHUB_RAW}/${file}" -o "${PANEL_DIR}/${file}" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            ((failed++))
        fi
    done

    if [ "$failed" -gt 0 ]; then
        echo -e "${YELLOW}[!] $failed file(s) failed to download.${NC}"
        echo -e "${YELLOW}    Make sure the files are pushed to: ${GITHUB_RAW}/${NC}"
    fi
}

setup_venv() {
    echo -e "${CYAN}[*] Creating Python virtual environment...${NC}"
    python3 -m venv "$PANEL_DIR/venv" 2>/dev/null || {
        apt-get install -y python3-venv 2>/dev/null || true
        python3 -m venv "$PANEL_DIR/venv"
    }
    "$PANEL_DIR/venv/bin/pip" install -q --upgrade pip
    if [ -f "$PANEL_DIR/requirements.txt" ]; then
        "$PANEL_DIR/venv/bin/pip" install -q -r "$PANEL_DIR/requirements.txt"
    else
        "$PANEL_DIR/venv/bin/pip" install -q flask pyyaml gunicorn
    fi
    echo -e "${GREEN}[✓] Python environment ready${NC}"
}

set_credentials() {
    echo -e "${CYAN}[*] Configuring credentials...${NC}"
    mkdir -p /etc/paqet-panel
    local hash
    hash=$(python3 -c "import hashlib; print(hashlib.sha256('${PANEL_PASS}'.encode()).hexdigest())")
    cat > /etc/paqet-panel/config.json << EOF
{
  "username": "${PANEL_USER}",
  "password_hash": "${hash}",
  "theme": "dark",
  "language": "en"
}
EOF
    chmod 600 /etc/paqet-panel/config.json
    echo -e "${GREEN}[✓] Credentials configured${NC}"
}

create_systemd() {
    echo -e "${CYAN}[*] Creating systemd service...${NC}"
    local secret
    secret=$(openssl rand -hex 32 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 64)
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Erisrtg Packet Tunnel Web Panel
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/venv/bin/gunicorn \\
    --workers 2 \\
    --bind 0.0.0.0:${PANEL_PORT} \\
    --timeout 60 \\
    --access-logfile /var/log/paqet-panel-access.log \\
    --error-logfile /var/log/paqet-panel-error.log \\
    app:app
Restart=always
RestartSec=5
Environment="PANEL_SECRET=${secret}"

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" --now
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}[✓] Panel service started${NC}"
    else
        echo -e "${YELLOW}[!] Service not active — check: journalctl -u ${SERVICE_NAME} -n 30${NC}"
    fi
}

open_firewall() {
    echo -e "${CYAN}[*] Opening port ${PANEL_PORT}...${NC}"
    iptables -I INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || true
    ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    echo -e "${GREEN}[✓] Firewall configured${NC}"
}

get_ip() {
    for s in ifconfig.me icanhazip.com api.ipify.org; do
        local ip; ip=$(curl -4 -s --max-time 3 "$s" 2>/dev/null)
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
    done
    hostname -I | awk '{print $1}'
}

print_result() {
    local ip; ip=$(get_ip)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ✅  Installation Complete!                           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}  📌 Panel Access${NC}"
    echo -e "  ┌──────────────────────────────────────────────────────────┐"
    printf  "  │  %-14s : %-40s│\n" "URL" "http://${ip}:${PANEL_PORT}"
    printf  "  │  %-14s : %-40s│\n" "Username" "${PANEL_USER}"
    printf  "  │  %-14s : %-40s│\n" "Password" "${PANEL_PASS}"
    echo -e "  └──────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${CYAN}  🛠  Commands${NC}"
    echo    "  systemctl status  ${SERVICE_NAME}"
    echo    "  systemctl restart ${SERVICE_NAME}"
    echo    "  journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo -e "${YELLOW}  ⚠️  Save your password — it won't be shown again!${NC}"
    echo ""
    echo -e "${MAGENTA}  Telegram: @erisrttg${NC}"
    echo ""
}

uninstall() {
    echo -e "${YELLOW}[*] Uninstalling...${NC}"
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -rf "$PANEL_DIR" /etc/paqet-panel
    systemctl daemon-reload
    echo -e "${GREEN}[✓] Uninstalled${NC}"
}

# ── MAIN ──────────────────────────────────────────────────────
print_banner
check_root

case "${1:-install}" in
    uninstall|remove) uninstall ;;
    *)
        install_deps
        download_panel
        setup_venv
        set_credentials
        create_systemd
        open_firewall
        print_result
        ;;
esac
