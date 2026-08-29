#!/usr/bin/env bash
#=================================================================
# Erisrtg Packet Tunnel - TERMUX EDITION (client/Iran role only)
# Rewritten from scratch for Termux on rooted Android (Magisk).
#
# IMPORTANT REALITY CHECK (read this before reporting bugs):
#
# 1) paqet uses libpcap + raw sockets. Prebuilt Linux binaries are
#    glibc-linked and will NOT run on Termux's bionic libc, so this
#    script builds paqet FROM SOURCE inside Termux.
#
# 2) Raw socket / pcap injection needs root. On Android this means
#    running the actual paqet process via `su` (Magisk). This is
#    inherently experimental: some kernels/SELinux policies restrict
#    raw sockets even for root. Test it; don't assume it will work.
#
# 3) paqet crafts Ethernet-layer frames and needs the gateway's MAC
#    address (ARP). Cellular data interfaces (rmnet/ccmni/...) are
#    typically point-to-point and have NO classic ARP/MAC. In
#    practice this almost certainly only works over Wi-Fi, not over
#    mobile data. The script will warn you if it detects this.
#
# 4) Termux has no systemd. Service supervision + auto-restart here
#    is done with `termux-services` (a runit-based supervisor), not
#    systemctl/journalctl/cron.
#
# 5) Android will suspend/kill background processes unless you take
#    a wake lock and exempt Termux from battery optimization. See
#    menu option 5 for guidance.
#=================================================================

set -o pipefail

# ── Always bind stdin to the real terminal ───────────────────────
# Covers two cases:
#   1) Launched via  curl ... | bash  (stdin = pipe, not tty)
#   2) Some Termux terminal emulators where read -p misbehaves
# Non-fatal: if /dev/tty is unavailable the script still continues.
exec </dev/tty 2>/dev/null || true

# ---------------- Colors ----------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="1.0-termux"

# ---------------- Paths (all inside Termux's own HOME, no /etc /opt) ----------------
readonly BASE_DIR="$HOME/.paqet-termux"
readonly CONFIG_DIR="$BASE_DIR/configs"
readonly LOG_DIR="$BASE_DIR/logs"
readonly SRC_DIR="$BASE_DIR/src/paqet"
readonly BIN_PATH="$PREFIX/bin/paqet"
readonly SERVICE_BASE="$HOME/.termux/service"
readonly GITHUB_REPO_URL="https://github.com/hanselime/paqet.git"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$BASE_DIR/src"

# ---------------- Defaults ----------------
readonly DEFAULT_SERVER_PORT="8888"
readonly DEFAULT_KCP_MODE="fast"
readonly DEFAULT_ENCRYPTION="aes-128-gcm"
readonly DEFAULT_CONNECTIONS="2"
readonly DEFAULT_MTU="1350"
readonly DEFAULT_SOCKS5_PORT="1080"

declare -A KCP_MODES=(
    ["0"]="normal:Normal speed / normal latency / low resource use"
    ["1"]="fast:Balanced speed / low latency (recommended)"
    ["2"]="fast2:High speed / lower latency / higher CPU"
    ["3"]="fast3:Max speed / very low latency / high CPU"
    ["4"]="manual:Advanced manual tuning"
)

declare -A ENCRYPTION_OPTIONS=(
    ["1"]="aes-128-gcm:Fast, secure, recommended"
    ["2"]="aes:General use"
    ["3"]="aes-128:Fast, low CPU"
    ["4"]="aes-192:Higher security, more CPU"
    ["5"]="aes-256:Max security, most CPU"
    ["6"]="none:No encryption (insecure, fastest)"
)

