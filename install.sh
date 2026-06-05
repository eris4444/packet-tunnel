#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  Erisrtg Packet Tunnel — Web Panel Installer
#  github.com/eris4444/packet-tunnel
#  Compatible with Iran servers (no direct pypi access needed)
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

# Iran-accessible pip mirrors (ordered by reliability)
PIP_MIRRORS=(
    "https://mirrors.chpc.ac.ir/pypi/simple"
    "https://repo.iut.ac.ir/repo/pypi/simple"
    "https://ftp.iij.ad.jp/pub/pypi/simple"
    "https://pypi.tuna.tsinghua.edu.cn/simple"
    "https://mirror.sjtu.edu.cn/pypi/web/simple"
    "https://mirrors.aliyun.com/pypi/simple"
)

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

# ── Print ────────────────────────────────────────────────────
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

# ── Check if pip mirror is reachable ─────────────────────────
test_mirror() {
    local mirror="$1"
    curl -fsSL --max-time 5 "$mirror" >/dev/null 2>&1
}

# ── Find a working pip mirror ────────────────────────────────
find_pip_mirror() {
    # First try direct pypi (works on non-Iran servers)
    if curl -fsSL --max-time 5 "https://pypi.org/simple/pip/" >/dev/null 2>&1; then
        echo ""   # empty = use default (pypi.org)
        return
    fi

    echo -e "${YELLOW}[!] pypi.org unreachable, trying local mirrors...${NC}" >&2
    for mirror in "${PIP_MIRRORS[@]}"; do
        echo -n "    ↳ Testing $(echo "$mirror" | cut -d/ -f3) ... " >&2
        if test_mirror "$mirror"; then
            echo -e "${GREEN}OK${NC}" >&2
            echo "$mirror"
            return
        else
            echo -e "${RED}fail${NC}" >&2
        fi
    done

    echo ""  # no mirror found — will try apt fallback
}

# ── Install system packages ──────────────────────────────────
install_deps() {
    echo -e "${CYAN}[*] Installing system dependencies...${NC}"
    local os; os=$(detect_os)
    case $os in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            # Install python3 packages via apt (no pypi needed)
            apt-get install -y \
                python3 python3-pip python3-venv \
                python3-flask python3-yaml \
                curl wget libpcap-dev iptables \
                iproute2 cron dnsutils >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y \
                python3 python3-pip \
                python3-flask python3-pyyaml \
                curl wget libpcap-devel \
                iptables iproute cronie bind-utils >/dev/null 2>&1
            ;;
        *)
            apt-get install -y python3 python3-pip python3-venv \
                python3-flask python3-yaml curl wget 2>/dev/null || \
            yum install -y python3 python3-pip \
                python3-flask python3-pyyaml curl wget 2>/dev/null || true
            ;;
    esac
    echo -e "${GREEN}[✓] System dependencies installed${NC}"
}

# ── Download panel files from GitHub ────────────────────────
download_panel() {
    echo -e "${CYAN}[*] Downloading panel files to ${PANEL_DIR}/ ...${NC}"
    mkdir -p "$PANEL_DIR"

    local failed=0
    for file in "${PANEL_FILES[@]}"; do
        echo -n "    ↳ $file ... "
        if curl -fsSL --max-time 30 "${GITHUB_RAW}/${file}" \
               -o "${PANEL_DIR}/${file}" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            ((failed++))
        fi
    done

    if [ "$failed" -gt 0 ]; then
        echo -e "${YELLOW}[!] $failed file(s) failed. Check repo: ${GITHUB_RAW}${NC}"
    fi
}

# ── Setup Python environment ─────────────────────────────────
setup_python() {
    echo -e "${CYAN}[*] Setting up Python environment...${NC}"

    # ── Strategy 1: check if flask already installed system-wide (via apt) ──
    if python3 -c "import flask, yaml" 2>/dev/null; then
        echo -e "${GREEN}[✓] Flask & PyYAML found (system packages)${NC}"

        # Check gunicorn
        if python3 -c "import gunicorn" 2>/dev/null || command -v gunicorn &>/dev/null; then
            echo -e "${GREEN}[✓] Gunicorn found${NC}"
            # Create a thin venv wrapper that uses system packages
            _create_venv_with_system_packages
            return
        fi
        # gunicorn missing — try to get it
    fi

    # ── Strategy 2: venv + pip with mirror ──────────────────────
    echo -e "${CYAN}[*] Creating virtual environment...${NC}"
    _ensure_venv

    local mirror
    mirror=$(find_pip_mirror)

    if [ -n "$mirror" ]; then
        echo -e "${CYAN}[*] Installing packages via mirror: $(echo "$mirror" | cut -d/ -f3)${NC}"
        _pip_install_with_mirror "$mirror"
    else
        # ── Strategy 3: apt packages into venv via --system-site-packages ──
        echo -e "${YELLOW}[!] No pip mirror reachable. Trying system-site-packages venv...${NC}"
        _create_venv_with_system_packages

        # If gunicorn still missing, install it from apt
        if ! "$PANEL_DIR/venv/bin/python3" -c "import gunicorn" 2>/dev/null; then
            echo -e "${CYAN}[*] Installing gunicorn via apt...${NC}"
            apt-get install -y gunicorn 2>/dev/null || \
            yum install -y python3-gunicorn 2>/dev/null || \
            pip3 install gunicorn 2>/dev/null || true
        fi
    fi

    # ── Final check ─────────────────────────────────────────────
    _verify_packages
}

