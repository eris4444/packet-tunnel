#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  Erisrtg Packet Tunnel — Web Panel Installer v7.0
#  github.com/eris4444/packet-tunnel
#
#  Self-contained: همه فایل‌های پنل داخل این اسکریپت embed شدن
#  سازگار با: سرور ایران · سرور خارج · لینوکس لوکال
#  نصب: bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/packet-tunnel/main/install.sh)
# ════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BLUE='\033[0;34m'; NC='\033[0m'

PANEL_DIR="/opt/paqet-panel"
SERVICE_NAME="paqet-panel"
PANEL_PORT="7777"
PANEL_USER="admin"
PANEL_PASS="$(tr -dc 'A-Za-z0-9!@#' </dev/urandom 2>/dev/null | head -c 16 || echo "Admin$(date +%s)")"
PAQET_BIN="/usr/local/bin/paqet"
PAQET_REPO="hanselime/paqet"

PIP_MIRRORS=(
    "https://mirrors.chpc.ac.ir/pypi/simple"
    "https://repo.iut.ac.ir/repo/pypi/simple"
    "https://mirror.aut.ac.ir/pypi/simple"
    "https://pypi.iau.ir/simple"
    "https://repo.sharif.ir/pypi/simple"
    "https://pypi.tuna.tsinghua.edu.cn/simple"
    "https://mirror.sjtu.edu.cn/pypi/web/simple"
    "https://mirrors.aliyun.com/pypi/simple"
    "https://mirrors.cloud.tencent.com/pypi/simple"
    "https://mirrors.huaweicloud.com/repository/pypi/simple"
    "https://mirrors.163.com/pypi/simple"
    "https://mirrors.bfsu.edu.cn/pypi/simple"
    "https://pypi.mirrors.ustc.edu.cn/simple"
    "https://mirrors.zju.edu.cn/pypi/simple"
    "https://ftp.iij.ad.jp/pub/pypi/simple"
    "https://mirrors.gigenet.com/pypi/simple"
    "https://ftp.kaist.ac.kr/pypi/simple"
    "https://mirror.yandex.ru/mirrors/pypi/simple"
    "https://mirrors.xtom.ru/pypi/simple"
    "https://pypi.ircam.fr/simple"
    "https://mirrors.xtom.de/pypi/simple"
    "https://mirror.init7.net/pypi/simple"
    "https://mirrors.xtom.nl/pypi/simple"
    "https://pypi.fusioned.net/simple"
    "https://mirrors.xtom.com/pypi/simple"
    "https://pypi.org/simple"
)

# ════════════════════════════════════════════════════════════════
#  EMBEDDED PANEL FILES (base64 tar.gz)
# ════════════════════════════════════════════════════════════════
read -r -d '' PANEL_BUNDLE << 'BUNDLE_EOF' || true
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
BUNDLE_EOF

# ── UI helpers ──────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Erisrtg Packet Tunnel — Web Panel Installer                 ║"
    echo "║  Port: 7777  |  github.com/eris4444/packet-tunnel            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}
step_ok()   { echo -e "  ${GREEN}[✓]${NC} $*"; }
step_warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
step_err()  { echo -e "  ${RED}[✗]${NC} $*"; }
step_info() { echo -e "  ${CYAN}[*]${NC} $*"; }
step_head() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
              echo -e "${BLUE}  $*${NC}"
              echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[✗] Run as root (sudo bash install.sh)${NC}"; exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; echo "$ID"
    else uname -s | tr '[:upper:]' '[:lower:]'; fi
}

detect_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armhf)   echo "arm"   ;;
        i386|i686)      echo "386"   ;;
        *)              echo "$arch" ;;
    esac
}