# ---------------- Utility printing ----------------
print_step()    { echo -e "${CYAN}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error()   { echo -e "${RED}[X]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info()    { echo -e "${CYAN}[i]${NC} $1"; }
pause() { local m="${1:-Press Enter to continue...}"; echo ""; printf "%s" "$m"; read -r </dev/tty; }

show_banner() {
    clear
    echo -e "${MAGENTA}"
    echo "==================================================================="
    echo "   Erisrtg Packet Tunnel - TERMUX EDITION (client/Iran role)"
    echo "   v${SCRIPT_VERSION}  -  built on rooted Termux, native bionic build"
    echo "==================================================================="
    echo -e "${NC}"
}

# ---------------- Environment checks ----------------
ROOT_OK=0
IS_TERMUX=0

check_termux() {
    if [ -z "${PREFIX:-}" ] || [[ "$PREFIX" != *com.termux* ]]; then
        print_error "This does not look like a Termux environment (\$PREFIX=$PREFIX)."
        print_error "This script is meant to run inside the Termux app."
        exit 1
    fi
    IS_TERMUX=1
}

run_root() {
    # Runs a single shell command string as root via Magisk's su.
    su -c "$1"
}

check_root() {
    if ! command -v su >/dev/null 2>&1; then
        print_error "No 'su' binary found in PATH. Is the device actually rooted/Magisk installed?"
        ROOT_OK=0
        return 1
    fi
    if run_root "id -u" 2>/dev/null | grep -q "^0$"; then
        ROOT_OK=1
        print_success "Root access confirmed via su."
        return 0
    else
        print_error "Could not get root via su (permission denied or no Magisk grant)."
        ROOT_OK=0
        return 1
    fi
}

# ---------------- Dependencies & build ----------------
install_dependencies() {
    clear; show_banner
    print_step "Updating Termux package lists..."
    pkg update -y >/dev/null 2>&1
    pkg upgrade -y >/dev/null 2>&1

    print_step "Installing build & runtime dependencies..."
    pkg install -y golang git clang make iproute2 curl wget net-tools termux-services >/dev/null 2>&1

    # libpcap package name changed over time in Termux; try both.
    pkg install -y libpcap >/dev/null 2>&1 || pkg install -y libpcap-dev >/dev/null 2>&1

    # Optional, non-fatal extras
    pkg install -y openssl-tool >/dev/null 2>&1 || true
    pkg install -y dnsutils >/dev/null 2>&1 || true
    pkg install -y termux-api >/dev/null 2>&1 || true

    if command -v go >/dev/null 2>&1 && command -v clang >/dev/null 2>&1; then
        print_success "Go and clang are available."
    else
        print_error "go or clang missing after install. Check your Termux mirrors (termux-change-repo) and retry."
        pause
        return 1
    fi

    print_success "Dependencies installed."
    pause
}

build_paqet() {
    clear; show_banner
    print_step "Building paqet from source (native Termux/bionic build)..."

    if ! command -v go >/dev/null 2>&1; then
        print_error "Go not installed. Run option 1 first (Install dependencies)."
        pause; return 1
    fi

    if [ -d "$SRC_DIR/.git" ]; then
        print_info "Source exists, pulling latest..."
        (cd "$SRC_DIR" && git pull --ff-only) || print_warning "git pull failed, continuing with existing source"
    else
        print_info "Cloning paqet source..."
        rm -rf "$SRC_DIR"
        git clone --depth 1 "$GITHUB_REPO_URL" "$SRC_DIR" || { print_error "Clone failed"; pause; return 1; }
    fi

    (
        cd "$SRC_DIR" || exit 1
        export CGO_ENABLED=1
        export CC=clang
        go build -o "$BIN_PATH" ./cmd/paqet
    )

    if [ -x "$BIN_PATH" ]; then
        print_success "Built: $BIN_PATH"
        "$BIN_PATH" version 2>/dev/null || print_info "(binary runs, version subcommand output above if any)"
    else
        print_error "Build failed. Common cause: libpcap headers not found -- make sure 'pkg install libpcap' succeeded."
        pause; return 1
    fi
    pause
}

# ---------------- Network info ----------------
NETWORK_INTERFACE=""
LOCAL_IP=""
GATEWAY_IP=""
GATEWAY_MAC=""

# hex little-endian (Android /proc/net/route) → dotted decimal
_hex_to_ip() {
    local h="$1"
    printf '%d.%d.%d.%d'         "0x${h:6:2}" "0x${h:4:2}" "0x${h:2:2}" "0x${h:0:2}" 2>/dev/null || echo ""
}

get_network_info() {
    NETWORK_INTERFACE=""
    LOCAL_IP=""
    GATEWAY_IP=""
    GATEWAY_MAC=""

    # ── 1. Interface + gateway from /proc/net/route (most reliable on Android) ──
    if [ -r /proc/net/route ]; then
        local best_line
        best_line=$(awk 'NR>1 && $2=="00000000" && $8>0 {print}' /proc/net/route 2>/dev/null | head -1)
        if [ -z "$best_line" ]; then
            # some kernels have flags in different position; just grab Destination=00000000
            best_line=$(grep -v "^Iface" /proc/net/route 2>/dev/null | awk '$2=="00000000"' | head -1)
        fi
        if [ -n "$best_line" ]; then
            NETWORK_INTERFACE=$(echo "$best_line" | awk '{print $1}')
            local gw_hex; gw_hex=$(echo "$best_line" | awk '{print $3}')
            GATEWAY_IP=$(_hex_to_ip "$gw_hex")
        fi
    fi

    # ── 2. Fallback: scan /sys/class/net for active WiFi interfaces ──
    if [ -z "$NETWORK_INTERFACE" ] || [ "$NETWORK_INTERFACE" = "unknown" ]; then
        for iface in wlan0 wlan1 wlan2 eth0 eth1; do
            if [ -d "/sys/class/net/$iface" ]; then
                local operstate; operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)
                if [ "$operstate" = "up" ] || [ "$operstate" = "unknown" ]; then
                    NETWORK_INTERFACE="$iface"
                    break
                fi
            fi
        done
    fi

    # ── 3. Local IP: try ip addr first, then /proc/net/fib_trie, then ifconfig ──
    if [ -n "$NETWORK_INTERFACE" ] && [ "$NETWORK_INTERFACE" != "unknown" ]; then
        LOCAL_IP=$(ip -4 addr show dev "$NETWORK_INTERFACE" 2>/dev/null             | grep -oE 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'             | awk '{print $2}' | head -1)

        if [ -z "$LOCAL_IP" ]; then
            LOCAL_IP=$(ip addr show "$NETWORK_INTERFACE" 2>/dev/null                 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
        fi

        if [ -z "$LOCAL_IP" ] && command -v ifconfig >/dev/null 2>&1; then
            LOCAL_IP=$(ifconfig "$NETWORK_INTERFACE" 2>/dev/null                 | grep -oE 'addr:[0-9.]+' | cut -d: -f2 | head -1)
            [ -z "$LOCAL_IP" ] && LOCAL_IP=$(ifconfig "$NETWORK_INTERFACE" 2>/dev/null                 | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)
        fi
    fi

    # ── 4. Gateway IP fallback via ip route ──
    if [ -z "$GATEWAY_IP" ] && command -v ip >/dev/null 2>&1; then
        GATEWAY_IP=$(ip route 2>/dev/null | awk '/^default/ {print $3}' | head -1)
    fi

    # ── 5. Gateway MAC: /proc/net/arp first (no extra tools needed) ──
    if [ -n "$GATEWAY_IP" ]; then
        ping -c 2 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 || true
        # /proc/net/arp columns: IP HW_type Flags MAC Mask Device
        GATEWAY_MAC=$(awk -v gw="$GATEWAY_IP" '$1==gw && $4!="00:00:00:00:00:00" {print $4}'             /proc/net/arp 2>/dev/null | head -1)

        if [ -z "$GATEWAY_MAC" ] && command -v ip >/dev/null 2>&1; then
            GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null                 | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
        fi
    fi

    NETWORK_INTERFACE="${NETWORK_INTERFACE:-unknown}"
}

warn_if_cellular() {
    case "$NETWORK_INTERFACE" in
        wlan*|eth*)
            print_success "Interface '$NETWORK_INTERFACE' looks like Wi-Fi/Ethernet — good."
            ;;
        rmnet*|ccmni*|ccinet*|pdp*|usb*)
            print_warning "Interface '$NETWORK_INTERFACE' is a CELLULAR data link."
            print_warning "Raw-socket framing needs a gateway MAC — cellular links usually don't have one."
            print_warning "Connect to Wi-Fi and re-run."
            ;;
        *)
            print_info "Interface '$NETWORK_INTERFACE' — type unrecognized (probably fine on Wi-Fi)."
            ;;
    esac
}