_ensure_venv() {
    if ! python3 -m venv "$PANEL_DIR/venv" 2>/dev/null; then
        apt-get install -y python3-venv 2>/dev/null || true
        python3 -m venv "$PANEL_DIR/venv"
    fi
}

_create_venv_with_system_packages() {
    # venv that can see system-installed packages (flask, yaml from apt)
    python3 -m venv --system-site-packages "$PANEL_DIR/venv" 2>/dev/null || {
        apt-get install -y python3-venv 2>/dev/null || true
        python3 -m venv --system-site-packages "$PANEL_DIR/venv"
    }
}

_pip_install_with_mirror() {
    local mirror="$1"
    local pip="$PANEL_DIR/venv/bin/pip"

    # Upgrade pip itself via mirror
    "$pip" install -q --upgrade pip \
        --index-url "$mirror" \
        --trusted-host "$(echo "$mirror" | cut -d/ -f3)" 2>/dev/null || true

    # Install packages
    "$pip" install -q \
        flask pyyaml gunicorn \
        --index-url "$mirror" \
        --trusted-host "$(echo "$mirror" | cut -d/ -f3)"
}

_verify_packages() {
    local python="$PANEL_DIR/venv/bin/python3"
    local ok=1

    echo -e "${CYAN}[*] Verifying packages...${NC}"
    for pkg in flask yaml gunicorn; do
        echo -n "    ↳ $pkg ... "
        if "$python" -c "import $pkg" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}MISSING${NC}"
            ok=0
        fi
    done

    if [ "$ok" -eq 0 ]; then
        echo -e "${RED}[✗] Some packages missing. Panel may not start.${NC}"
        echo -e "${YELLOW}    Try manually: pip3 install flask pyyaml gunicorn${NC}"
        echo -e "${YELLOW}    Or via apt:  apt install python3-flask python3-yaml gunicorn${NC}"
    else
        echo -e "${GREEN}[✓] Python environment ready${NC}"
    fi
}

# ── Write credentials ────────────────────────────────────────
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

# ── Detect gunicorn path ─────────────────────────────────────
get_gunicorn_path() {
    # Prefer venv gunicorn
    if [ -x "$PANEL_DIR/venv/bin/gunicorn" ]; then
        echo "$PANEL_DIR/venv/bin/gunicorn"; return
    fi
    # System gunicorn
    if command -v gunicorn &>/dev/null; then
        command -v gunicorn; return
    fi
    # python -m gunicorn fallback
    echo "$PANEL_DIR/venv/bin/python3 -m gunicorn"
}

# ── Create systemd service ───────────────────────────────────
create_systemd() {
    echo -e "${CYAN}[*] Creating systemd service...${NC}"
    local secret
    secret=$(openssl rand -hex 32 2>/dev/null || \
             tr -dc 'a-f0-9' </dev/urandom | head -c 64)
    local gunicorn_bin
    gunicorn_bin=$(get_gunicorn_path)

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Erisrtg Packet Tunnel Web Panel
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${gunicorn_bin} \\
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
        echo -e "${YELLOW}[!] Service not active.${NC}"
        echo -e "${YELLOW}    Check: journalctl -u ${SERVICE_NAME} -n 30${NC}"
    fi
}

# ── Open firewall ────────────────────────────────────────────
open_firewall() {
    echo -e "${CYAN}[*] Opening port ${PANEL_PORT}...${NC}"
    iptables -I INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || true
    ufw allow "${PANEL_PORT}/tcp"      >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload              >/dev/null 2>&1 || true
    echo -e "${GREEN}[✓] Firewall configured${NC}"
}

# ── Get public IP ─────────────────────────────────────────────
get_ip() {
    # Iran-accessible IP services
    for s in ip.sb ipinfo.io/ip checkip.amazonaws.com; do
        local ip; ip=$(curl -4 -s --max-time 4 "$s" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
    done
    hostname -I | awk '{print $1}'
}

# ── Print final result ────────────────────────────────────────
print_result() {
    local ip; ip=$(get_ip)
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ✅  Installation Complete!                           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}  📌 Panel Access${NC}"
    echo -e "  ┌──────────────────────────────────────────────────────────┐"
    printf  "  │  %-14s : %-40s│\n" "URL"      "http://${ip}:${PANEL_PORT}"
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

# ── Uninstall ─────────────────────────────────────────────────
uninstall() {
    echo -e "${YELLOW}[*] Uninstalling...${NC}"
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -rf "$PANEL_DIR" /etc/paqet-panel
    systemctl daemon-reload
    echo -e "${GREEN}[✓] Uninstalled${NC}"
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
print_banner
check_root

case "${1:-install}" in
    uninstall|remove) uninstall ;;
    *)
        install_deps
        download_panel
        setup_python
        set_credentials
        create_systemd
        open_firewall
        print_result
        ;;
esac
