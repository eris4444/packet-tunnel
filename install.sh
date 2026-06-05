#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  Erisrtg Packet Tunnel — Web Panel Installer v7.0
#  github.com/eris4444/packet-tunnel
#
#  Self-contained: همه فایل‌های پنل داخل این اسکریپت embed شدن
#  Iran-compatible: نیازی به دسترسی مستقیم به pypi.org نیست
#  نصب: bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/packet-tunnel/main/install.sh)
# ════════════════════════════════════════════════════════════════
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

PANEL_DIR="/opt/paqet-panel"
SERVICE_NAME="paqet-panel"
PANEL_PORT="7777"
PANEL_USER="admin"
PANEL_PASS="$(tr -dc 'A-Za-z0-9!@#' </dev/urandom 2>/dev/null | head -c 16 || echo "Admin$(date +%s)")"

# ══════════════════════════════════════════════════════════════
#  PIP MIRRORS — ایران + آسیا + اروپا + آمریکا
#  ترتیب: ایران اول، بقیه به عنوان fallback
# ══════════════════════════════════════════════════════════════
PIP_MIRRORS=(
    # ── ایران ──────────────────────────────────────────────────
    "https://mirrors.chpc.ac.ir/pypi/simple"        # مرکز HPC ایران
    "https://repo.iut.ac.ir/repo/pypi/simple"       # دانشگاه صنعتی اصفهان
    "https://mirror.aut.ac.ir/pypi/simple"           # دانشگاه صنعتی امیرکبیر
    "https://pypi.iau.ir/simple"                     # دانشگاه آزاد
    "https://repo.sharif.ir/pypi/simple"             # دانشگاه صنعتی شریف
    # ── چین ────────────────────────────────────────────────────
    "https://pypi.tuna.tsinghua.edu.cn/simple"       # Tsinghua University
    "https://mirror.sjtu.edu.cn/pypi/web/simple"     # Shanghai Jiao Tong
    "https://mirrors.aliyun.com/pypi/simple"         # Alibaba Cloud
    "https://mirrors.cloud.tencent.com/pypi/simple"  # Tencent Cloud
    "https://mirrors.huaweicloud.com/repository/pypi/simple" # Huawei Cloud
    "https://mirrors.163.com/pypi/simple"            # NetEase 163
    "https://mirrors.bfsu.edu.cn/pypi/simple"        # Beijing Foreign Studies Univ
    "https://pypi.mirrors.ustc.edu.cn/simple"        # Univ of Sci & Tech China
    "https://mirrors.zju.edu.cn/pypi/simple"         # Zhejiang University
    # ── ژاپن ───────────────────────────────────────────────────
    "https://ftp.iij.ad.jp/pub/pypi/simple"          # IIJ Japan
    "https://mirrors.gigenet.com/pypi/simple"        # GigeNET Japan
    # ── کره ────────────────────────────────────────────────────
    "https://ftp.kaist.ac.kr/pypi/simple"            # KAIST Korea
    # ── روسیه ──────────────────────────────────────────────────
    "https://mirror.yandex.ru/mirrors/pypi/simple"   # Yandex Russia
    "https://mirrors.xtom.ru/pypi/simple"            # xTom Russia
    # ── اروپا ──────────────────────────────────────────────────
    "https://pypi.ircam.fr/simple"                   # IRCAM France
    "https://mirrors.xtom.de/pypi/simple"            # xTom Germany
    "https://mirror.init7.net/pypi/simple"           # Init7 Switzerland
    "https://mirrors.xtom.nl/pypi/simple"            # xTom Netherlands
    "https://pypi.fusioned.net/simple"               # Fusioned UK
    # ── آمریکا ─────────────────────────────────────────────────
    "https://mirrors.xtom.com/pypi/simple"           # xTom USA
    "https://pypi.org/simple"                        # PyPI اصلی (آخرین تلاش)
)

# ════════════════════════════════════════════════════════════════
#  EMBEDDED PANEL FILES (base64 tar.gz)
# ════════════════════════════════════════════════════════════════
read -r -d '' PANEL_BUNDLE << 'BUNDLE_EOF' || true
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
BUNDLE_EOF

# ── print_banner ────────────────────────────────────────────────
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