get_public_ip() {
    local services=("ifconfig.me" "icanhazip.com" "api.ipify.org")
    for s in "${services[@]}"; do
        local ip
        ip=$(curl -4 -s --max-time 3 "$s" 2>/dev/null)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    echo "Not Detected"
}

# ---------------- Validation helpers ----------------
validate_ip() {
    local ip=$1
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -ra o <<< "$ip"
    for x in "${o[@]}"; do [ "$x" -ge 0 ] && [ "$x" -le 255 ] || return 1; done
    return 0
}
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
clean_config_name() { local n; n=$(echo "$1" | tr -cd '[:alnum:]-_'); echo "${n:-client}"; }
clean_port_list() {
    local out=""
    IFS=',' read -ra arr <<< "$(echo "$1" | tr -d ' ')"
    for p in "${arr[@]}"; do
        validate_port "$p" && out="${out:+$out,}$p"
    done
    echo "$out"
}
generate_secret_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
    else
        tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32
    fi
}

# ---------------- Optional best-effort iptables (often unavailable on Android) ----------------
iptables_try() {
    local port="$1" proto="$2"
    if [ "$ROOT_OK" != "1" ]; then return 0; fi
    if ! run_root "command -v iptables" >/dev/null 2>&1; then
        print_warning "iptables not available on this device/ROM, skipping (not fatal)."
        return 0
    fi
    local protos=()
    [ "$proto" = "both" ] && protos=("tcp" "udp") || protos=("$proto")
    for p in "${protos[@]}"; do
        run_root "iptables -t raw -D PREROUTING -p $p --dport $port -j NOTRACK" >/dev/null 2>&1 || true
        run_root "iptables -t raw -A PREROUTING -p $p --dport $port -j NOTRACK" >/dev/null 2>&1 || true
        run_root "iptables -t raw -D OUTPUT -p $p --sport $port -j NOTRACK" >/dev/null 2>&1 || true
        run_root "iptables -t raw -A OUTPUT -p $p --sport $port -j NOTRACK" >/dev/null 2>&1 || true
    done
    print_success "iptables NOTRACK applied for port $port/$proto (best-effort)."
}