# ════════════════════════════════════════════════════════════════
#  STEP 1 — System Dependencies
# ════════════════════════════════════════════════════════════════
install_deps() {
    step_head "Step 1 — System Dependencies"
    local os; os=$(detect_os)

    case $os in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            step_info "apt-get update..."
            apt-get update -qq 2>/dev/null || step_warn "apt update had warnings (continuing)"

            step_info "Installing core packages..."
            apt-get install -y python3 python3-pip python3-venv curl wget tar 2>/dev/null \
                && step_ok "Core packages" \
                || step_warn "Some core packages failed (may already be installed)"

            step_info "Installing Python packages via apt..."
            apt-get install -y python3-flask python3-yaml 2>/dev/null \
                && step_ok "Python apt packages" \
                || step_warn "Python apt packages not available (will use pip)"

            step_info "Installing system tools..."
            apt-get install -y libpcap-dev iptables iproute2 cron dnsutils 2>/dev/null \
                && step_ok "System tools" \
                || step_warn "Some system tools unavailable (non-critical)"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            local pm="yum"; command -v dnf &>/dev/null && pm="dnf"
            $pm install -y python3 python3-pip curl wget tar 2>/dev/null \
                && step_ok "Core packages" || step_warn "Some packages failed"
            $pm install -y python3-flask python3-pyyaml 2>/dev/null \
                && step_ok "Python packages" || step_warn "Python not in repo (will use pip)"
            $pm install -y libpcap-devel iptables iproute cronie bind-utils 2>/dev/null \
                && step_ok "System tools" || step_warn "Some tools unavailable"
            ;;
        *)
            step_warn "Unknown OS '$os' — trying apt..."
            apt-get install -y python3 python3-pip python3-venv curl wget tar 2>/dev/null || \
            yum install -y python3 python3-pip curl wget tar 2>/dev/null || \
            step_warn "Ensure python3 and curl are available"
            ;;
    esac

    if ! command -v python3 &>/dev/null; then
        step_err "python3 not found! Install it manually and re-run."
        exit 1
    fi
    step_ok "python3 $(python3 --version 2>&1 | awk '{print $2}')"
}

