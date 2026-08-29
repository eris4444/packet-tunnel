#!/usr/bin/env bash
# =================================================================
# Erisrtg Packet Tunnel - Termux Installer
# Run once:
#   bash <(curl -fsSL https://raw.githubusercontent.com/eris4444/packet-tunnel/main/termux-install.sh)
# =================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MANAGER_URL="https://raw.githubusercontent.com/eris4444/packet-tunnel/main/termux-manager.sh"
INSTALL_BIN="$PREFIX/bin/paqet-termux"

print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_err()  { echo -e "${RED}[X]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

clear
echo -e "${CYAN}"
echo "==================================================================="
echo "   Erisrtg Packet Tunnel - Termux Edition  |  Installer"
echo "   github.com/eris4444/packet-tunnel"
echo "==================================================================="
echo -e "${NC}"

# ── 1. Check Termux ──────────────────────────────────────────────
if [ -z "${PREFIX:-}" ] || [[ "$PREFIX" != *com.termux* ]]; then
    print_err "این اسکریپت فقط داخل ترموکس اجرا می‌شه."
    print_err "This script must be run inside Termux."
    exit 1
fi
print_ok "Termux environment detected."

# ── 2. Check root (Magisk su) ─────────────────────────────────────
print_info "Checking root access..."
if ! command -v su >/dev/null 2>&1; then
    print_warn "No 'su' binary found. The tunnel needs root to use raw sockets."
    print_warn "Install Magisk and grant Termux root access, then re-run."
    read -r -p "Continue anyway? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
elif su -c "id -u" 2>/dev/null | grep -q "^0$"; then
    print_ok "Root access confirmed (Magisk su)."
else
    print_warn "Could not verify root via su (try granting Termux root in Magisk)."
    read -r -p "Continue anyway? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# ── 3. Quick update & minimal deps for install step ──────────────
print_info "Updating package lists..."
pkg update -y -q 2>/dev/null || true

print_info "Installing curl/wget if missing..."
pkg install -y -q curl wget 2>/dev/null || true

# ── 4. Download main manager ──────────────────────────────────────
print_info "Downloading termux-manager.sh → $INSTALL_BIN ..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$MANAGER_URL" -o "$INSTALL_BIN"
elif command -v wget >/dev/null 2>&1; then
    wget -q "$MANAGER_URL" -O "$INSTALL_BIN"
else
    print_err "Neither curl nor wget available. Install one and retry."
    exit 1
fi

chmod +x "$INSTALL_BIN"
print_ok "Installed: $INSTALL_BIN"

# ── 5. Verify the downloaded script is not empty / is bash ───────
if ! head -1 "$INSTALL_BIN" | grep -q "bash"; then
    print_err "Downloaded file doesn't look like a bash script."
    print_err "Check your internet connection and try again."
    rm -f "$INSTALL_BIN"
    exit 1
fi

# ── 6. Done ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}==================================================================="
echo "   Installation complete!"
echo "==================================================================="
echo -e "${NC}"
echo -e " Run the manager anytime with:  ${CYAN}paqet-termux${NC}"
echo ""
echo -e " Quick-start order inside the manager:"
echo -e "   ${YELLOW}1${NC} → Install dependencies"
echo -e "   ${YELLOW}2${NC} → Build paqet from source  (needed once)"
echo -e "   ${YELLOW}3${NC} → Configure client tunnel  (while on Wi-Fi!)"
echo -e "   ${YELLOW}4${NC} → Start / manage tunnels"
echo -e "   ${YELLOW}6${NC} → Background / battery setup guide"
echo ""
echo -e " ${YELLOW}Important:${NC} Raw-socket tunneling almost certainly only works"
echo -e " over Wi-Fi, not over mobile data (no ARP/MAC on cellular interfaces)."
echo ""

read -r -p "Launch manager now? (Y/n): " launch
if [[ ! "$launch" =~ ^[Nn]$ ]]; then
    exec bash "$INSTALL_BIN"
fi