# ---------------- Manual KCP (shortened) ----------------
get_manual_kcp_settings() {
    local nodelay interval resend nocongestion rcvwnd sndwnd
    printf "%s" "  nodelay [0-2, default 1]: "; read -r nodelay </dev/tty; nodelay="${nodelay:-1}"
    printf "%s" "  interval ms [default 20]: "; read -r interval </dev/tty; interval="${interval:-20}"
    printf "%s" "  resend [default 1]: "; read -r resend </dev/tty; resend="${resend:-1}"
    printf "%s" "  nocongestion 0/1 [default 1]: "; read -r nocongestion </dev/tty; nocongestion="${nocongestion:-1}"
    printf "%s" "  rcvwnd [default 1024]: "; read -r rcvwnd </dev/tty; rcvwnd="${rcvwnd:-1024}"
    printf "%s" "  sndwnd [default 1024]: "; read -r sndwnd </dev/tty; sndwnd="${sndwnd:-1024}"
    echo "mode: \"manual\""
    echo "nodelay: $nodelay"
    echo "interval: $interval"
    echo "resend: $resend"
    echo "nocongestion: $nocongestion"
    echo "rcvwnd: $rcvwnd"
    echo "sndwnd: $sndwnd"
}

# ---------------- Client configuration wizard ----------------
configure_client() {
    while true; do
        clear; show_banner
        echo -e "${GREEN}Configure Client (this phone = Iran entry point)${NC}\n"

        get_network_info
        local pub_ip; pub_ip=$(get_public_ip)

        echo -e "${YELLOW}Detected network${NC}"
        printf " Interface  : %s\n" "${NETWORK_INTERFACE:-not found}"
        printf " Local IP   : %s\n" "${LOCAL_IP:-not found}"
        printf " Gateway IP : %s\n" "${GATEWAY_IP:-not found}"
        printf " Gateway MAC: %s\n" "${GATEWAY_MAC:-NOT FOUND}"
        printf " Public IP  : %s\n" "$pub_ip"
        echo ""
        warn_if_cellular

        # ── Manual override when auto-detection fails ──────────────────
        local net_ok=1
        [ -z "$NETWORK_INTERFACE" ] || [ "$NETWORK_INTERFACE" = "unknown" ] && net_ok=0
        [ -z "$LOCAL_IP" ]   && net_ok=0
        [ -z "$GATEWAY_MAC" ] && net_ok=0

        if [ "$net_ok" = "0" ]; then
            print_warning "Auto-detection incomplete. You can enter the values manually."
            print_info "To find them yourself, open another Termux session and run:"
            print_info "  ip route          (look for 'default via X.X.X.X dev IFACE')"
            print_info "  ip addr           (look for your Wi-Fi IP under the interface)"
            print_info "  cat /proc/net/arp (look for your gateway IP row, column 4 = MAC)"
            echo ""

            if [ -z "$NETWORK_INTERFACE" ] || [ "$NETWORK_INTERFACE" = "unknown" ]; then
                printf "%s" "Network interface name [e.g. wlan0]: "; read -r _iface </dev/tty
                [ -n "$_iface" ] && NETWORK_INTERFACE="$_iface"
            fi

            if [ -z "$LOCAL_IP" ]; then
                printf "%s" "Your local/Wi-Fi IP [e.g. 192.168.1.5]: "; read -r _lip </dev/tty
                validate_ip "$_lip" && LOCAL_IP="$_lip"
            fi

            if [ -z "$GATEWAY_IP" ]; then
                printf "%s" "Gateway/router IP  [e.g. 192.168.1.1]: "; read -r _gip </dev/tty
                validate_ip "$_gip" && GATEWAY_IP="$_gip"
                if [ -n "$GATEWAY_IP" ]; then
                    print_info "Refreshing ARP for $GATEWAY_IP ..."
                    ping -c 2 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 || true
                    GATEWAY_MAC=$(awk -v gw="$GATEWAY_IP" '$1==gw && $4!="00:00:00:00:00:00" {print $4}' /proc/net/arp 2>/dev/null | head -1)
                fi
            fi

            if [ -z "$GATEWAY_MAC" ]; then
                printf "%s" "Gateway MAC address [e.g. aa:bb:cc:dd:ee:ff]: "; read -r _mac </dev/tty
                [ -n "$_mac" ] && GATEWAY_MAC="$_mac"
            fi

            # Final check
            echo ""
            printf " Interface  : %s\n" "$NETWORK_INTERFACE"
            printf " Local IP   : %s\n" "$LOCAL_IP"
            printf " Gateway MAC: %s\n" "${GATEWAY_MAC:-STILL MISSING}"
            echo ""

            if [ -z "$GATEWAY_MAC" ]; then
                print_error "Gateway MAC is still missing — the tunnel will NOT work without it."
                printf "%s" "Continue anyway? (y/N): "; read -r _cont </dev/tty
                [[ "$_cont" =~ ^[Yy]$ ]] || continue
            fi
        fi
        echo ""

        printf "%s" "Service name (e.g. myclient): "; read -r config_name </dev/tty
        config_name=$(clean_config_name "${config_name:-client}")
        if [ -f "$CONFIG_DIR/${config_name}.yaml" ]; then
            printf "%s" "Config '$config_name' exists. Overwrite? (y/N): "; read -r ow </dev/tty
            [[ "$ow" =~ ^[Yy]$ ]] || continue
        fi

        printf "%s" "Kharej server IP: "; read -r server_ip </dev/tty
        validate_ip "$server_ip" || { print_error "Invalid IP"; sleep 1.5; continue; }

        printf "%s" "Server port [default $DEFAULT_SERVER_PORT]: "; read -r server_port </dev/tty
        server_port="${server_port:-$DEFAULT_SERVER_PORT}"
        validate_port "$server_port" || { print_error "Invalid port"; sleep 1.5; continue; }

        printf "%s" "Secret key (from server): "; read -r secret_key </dev/tty
        [ -z "$secret_key" ] && { print_error "Secret key required"; sleep 1.5; continue; }

        echo -e "\n${CYAN}KCP mode${NC}"
        for k in 0 1 2 3 4; do
            IFS=':' read -r nm dsc <<< "${KCP_MODES[$k]}"
            echo " [$k] $nm - $dsc"
        done
        printf "%s" "Choose [0-4] (default 1): "; read -r mode_choice </dev/tty
        mode_choice="${mode_choice:-1}"
        local mode_name="" kcp_fragment=""
        case $mode_choice in
            0) mode_name="normal" ;;
            1) mode_name="fast" ;;
            2) mode_name="fast2" ;;
            3) mode_name="fast3" ;;
            4) mode_name="manual"; echo ""; kcp_fragment=$(get_manual_kcp_settings) ;;
            *) mode_name="fast" ;;
        esac

        printf "%s" "Connections [1-32, default $DEFAULT_CONNECTIONS]: "; read -r conn </dev/tty
        conn="${conn:-$DEFAULT_CONNECTIONS}"
        [[ "$conn" =~ ^[0-9]+$ ]] && [ "$conn" -ge 1 ] && [ "$conn" -le 32 ] || conn="$DEFAULT_CONNECTIONS"

        printf "%s" "MTU [default $DEFAULT_MTU]: "; read -r mtu </dev/tty
        mtu="${mtu:-$DEFAULT_MTU}"
        [[ "$mtu" =~ ^[0-9]+$ ]] || mtu="$DEFAULT_MTU"

        echo -e "\n${CYAN}Encryption${NC}"
        for k in 1 2 3 4 5 6; do
            IFS=':' read -r nm dsc <<< "${ENCRYPTION_OPTIONS[$k]}"
            echo " [$k] $nm - $dsc"
        done
        printf "%s" "Choose [1-6] (default 1): "; read -r enc_choice </dev/tty
        enc_choice="${enc_choice:-1}"
        local block; IFS=':' read -r block _ <<< "${ENCRYPTION_OPTIONS[$enc_choice]}"
        block="${block:-$DEFAULT_ENCRYPTION}"

        echo -e "\n${CYAN}Traffic type${NC}"
        echo " [1] Port forwarding"
        echo " [2] SOCKS5 proxy"
        printf "%s" "Choose [1-2] (default 1): "; read -r traffic_type </dev/tty
        traffic_type="${traffic_type:-1}"

        local forward_entries=() socks5_entries=() display=""
        if [ "$traffic_type" = "1" ]; then
            printf "%s" "Forward ports, comma separated (e.g. 443,8443): "; read -r fports </dev/tty
            fports=$(clean_port_list "$fports")
            [ -z "$fports" ] && { print_error "No valid ports"; sleep 1.5; continue; }
            IFS=',' read -ra PORTS <<< "$fports"
            for p in "${PORTS[@]}"; do
                printf "%s" "Port $p protocol [1=tcp 2=udp 3=both] (default 1): "; read -r pc </dev/tty
                pc="${pc:-1}"
                case $pc in
                    2) forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"udp\"")
                       display+=" $p(UDP)"; iptables_try "$p" "udp" ;;
                    3) forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                       forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"udp\"")
                       display+=" $p(TCP+UDP)"; iptables_try "$p" "both" ;;
                    *) forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                       display+=" $p(TCP)"; iptables_try "$p" "tcp" ;;
                esac
            done
        else
            printf "%s" "SOCKS5 port [default $DEFAULT_SOCKS5_PORT]: "; read -r sport </dev/tty
            sport="${sport:-$DEFAULT_SOCKS5_PORT}"
            validate_port "$sport" || { print_error "Invalid port"; sleep 1.5; continue; }

            # LAN vs local-only
            echo ""
            echo " [1] 0.0.0.0:$sport  - reachable from ALL devices on local network (hotspot/LAN)"
            echo " [2] 127.0.0.1:$sport - only this phone"
            printf "%s" "Listen address [1-2] (default 1): "; read -r socks_bind_choice </dev/tty
            local socks_bind
            [ "${socks_bind_choice:-1}" = "2" ] && socks_bind="127.0.0.1" || socks_bind="0.0.0.0"
            print_info "SOCKS5 will listen on ${socks_bind}:${sport}"
            if [ "$socks_bind" = "0.0.0.0" ]; then
                print_warning "Listening on 0.0.0.0 exposes the proxy to your whole network."
                print_warning "Consider setting a username/password to prevent unauthorized use."
            fi

            iptables_try "$sport" "tcp"
            printf "%s" "SOCKS5 username (blank = no auth): "; read -r su_ </dev/tty
            if [ -n "$su_" ]; then
                printf "%s" "SOCKS5 password: "; read -r sp_ </dev/tty
                socks5_entries+=("  - listen: \"${socks_bind}:$sport\"\n    username: \"$su_\"\n    password: \"$sp_\"")
            else
                socks5_entries+=("  - listen: \"${socks_bind}:$sport\"")
            fi
        fi

        mkdir -p "$CONFIG_DIR"
        {
            echo "# Erisrtg Packet Tunnel (Termux) - Client Configuration"
            echo "role: \"client\""
            echo "log:"
            echo "  level: \"info\""
            if [ ${#forward_entries[@]} -gt 0 ]; then
                echo "forward:"
                for e in "${forward_entries[@]}"; do echo -e "$e"; done
            fi
            if [ ${#socks5_entries[@]} -gt 0 ]; then
                echo "socks5:"
                for e in "${socks5_entries[@]}"; do echo -e "$e"; done
            fi
            echo "network:"
            echo "  interface: \"$NETWORK_INTERFACE\""
            echo "  ipv4:"
            echo "    addr: \"${LOCAL_IP:-0.0.0.0}:0\""
            echo "    router_mac: \"${GATEWAY_MAC}\""
            echo "  tcp:"
            echo "    local_flag: [\"PA\"]"
            echo "    remote_flag: [\"PA\"]"
            echo "server:"
            echo "  addr: \"$server_ip:$server_port\""
            echo "transport:"
            echo "  protocol: \"kcp\""
            echo "  conn: $conn"
            echo "  kcp:"
            echo "    key: \"$secret_key\""
            if [ "$mode_name" = "manual" ] && [ -n "$kcp_fragment" ]; then
                echo "    block: \"$block\""
                echo "    mtu: $mtu"
                while IFS= read -r line; do
                    [[ -n "$line" ]] && ! echo "$line" | grep -q "^mode:" && echo "    $line"
                done <<< "$kcp_fragment"
                echo "    mode: \"manual\""
            else
                echo "    mode: \"$mode_name\""
                echo "    block: \"$block\""
                echo "    mtu: $mtu"
            fi
        } > "$CONFIG_DIR/${config_name}.yaml"

        print_success "Saved: $CONFIG_DIR/${config_name}.yaml"
        create_termux_service "$config_name"

        echo ""
        print_info "Config created. Use menu option 3 to start/manage the service."
        pause
        return 0
    done
}

# ---------------- termux-services integration ----------------
create_termux_service() {
    local name="$1"
    local svc_dir="$SERVICE_BASE/paqet-${name}"
    local cfg="$CONFIG_DIR/${name}.yaml"
    mkdir -p "$svc_dir/log"

    cat > "$svc_dir/run" << EOF
#!$PREFIX/bin/sh
exec 2>&1
exec su -c "$BIN_PATH run -c $cfg"
EOF
    chmod 700 "$svc_dir/run"

    cat > "$svc_dir/log/run" << EOF
#!$PREFIX/bin/sh
exec svlogd -tt "$LOG_DIR/${name}"
EOF
    chmod 700 "$svc_dir/log/run"
    mkdir -p "$LOG_DIR/${name}"

    print_success "termux-services unit created: paqet-${name}"
    print_info "Run 'sv-enable paqet-${name}' once, then use menu option 3 to start it."
}

ensure_supervisor_running() {
    if ! pgrep -f "runsvdir.*$SERVICE_BASE" >/dev/null 2>&1; then
        print_warning "Service supervisor (runsvdir) doesn't look like it's running."
        print_info "Starting it now: runsvdir $SERVICE_BASE &"
        runsvdir "$SERVICE_BASE" >/dev/null 2>&1 &
        disown
        sleep 1
    fi
}

list_services() {
    local found=0
    for d in "$SERVICE_BASE"/paqet-*; do
        [ -d "$d" ] || continue
        found=1
        local name; name=$(basename "$d")
        local status; status=$(sv status "$name" 2>/dev/null)
        echo " - $name : ${status:-unknown}"
    done
    [ "$found" = "0" ] && print_warning "No tunnels configured yet (use menu option 2)."
}

manage_services() {
    while true; do
        clear; show_banner
        echo -e "${GREEN}Manage Tunnels${NC}\n"
        ensure_supervisor_running
        list_services
        echo ""
        echo " 1. Enable+Start a tunnel"
        echo " 2. Stop a tunnel"
        echo " 3. Restart a tunnel"
        echo " 4. View recent log"
        echo " 5. View config"
        echo " 6. Edit config (nano)"
        echo " 7. Delete tunnel"
        echo " 0. Back"
        echo ""
        printf "%s" "Choice: "; read -r c </dev/tty
        [ "$c" = "0" ] && return

        if [ "$c" = "1" ] || [ "$c" = "2" ] || [ "$c" = "3" ] || [ "$c" = "4" ] || [ "$c" = "5" ] || [ "$c" = "6" ] || [ "$c" = "7" ]; then
            printf "%s" "Service name (without 'paqet-' prefix): "; read -r n </dev/tty
            local svc="paqet-$n"
            local svc_dir="$SERVICE_BASE/$svc"
            local cfg="$CONFIG_DIR/$n.yaml"
            if [ ! -d "$svc_dir" ]; then print_error "Not found: $svc"; pause; continue; fi

            case "$c" in
                1) sv-enable "$svc" >/dev/null 2>&1; sv up "$svc"; print_success "Started $svc" ;;
                2) sv down "$svc"; print_success "Stopped $svc" ;;
                3) sv restart "$svc"; print_success "Restarted $svc" ;;
                4) tail -n 40 "$LOG_DIR/$n/current" 2>/dev/null || print_warning "No log yet" ;;
                5) [ -f "$cfg" ] && cat "$cfg" || print_error "Config missing" ;;
                6) command -v nano >/dev/null 2>&1 && nano "$cfg" || vi "$cfg"
                   printf "%s" "Restart tunnel to apply changes? (y/N): "; read -r r </dev/tty
                   [[ "$r" =~ ^[Yy]$ ]] && sv restart "$svc" ;;
                7) printf "%s" "Delete $svc and its config? (y/N): "; read -r r </dev/tty
                   if [[ "$r" =~ ^[Yy]$ ]]; then
                       sv down "$svc" >/dev/null 2>&1 || true
                       rm -f "$PREFIX/var/service/$svc" 2>/dev/null || true
                       rm -rf "$svc_dir" "$cfg" "$LOG_DIR/$n"
                       print_success "Deleted"
                   fi ;;
            esac
            pause
        else
            print_error "Invalid choice"; sleep 1
        fi
    done
}