# ════════════════════════════════════════════════════════════════
#  STEP 2 — Paqet Core Installation
# ════════════════════════════════════════════════════════════════
install_paqet() {
    step_head "Step 2 — Paqet Core Installation"

    local os;   os=$(detect_os)
    local arch; arch=$(detect_arch)

    # Current installed version
    local cur_ver="Not installed"
    if [ -x "$PAQET_BIN" ]; then
        cur_ver=$("$PAQET_BIN" version 2>/dev/null | head -1 | grep -oP 'v[\d\.\-a-zA-Z]+' | head -1 || echo "unknown")
    fi

    echo ""
    echo -e "  ${CYAN}System Information:${NC}"
    printf  "   %-20s %s\n" "OS:"              "$os"
    printf  "   %-20s %s\n" "Arch:"            "$arch"
    printf  "   %-20s %s\n" "Current Version:" "$cur_ver"

    # Get latest version from GitHub API
    step_info "Fetching latest Paqet version from GitHub..."
    local latest_ver
    latest_ver=$(curl -fsSL --max-time 8 \
        "https://api.github.com/repos/${PAQET_REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [ -z "$latest_ver" ]; then
        # Fallback: try to get from releases page
        latest_ver=$(curl -fsSL --max-time 8 \
            "https://github.com/${PAQET_REPO}/releases/latest" 2>/dev/null \
            | grep -oP 'v[\d]+\.[\d]+\.[\d]+-?[a-zA-Z0-9.]*' | head -1)
    fi

    if [ -z "$latest_ver" ]; then
        step_warn "Could not fetch latest version — using fallback v1.0.0-alpha.19"
        latest_ver="v1.0.0-alpha.19"
    fi

    printf  "   %-20s %s\n" "Latest Version:"  "$latest_ver"

    # Already up to date?
    if [ "$cur_ver" = "$latest_ver" ]; then
        step_ok "Paqet is already up to date ($cur_ver)"
        return 0
    fi

    # Build download URL
    local filename="paqet-linux-${arch}-${latest_ver}.tar.gz"
    local url="https://github.com/${PAQET_REPO}/releases/download/${latest_ver}/${filename}"
    echo ""
    printf  "   %-20s %s\n" "Download URL:" "$url"
    echo ""

    # Download
    step_info "Downloading Paqet ${latest_ver} (${arch})..."
    local tmp_dir; tmp_dir=$(mktemp -d)
    local tmp_file="${tmp_dir}/${filename}"

    if curl -fsSL --max-time 60 --progress-bar "$url" -o "$tmp_file" 2>&1; then
        step_ok "Downloaded: $filename"
    else
        step_err "Download failed!"
        step_warn "URL: $url"
        step_warn "Check your internet connection or download manually:"
        echo    "    curl -L '$url' -o /tmp/paqet.tar.gz"
        echo    "    tar xzf /tmp/paqet.tar.gz && cp paqet /usr/local/bin/"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Extract
    step_info "Extracting..."
    if ! tar xzf "$tmp_file" -C "$tmp_dir" 2>/dev/null; then
        step_err "Extraction failed!"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Find the binary
    local bin_src
    bin_src=$(find "$tmp_dir" -name "paqet" -type f ! -name "*.tar.gz" | head -1)
    if [ -z "$bin_src" ]; then
        # Sometimes named differently
        bin_src=$(find "$tmp_dir" -maxdepth 3 -type f -perm /111 ! -name "*.tar.gz" | head -1)
    fi

    if [ -z "$bin_src" ]; then
        step_err "Binary not found in archive!"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Install
    cp -f "$bin_src" "$PAQET_BIN"
    chmod +x "$PAQET_BIN"
    rm -rf "$tmp_dir"

    # Verify
    if [ -x "$PAQET_BIN" ]; then
        local installed_ver
        installed_ver=$("$PAQET_BIN" version 2>/dev/null | head -1 || echo "installed")
        step_ok "Paqet installed: $installed_ver"
        step_ok "Binary: $PAQET_BIN"
    else
        step_err "Installation verification failed"
        return 1
    fi
}

# ════════════════════════════════════════════════════════════════
#  STEP 3 — Extract Panel Files
# ════════════════════════════════════════════════════════════════
extract_panel() {
    step_head "Step 3 — Panel Files"
    mkdir -p "$PANEL_DIR" || { step_err "Cannot create ${PANEL_DIR}"; exit 1; }

    if ! printf '%s' "$PANEL_BUNDLE" | base64 -d | tar xzf - -C "$PANEL_DIR" 2>/dev/null; then
        step_err "Extraction failed!"
        exit 1
    fi

    local count
    count=$(ls "$PANEL_DIR"/*.py "$PANEL_DIR"/*.html 2>/dev/null | wc -l)
    if [ "$count" -ge 9 ]; then
        step_ok "${count} panel files extracted to ${PANEL_DIR}/"
    else
        step_err "Only ${count} files found after extraction"
        exit 1
    fi
}

# ════════════════════════════════════════════════════════════════
#  STEP 4 — Python Environment
# ════════════════════════════════════════════════════════════════
find_pip_mirror() {
    local total=${#PIP_MIRRORS[@]}
    local tried=0
    echo -e "${CYAN}[*] Finding fastest pip mirror (${total} candidates)...${NC}" >&2
    for mirror in "${PIP_MIRRORS[@]}"; do
        ((tried++)) || true
        local host; host=$(echo "$mirror" | awk -F/ '{print $3}')
        printf "    [%2d/%d] %-45s " "$tried" "$total" "$host" >&2
        if curl -fsSL --max-time 4 "$mirror" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}" >&2
            echo "$mirror"; return 0
        else
            echo -e "${RED}✗${NC}" >&2
        fi
    done
    echo ""; return 1
}

_make_venv() {
    local flags="$1"
    [ -d "$PANEL_DIR/venv" ] && rm -rf "$PANEL_DIR/venv"
    if python3 -m venv $flags "$PANEL_DIR/venv" 2>/dev/null; then
        step_ok "Virtual environment created"; return 0
    fi
    step_warn "venv failed — installing python3-venv..."
    apt-get install -y python3-venv 2>/dev/null || true
    python3 -m venv $flags "$PANEL_DIR/venv" 2>/dev/null \
        && step_ok "Virtual environment created" \
        || { step_err "Cannot create venv"; exit 1; }
}

_apt_flask_fallback() {
    apt-get install -y python3-flask python3-yaml gunicorn 2>/dev/null \
        && step_ok "Installed flask/yaml/gunicorn via apt" \
        || step_warn "apt flask install failed"
    rm -rf "$PANEL_DIR/venv"
    python3 -m venv --system-site-packages "$PANEL_DIR/venv" 2>/dev/null || true
}

_ensure_gunicorn() {
    local python="$PANEL_DIR/venv/bin/python3"
    "$python" -c "import gunicorn" 2>/dev/null && return 0
    command -v gunicorn &>/dev/null && return 0
    step_info "Installing gunicorn..."
    local mirror; mirror=$(find_pip_mirror 2>/dev/null) || mirror=""
    if [ -n "$mirror" ]; then
        local host; host=$(echo "$mirror" | awk -F/ '{print $3}')
        "$PANEL_DIR/venv/bin/pip" install -q gunicorn \
            --index-url "$mirror" --trusted-host "$host" 2>/dev/null \
            || apt-get install -y gunicorn 2>/dev/null || true
    else
        apt-get install -y gunicorn 2>/dev/null || true
    fi
}

_verify_packages() {
    local python="$PANEL_DIR/venv/bin/python3"
    local all_ok=1
    for pkg in flask yaml gunicorn; do
        printf "    ↳ %-12s " "$pkg"
        if "$python" -c "import $pkg" 2>/dev/null; then echo -e "${GREEN}OK${NC}"
        else echo -e "${RED}MISSING${NC}"; all_ok=0; fi
    done
    if [ "$all_ok" -eq 1 ]; then
        step_ok "Python environment ready"; return 0
    else
        step_warn "Trying last-resort apt install..."
        apt-get install -y python3-flask python3-yaml gunicorn 2>/dev/null || true
        rm -rf "$PANEL_DIR/venv"
        python3 -m venv --system-site-packages "$PANEL_DIR/venv" 2>/dev/null || true
        "$python" -c "import flask, yaml, gunicorn" 2>/dev/null \
            && step_ok "Packages recovered" \
            || step_warn "Panel may not start — check logs after install"
    fi
}

setup_python() {
    step_head "Step 4 — Python Environment"

    if python3 -c "import flask, yaml" 2>/dev/null; then
        step_ok "Flask & PyYAML found (system packages)"
        _make_venv "--system-site-packages"
        _ensure_gunicorn
        _verify_packages; return
    fi

    _make_venv ""
    local mirror; mirror=$(find_pip_mirror) || mirror=""
    local pip="$PANEL_DIR/venv/bin/pip"

    step_info "Installing packages (flask pyyaml gunicorn)..."
    if [ -n "$mirror" ]; then
        local host; host=$(echo "$mirror" | awk -F/ '{print $3}')
        "$pip" install -q --upgrade pip \
            --index-url "$mirror" --trusted-host "$host" 2>/dev/null || true
        "$pip" install -q flask pyyaml gunicorn \
            --index-url "$mirror" --trusted-host "$host" 2>/dev/null \
            && step_ok "Packages installed via $host" \
            || { step_warn "Mirror install failed, trying apt..."; _apt_flask_fallback; }
    else
        step_warn "No pip mirror reachable — using apt fallback..."
        _apt_flask_fallback
    fi

    step_info "Verifying packages..."
    _verify_packages
}

# ════════════════════════════════════════════════════════════════
#  STEP 5 — Credentials
# ════════════════════════════════════════════════════════════════
set_credentials() {
    step_head "Step 5 — Panel Credentials"
    mkdir -p /etc/paqet-panel
    local hash
    hash=$(python3 -c "import hashlib; print(hashlib.sha256('${PANEL_PASS}'.encode()).hexdigest())" 2>/dev/null)
    [ -z "$hash" ] && { step_err "Failed to hash password"; exit 1; }
    cat > /etc/paqet-panel/config.json << EOF
{
  "username": "${PANEL_USER}",
  "password_hash": "${hash}",
  "theme": "dark",
  "language": "en"
}
EOF
    chmod 600 /etc/paqet-panel/config.json
    step_ok "Credentials saved to /etc/paqet-panel/config.json"
}

# ════════════════════════════════════════════════════════════════
#  STEP 6 — Systemd Service
# ════════════════════════════════════════════════════════════════
get_gunicorn() {
    [ -x "$PANEL_DIR/venv/bin/gunicorn" ] && { echo "$PANEL_DIR/venv/bin/gunicorn"; return; }
    command -v gunicorn &>/dev/null        && { command -v gunicorn; return; }
    echo "$PANEL_DIR/venv/bin/python3 -m gunicorn"
}

create_systemd() {
    step_head "Step 6 — Systemd Service"

    if ! command -v systemctl &>/dev/null; then
        step_warn "systemctl not found — skipping service creation"
        echo ""
        echo -e "  ${YELLOW}Run manually:${NC}"
        echo    "  cd ${PANEL_DIR} && $(get_gunicorn) --bind 0.0.0.0:${PANEL_PORT} app:app"
        return 0
    fi

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

    systemctl daemon-reload 2>/dev/null || true
    if systemctl enable "$SERVICE_NAME" --now 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            step_ok "Service started and enabled (systemd)"
        else
            step_warn "Service enabled but not yet active"
            step_warn "Check: journalctl -u ${SERVICE_NAME} -n 30"
        fi
    else
        step_warn "systemctl enable failed — trying direct start..."
        systemctl start "$SERVICE_NAME" 2>/dev/null || \
        step_warn "Manual: cd ${PANEL_DIR} && $(get_gunicorn) --bind 0.0.0.0:${PANEL_PORT} app:app"
    fi
}

# ════════════════════════════════════════════════════════════════
#  STEP 7 — Firewall
# ════════════════════════════════════════════════════════════════
open_firewall() {
    step_head "Step 7 — Firewall"
    iptables -I INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null && step_ok "iptables rule added" || true
    ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 && step_ok "ufw rule added" || true
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    step_ok "Port ${PANEL_PORT} open"
}

# ── Get public IP (validates — rejects HTML error pages) ─────────
get_ip() {
    local services=("ip.sb" "api.ipify.org" "ipinfo.io/ip" "2ip.ru"
                    "checkip.amazonaws.com" "ifconfig.me" "icanhazip.com")
    for svc in "${services[@]}"; do
        local ip
        ip=$(curl -4 -sS --max-time 4 --connect-timeout 3 \
             --user-agent 'curl/7.68' "https://${svc}" 2>/dev/null \
             || curl -4 -sS --max-time 4 "http://${svc}" 2>/dev/null)
        ip=$(echo "$ip" | tr -d '[:space:]' | head -c 15)
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
    local lip; lip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    [[ "$lip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$lip"; return; }
    hostname -I 2>/dev/null | awk '{print $1}'
}

# ── Print final result ────────────────────────────────────────────
print_result() {
    local ip; ip=$(get_ip)
    local paqet_ver="Not installed"
    [ -x "$PAQET_BIN" ] && paqet_ver=$("$PAQET_BIN" version 2>/dev/null | head -1 || echo "installed")

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
    printf  "  │  %-14s : %-40s│\n" "Paqet"    "${paqet_ver}"
    echo -e "  └──────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${CYAN}  🛠  Commands${NC}"
    printf  "  %-10s %s\n" "Status:"  "systemctl status  ${SERVICE_NAME}"
    printf  "  %-10s %s\n" "Restart:" "systemctl restart ${SERVICE_NAME}"
    printf  "  %-10s %s\n" "Logs:"    "journalctl -u ${SERVICE_NAME} -f"
    printf  "  %-10s %s\n" "Paqet:"   "${PAQET_BIN} --help"
    echo ""
    echo -e "${YELLOW}  ⚠️  Save your password — it won't be shown again!${NC}"
    echo ""
    echo -e "${MAGENTA}  Telegram: @erisrttg${NC}"
    echo ""
}

# ── Uninstall ─────────────────────────────────────────────────────
uninstall() {
    echo -e "${YELLOW}[*] Uninstalling panel...${NC}"
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -rf "$PANEL_DIR" /etc/paqet-panel
    systemctl daemon-reload 2>/dev/null || true
    echo -e "${GREEN}[✓] Panel uninstalled (Paqet binary kept at ${PAQET_BIN})${NC}"
}

# ════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════
print_banner
check_root

case "${1:-install}" in
    uninstall|remove)
        uninstall ;;
    update-paqet)
        install_paqet ;;
    *)
        install_deps
        install_paqet
        extract_panel
        setup_python
        set_credentials
        create_systemd
        open_firewall
        print_result
        ;;
esac