# ── Extract embedded files ──────────────────────────────────────
extract_panel() {
    echo -e "${CYAN}[*] Extracting panel files to ${PANEL_DIR}/ ...${NC}"
    mkdir -p "$PANEL_DIR"
    printf '%s' "$PANEL_BUNDLE" | base64 -d | tar xzf - -C "$PANEL_DIR"
    local count
    count=$(ls "$PANEL_DIR"/*.py "$PANEL_DIR"/*.html 2>/dev/null | wc -l)
    if [ "$count" -ge 9 ]; then
        echo -e "${GREEN}[✓] ${count} panel files extracted${NC}"
    else
        echo -e "${RED}[✗] Extraction failed (only ${count} files found)${NC}"
        exit 1
    fi
}

# ── Install system dependencies ─────────────────────────────────
install_deps() {
    echo -e "${CYAN}[*] Installing system dependencies...${NC}"
    local os; os=$(detect_os)
    case $os in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
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

# ── Find first working pip mirror ──────────────────────────────
find_pip_mirror() {
    local total=${#PIP_MIRRORS[@]}
    local tried=0

    echo -e "${CYAN}[*] Finding fastest pip mirror (${total} candidates)...${NC}" >&2

    for mirror in "${PIP_MIRRORS[@]}"; do
        ((tried++))
        local host; host=$(echo "$mirror" | awk -F/ '{print $3}')
        printf "    [%2d/%d] %-45s " "$tried" "$total" "$host" >&2
        if curl -fsSL --max-time 4 "$mirror" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}" >&2
            echo "$mirror"
            return
        else
            echo -e "${RED}✗${NC}" >&2
        fi
    done

    echo "" # all failed
    echo -e "${RED}[✗] All mirrors failed.${NC}" >&2
}

# ── Setup Python environment ────────────────────────────────────
setup_python() {
    echo -e "${CYAN}[*] Setting up Python environment...${NC}"

    # Strategy 1: flask already installed via apt
    if python3 -c "import flask, yaml" 2>/dev/null; then
        echo -e "${GREEN}[✓] Flask & PyYAML found (apt packages)${NC}"
        python3 -m venv --system-site-packages "$PANEL_DIR/venv" 2>/dev/null || {
            apt-get install -y python3-venv 2>/dev/null || true
            python3 -m venv --system-site-packages "$PANEL_DIR/venv"
        }
        _ensure_gunicorn
        _verify_packages
        return
    fi

    # Strategy 2: venv + pip with mirror
    echo -e "${CYAN}[*] Creating virtual environment...${NC}"
    python3 -m venv "$PANEL_DIR/venv" 2>/dev/null || {
        apt-get install -y python3-venv 2>/dev/null || true
        python3 -m venv "$PANEL_DIR/venv"
    }

    local mirror; mirror=$(find_pip_mirror)
    local pip="$PANEL_DIR/venv/bin/pip"

    echo -e "${CYAN}[*] Installing Python packages...${NC}"
    if [ -n "$mirror" ]; then
        local host; host=$(echo "$mirror" | awk -F/ '{print $3}')
        "$pip" install -q --upgrade pip \
            --index-url "$mirror" --trusted-host "$host" 2>/dev/null || true
        "$pip" install -q flask pyyaml gunicorn \
            --index-url "$mirror" --trusted-host "$host"
    else
        # Strategy 3: all mirrors failed — apt last resort
        echo -e "${YELLOW}[!] No mirror reachable. Using apt fallback...${NC}"
        apt-get install -y gunicorn python3-flask python3-yaml 2>/dev/null || true
        rm -rf "$PANEL_DIR/venv"
        python3 -m venv --system-site-packages "$PANEL_DIR/venv"
    fi

    _verify_packages
}

_ensure_gunicorn() {
    if "$PANEL_DIR/venv/bin/python3" -c "import gunicorn" 2>/dev/null || \
       command -v gunicorn &>/dev/null; then
        return
    fi
    echo -e "${CYAN}[*] Installing gunicorn...${NC}"
    local mirror; mirror=$(find_pip_mirror)
    if [ -n "$mirror" ]; then
        local host; host=$(echo "$mirror" | awk -F/ '{print $3}')
        "$PANEL_DIR/venv/bin/pip" install -q gunicorn \
            --index-url "$mirror" --trusted-host "$host" 2>/dev/null || \
        apt-get install -y gunicorn 2>/dev/null || true
    else
        apt-get install -y gunicorn 2>/dev/null || true
    fi
}

_verify_packages() {
    local python="$PANEL_DIR/venv/bin/python3"
    echo -e "${CYAN}[*] Verifying packages...${NC}"
    local ok=1
    for pkg in flask yaml gunicorn; do
        printf "    ↳ %-12s " "$pkg"
        if "$python" -c "import $pkg" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}MISSING${NC}"; ok=0
        fi
    done
    if [ "$ok" -eq 1 ]; then
        echo -e "${GREEN}[✓] Python environment ready${NC}"
    else
        echo -e "${YELLOW}[!] Trying last-resort apt install...${NC}"
        apt-get install -y python3-flask python3-yaml gunicorn 2>/dev/null || true
        rm -rf "$PANEL_DIR/venv"
        python3 -m venv --system-site-packages "$PANEL_DIR/venv"
        echo -e "${YELLOW}[!] Check service logs if panel fails to start${NC}"
    fi
}

# ── Write credentials ───────────────────────────────────────────
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

# ── Find gunicorn binary ────────────────────────────────────────
get_gunicorn() {
    [ -x "$PANEL_DIR/venv/bin/gunicorn" ] && { echo "$PANEL_DIR/venv/bin/gunicorn"; return; }
    command -v gunicorn &>/dev/null             && { command -v gunicorn; return; }
    echo "$PANEL_DIR/venv/bin/python3 -m gunicorn"
}

# ── Create systemd service ──────────────────────────────────────
create_systemd() {
    echo -e "${CYAN}[*] Creating systemd service...${NC}"
    local secret
    secret=$(openssl rand -hex 32 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 64)
    local gunicorn; gunicorn=$(get_gunicorn)

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Erisrtg Packet Tunnel Web Panel
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${gunicorn} \\
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
        echo -e "    Run: journalctl -u ${SERVICE_NAME} -n 30"
    fi
}

# ── Open firewall ───────────────────────────────────────────────
open_firewall() {
    echo -e "${CYAN}[*] Opening port ${PANEL_PORT}...${NC}"
    iptables -I INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || true
    ufw allow "${PANEL_PORT}/tcp"      >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload              >/dev/null 2>&1 || true
    echo -e "${GREEN}[✓] Firewall configured${NC}"
}

# ── Get public IP ───────────────────────────────────────────────
get_ip() {
    for s in ip.sb ipinfo.io/ip checkip.amazonaws.com 2ip.ru api.ipify.org; do
        local ip; ip=$(curl -4 -s --max-time 4 "$s" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
    done
    hostname -I | awk '{print $1}'
}

# ── Print result ────────────────────────────────────────────────
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

# ── Uninstall ───────────────────────────────────────────────────
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
        extract_panel
        setup_python
        set_credentials
        create_systemd
        open_firewall
        print_result
        ;;
esac