# ---------------- Diagnostics ----------------
test_connection() {
    clear; show_banner
    echo -e "${GREEN}Diagnostics${NC}\n"
    printf "%s" "Kharej server IP to test: "; read -r ip </dev/tty
    validate_ip "$ip" || { print_error "Invalid IP"; pause; return; }

    print_step "ICMP ping..."
    ping -c 4 -W 2 "$ip" 2>&1 | tail -n 3

    print_step "TCP port reachability (443,80,22)..."
    for p in 443 80 22; do
        if timeout 3 bash -c "</dev/tcp/$ip/$p" 2>/dev/null; then
            echo " port $p: OPEN"
        else
            echo " port $p: closed/filtered"
        fi
    done

    print_step "DNS sanity check..."
    if command -v dig >/dev/null 2>&1; then
        dig +short github.com
    else
        nslookup github.com 2>/dev/null | tail -n 4
    fi
    pause
}

background_help() {
    clear; show_banner
    echo -e "${GREEN}Keeping the tunnel alive in the background${NC}\n"
    cat << 'EOF'
Android will suspend or kill Termux in the background unless you:

1) Take a wake lock so the CPU doesn't sleep while Termux is open:
     termux-wake-lock
   (undo with: termux-wake-unlock)
   Requires the 'termux-api' package and the Termux:API companion app
   installed from F-Droid for the lock to actually hold.

2) Exclude Termux from battery optimization:
   Android Settings -> Apps -> Termux -> Battery -> Unrestricted

3) Make the service supervisor start automatically:
   - It auto-starts the first time you open a Termux session, via
     termux-services' profile.d hook.
   - For it to survive a phone reboot without you opening Termux
     manually, install the separate "Termux:Boot" app (F-Droid) and
     place a script in ~/.termux/boot/ that runs:
       runsvdir ~/.termux/service &

4) Remember this is still fundamentally a foreground terminal app on
   Android, not a real background service like a VPN app gets via
   Android's VpnService API. Expect occasional drops when Android is
   aggressive about killing background processes (varies a lot by
   phone vendor: MIUI/ColorOS/etc. are notably aggressive).
EOF
    pause
}

# ---------------- Main menu ----------------
main_menu() {
    while true; do
        clear; show_banner
        echo -e "${CYAN}Root: $([ "$ROOT_OK" = "1" ] && echo "OK" || echo "NOT CONFIRMED")${NC}"
        echo -e "${CYAN}paqet binary: $([ -x "$BIN_PATH" ] && echo "built ($BIN_PATH)" || echo "not built yet")${NC}\n"
        echo " 1. Install dependencies"
        echo " 2. Build/update paqet from source"
        echo " 3. Configure a new client tunnel"
        echo " 4. Manage tunnels (start/stop/logs/edit/delete)"
        echo " 5. Test connection to a server"
        echo " 6. Background/battery setup help"
        echo " 0. Exit"
        echo ""
        printf "%s" "Choice: "; read -r choice </dev/tty
        case "$choice" in
            1) install_dependencies ;;
            2) build_paqet ;;
            3) configure_client ;;
            4) manage_services ;;
            5) test_connection ;;
            6) background_help ;;
            0) exit 0 ;;
            *) print_error "Invalid choice"; sleep 1 ;;
        esac
    done
}

# ---------------- Entry point ----------------
check_termux
check_root
main_menu
