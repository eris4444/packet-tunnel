#!/usr/bin/env python3
"""
Erisrtg Packet Tunnel - Web Panel
Port: 7777 | github.com/eris4444/packet-tunnel
All files flat in one directory — no subdirectories.
"""

import os, json, subprocess, re, secrets, hashlib, glob
from functools import wraps
from flask import (Flask, render_template, request, jsonify,
                   session, redirect, url_for, flash)

# Flask با template_folder='.' یعنی همون دایرکتوری خود app.py
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__, template_folder=BASE_DIR)
app.secret_key = os.environ.get('PANEL_SECRET', secrets.token_hex(32))

# ── Paths ────────────────────────────────────────────────────
CONFIG_DIR   = '/etc/paqet'
SERVICE_DIR  = '/etc/systemd/system'
BIN_PATH     = '/usr/local/bin/paqet'
PANEL_CONFIG = '/etc/paqet-panel/config.json'

os.makedirs('/etc/paqet-panel', exist_ok=True)
os.makedirs(CONFIG_DIR, exist_ok=True)

# ── Panel config ─────────────────────────────────────────────
def load_panel_config():
    default = {
        'username': 'admin',
        'password_hash': hashlib.sha256('admin123'.encode()).hexdigest(),
        'theme': 'dark',
        'language': 'en'
    }
    try:
        with open(PANEL_CONFIG) as f:
            data = json.load(f)
            for k, v in default.items():
                data.setdefault(k, v)
            return data
    except Exception:
        save_panel_config(default)
        return default

def save_panel_config(cfg):
    with open(PANEL_CONFIG, 'w') as f:
        json.dump(cfg, f, indent=2)

# ── Auth ──────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

def check_password(plain, hashed):
    return hashlib.sha256(plain.encode()).hexdigest() == hashed

# ── System helpers ────────────────────────────────────────────
def run_cmd(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True,
                           text=True, timeout=timeout)
        return r.stdout.strip(), r.stderr.strip(), r.returncode
    except subprocess.TimeoutExpired:
        return '', 'Timeout', 1
    except Exception as e:
        return '', str(e), 1

def get_services():
    out, _, _ = run_cmd(
        "systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | grep '^paqet-'"
    )
    services = []
    for line in out.splitlines():
        parts = line.split()
        if not parts: continue
        svc_file = parts[0]
        svc_name = svc_file.replace('.service', '')
        cfg_name = svc_name.replace('paqet-', '')
        status, _, _ = run_cmd(f"systemctl is-active {svc_file} 2>/dev/null")
        enabled, _, _ = run_cmd(f"systemctl is-enabled {svc_file} 2>/dev/null")
        cfg_path = f"{CONFIG_DIR}/{cfg_name}.yaml"
        role = mode = 'unknown'; mtu = conn = port = '-'
        if os.path.exists(cfg_path):
            try:
                import yaml
                with open(cfg_path) as f:
                    raw = yaml.safe_load(f)
                if raw:
                    role = raw.get('role', 'unknown')
                    kcp  = raw.get('transport', {}).get('kcp', {})
                    mode = kcp.get('mode', 'fast')
                    mtu  = str(kcp.get('mtu', '-'))
                    conn = str(raw.get('transport', {}).get('conn', '-'))
                    listen = raw.get('listen', {})
                    if listen: port = listen.get('addr', '-').split(':')[-1]
                    srv = raw.get('server', {})
                    if srv: port = srv.get('addr', '-').split(':')[-1]
            except Exception: pass
        cron_out, _, _ = run_cmd(f"crontab -l 2>/dev/null | grep 'systemctl restart {svc_name}'")
        services.append({
            'name': svc_name, 'cfg_name': cfg_name,
            'status': status.strip() or 'unknown',
            'enabled': enabled.strip(),
            'role': role, 'mode': mode, 'mtu': mtu,
            'conn': conn, 'port': port,
            'has_cron': bool(cron_out.strip())
        })
    return services

def get_service_logs(svc_name, lines=50):
    out, _, _ = run_cmd(f"journalctl -u {svc_name} -n {lines} --no-pager 2>/dev/null")
    return out

def _is_valid_ip(s):
    """فقط یه IPv4 خالص قبول میکنه — HTML یا هر چیز دیگه‌ای رد میشه."""
    import re as _re
    s = s.strip()
    return bool(_re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', s)) and \
           all(0 <= int(o) <= 255 for o in s.split('.'))

def get_public_ip():
    """
    سرویس‌های IP-echo رو یکی‌یکی امتحان می‌کنه.
    اگر جواب HTML بود یا IP معتبر نبود، رد می‌کنه.
    آخرین fallback: IP محلی از hostname.
    """
    # سرویس‌هایی که روی ایران کار می‌کنن اول میان
    services = [
        "ip.sb",
        "api.ipify.org",
        "ipinfo.io/ip",
        "2ip.ru",
        "checkip.amazonaws.com",
        "ifconfig.me",
        "icanhazip.com",
        "ident.me",
        "ipecho.net/plain",
        "myexternalip.com/raw",
    ]
    for svc in services:
        out, _, rc = run_cmd(
            f"curl -4 -sS --max-time 4 --connect-timeout 3 "
            f"--user-agent 'curl/7.68' "
            f"'https://{svc}' 2>/dev/null || "
            f"curl -4 -sS --max-time 4 --connect-timeout 3 "
            f"'http://{svc}' 2>/dev/null"
        )
        candidate = out.strip().split('\n')[0].strip()
        if _is_valid_ip(candidate):
            return candidate
    # fallback: آدرس محلی رابط پیش‌فرض
    local, _, _ = run_cmd("ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1")
    if _is_valid_ip(local.strip()):
        return local.strip()
    local2, _, _ = run_cmd("hostname -I | awk '{print $1}'")
    return local2.strip() or 'N/A'

def get_system_stats():
    cpu, _, _    = run_cmd("top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d'%' -f1 | cut -d',' -f1")
    mem, _, _    = run_cmd("free -m | awk 'NR==2{printf \"%s/%s\", $3, $2}'")
    uptime, _, _ = run_cmd("uptime -p 2>/dev/null || uptime")
    disk, _, _   = run_cmd("df -h / | awk 'NR==2{print $5}'")
    load, _, _   = run_cmd("cat /proc/loadavg | awk '{print $1, $2, $3}'")
    kernel, _, _ = run_cmd("uname -r")
    os_name, _, _= run_cmd("cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'")
    pv, _, _     = run_cmd(f"{BIN_PATH} version 2>/dev/null | head -1")
    public_ip    = get_public_ip()
    return {
        'cpu': (cpu.strip() or '0').split()[0],
        'mem': mem.strip() or '0/0',
        'uptime': uptime.strip(),
        'disk': disk.strip() or '0%',
        'load': load.strip(),
        'public_ip': public_ip,
        'kernel': kernel.strip(),
        'os': os_name.strip(),
        'paqet_version': pv.strip() or 'Not installed',
        'paqet_installed': os.path.exists(BIN_PATH)
    }

def get_config_raw(cfg_name):
    path = f"{CONFIG_DIR}/{cfg_name}.yaml"
    if not os.path.exists(path): return ''
    with open(path) as f: return f.read()

def generate_key():
    import string, random
    chars = string.ascii_letters + string.digits
    return ''.join(random.choices(chars, k=32))

def get_network_info():
    iface, _, _  = run_cmd("ip route | grep default | awk '{print $5}' | head -1")
    local_ip, _, _= run_cmd(f"ip -4 addr show {iface.strip()} 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){{3}}' | head -1")
    gw, _, _     = run_cmd("ip route | grep default | awk '{print $3}' | head -1")
    gw_mac = ''
    if gw.strip():
        run_cmd(f"ping -c 1 -W 1 {gw.strip()} >/dev/null 2>&1")
        gw_mac, _, _ = run_cmd(f"ip neigh show {gw.strip()} 2>/dev/null | grep -oE '([0-9a-fA-F]{{2}}:){{5}}[0-9a-fA-F]{{2}}' | head -1")
    return {
        'interface':   iface.strip() or 'eth0',
        'local_ip':    local_ip.strip() or '127.0.0.1',
        'gateway':     gw.strip(),
        'gateway_mac': gw_mac.strip() or '00:00:00:00:00:00'
    }

def build_service_file(cfg_name):
    return f"""[Unit]
Description=Erisrtg Packet Tunnel ({cfg_name})
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart={BIN_PATH} run -c {CONFIG_DIR}/{cfg_name}.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535
Environment="GOMAXPROCS=0"

[Install]
WantedBy=multi-user.target
"""

# ═══════════════════════════════════════════════════
#  ROUTES
# ═══════════════════════════════════════════════════

@app.route('/')
def index():
    return redirect(url_for('login') if not session.get('logged_in') else url_for('dashboard'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    cfg = load_panel_config()
    if request.method == 'POST':
        if (request.form.get('username') == cfg['username'] and
                check_password(request.form.get('password', ''), cfg['password_hash'])):
            session.update({'logged_in': True, 'username': cfg['username'],
                            'theme': cfg.get('theme', 'dark'), 'lang': cfg.get('language', 'en')})
            return redirect(url_for('dashboard'))
        flash('invalid_credentials')
    return render_template('login.html', cfg=cfg)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard():
    return render_template('dashboard.html', stats=get_system_stats(),
                           services=get_services(), cfg=load_panel_config(), active='dashboard')

@app.route('/services')
@login_required
def services():
    return render_template('services.html', services=get_services(),
                           cfg=load_panel_config(), active='services')

@app.route('/services/<cfg_name>')
@login_required
def service_detail(cfg_name):
    svc_list = get_services()
    svc = next((s for s in svc_list if s['cfg_name'] == cfg_name), None)
    if not svc: return redirect(url_for('services'))
    return render_template('service_detail.html',
                           svc=svc,
                           logs=get_service_logs(svc['name']),
                           config_raw=get_config_raw(cfg_name),
                           cfg=load_panel_config(), active='services')

@app.route('/add-server', methods=['GET', 'POST'])
@login_required
def add_server():
    cfg = load_panel_config()
    net = get_network_info()
    if request.method == 'GET':
        return render_template('add_server.html', generated_key=generate_key(),
                               net=net, cfg=cfg, active='add_server')

    d = request.form
    cfg_name = re.sub(r'[^a-zA-Z0-9_-]', '', d.get('name', 'server')) or 'server'
    port     = d.get('port', '8888')
    secret   = d.get('secret', generate_key())
    kcp_mode = d.get('kcp_mode', 'fast')
    conn     = d.get('conn', '4')
    mtu      = d.get('mtu', '1150')
    block    = d.get('encryption', 'aes-128-gcm')
    pcap_buf = d.get('pcap_sockbuf', '')
    tcpbuf   = d.get('tcpbuf', '')
    udpbuf   = d.get('udpbuf', '')

    yaml_txt = f'# Erisrtg Packet Tunnel - Server\nrole: "server"\nlog:\n  level: "info"\nlisten:\n  addr: ":{port}"\nnetwork:\n  interface: "{net["interface"]}"\n  ipv4:\n    addr: "{net["local_ip"]}:{port}"\n    router_mac: "{net["gateway_mac"]}"\n  tcp:\n    local_flag: ["PA"]\n'
    if pcap_buf: yaml_txt += f'  pcap:\n    sockbuf: {pcap_buf}\n'
    yaml_txt += f'transport:\n  protocol: "kcp"\n'
    if conn:   yaml_txt += f'  conn: {conn}\n'
    if tcpbuf: yaml_txt += f'  tcpbuf: {tcpbuf}\n'
    if udpbuf: yaml_txt += f'  udpbuf: {udpbuf}\n'
    yaml_txt += f'  kcp:\n    key: "{secret}"\n    mode: "{kcp_mode}"\n    block: "{block}"\n    mtu: {mtu}\n'

    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(f"{CONFIG_DIR}/{cfg_name}.yaml", 'w') as f: f.write(yaml_txt)

    svc_name = f"paqet-{cfg_name}"
    with open(f"{SERVICE_DIR}/{svc_name}.service", 'w') as f:
        f.write(build_service_file(cfg_name))
    run_cmd("systemctl daemon-reload")
    run_cmd(f"systemctl enable {svc_name} --now")
    return redirect(url_for('service_detail', cfg_name=cfg_name))

@app.route('/add-client', methods=['GET', 'POST'])
@login_required
def add_client():
    cfg = load_panel_config()
    net = get_network_info()
    if request.method == 'GET':
        return render_template('add_client.html', net=net, cfg=cfg, active='add_client')

    d = request.form
    cfg_name     = re.sub(r'[^a-zA-Z0-9_-]', '', d.get('name', 'client')) or 'client'
    server_ip    = d.get('server_ip', '')
    server_port  = d.get('server_port', '8888')
    secret       = d.get('secret', '')
    kcp_mode     = d.get('kcp_mode', 'fast')
    conn         = d.get('conn', '4')
    mtu          = d.get('mtu', '1150')
    block        = d.get('encryption', 'aes-128-gcm')
    pcap_buf     = d.get('pcap_sockbuf', '')
    tcpbuf       = d.get('tcpbuf', '')
    udpbuf       = d.get('udpbuf', '')
    traffic_type = d.get('traffic_type', '1')
    fwd_ports    = d.get('forward_ports', '9090')
    proto        = d.get('protocol', 'tcp')
    socks_port   = d.get('socks_port', '1080')
    socks_user   = d.get('socks_user', '')
    socks_pass   = d.get('socks_pass', '')

    yaml_txt = f'# Erisrtg Packet Tunnel - Client\nrole: "client"\nlog:\n  level: "info"\n'
    if traffic_type == '1':
        yaml_txt += 'forward:\n'
        for p in fwd_ports.split(','):
            p = p.strip()
            if p: yaml_txt += f'  - listen: "0.0.0.0:{p}"\n    target: "127.0.0.1:{p}"\n    protocol: "{proto}"\n'
    else:
        yaml_txt += 'socks5:\n'
        if socks_user and socks_pass:
            yaml_txt += f'  - listen: "127.0.0.1:{socks_port}"\n    username: "{socks_user}"\n    password: "{socks_pass}"\n'
        else:
            yaml_txt += f'  - listen: "127.0.0.1:{socks_port}"\n'

    yaml_txt += f'network:\n  interface: "{net["interface"]}"\n  ipv4:\n    addr: "{net["local_ip"]}:0"\n    router_mac: "{net["gateway_mac"]}"\n  tcp:\n    local_flag: ["PA"]\n    remote_flag: ["PA"]\n'
    if pcap_buf: yaml_txt += f'  pcap:\n    sockbuf: {pcap_buf}\n'
    yaml_txt += f'server:\n  addr: "{server_ip}:{server_port}"\ntransport:\n  protocol: "kcp"\n'
    if conn:   yaml_txt += f'  conn: {conn}\n'
    if tcpbuf: yaml_txt += f'  tcpbuf: {tcpbuf}\n'
    if udpbuf: yaml_txt += f'  udpbuf: {udpbuf}\n'
    yaml_txt += f'  kcp:\n    key: "{secret}"\n    mode: "{kcp_mode}"\n    block: "{block}"\n    mtu: {mtu}\n'

    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(f"{CONFIG_DIR}/{cfg_name}.yaml", 'w') as f: f.write(yaml_txt)

    svc_name = f"paqet-{cfg_name}"
    with open(f"{SERVICE_DIR}/{svc_name}.service", 'w') as f:
        f.write(build_service_file(cfg_name))
    run_cmd("systemctl daemon-reload")
    run_cmd(f"systemctl enable {svc_name} --now")
    return redirect(url_for('service_detail', cfg_name=cfg_name))

@app.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    cfg = load_panel_config()
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'change_password':
            cur = request.form.get('current_password', '')
            new = request.form.get('new_password', '')
            cfm = request.form.get('confirm_password', '')
            if not check_password(cur, cfg['password_hash']): flash('wrong_password')
            elif new != cfm: flash('password_mismatch')
            elif len(new) < 6: flash('password_short')
            else:
                cfg['password_hash'] = hashlib.sha256(new.encode()).hexdigest()
                save_panel_config(cfg); flash('password_changed')
        elif action == 'change_username':
            u = request.form.get('new_username', '').strip()
            if len(u) < 3: flash('username_short')
            else:
                cfg['username'] = u; session['username'] = u
                save_panel_config(cfg); flash('username_changed')
        elif action == 'change_theme':
            cfg['theme'] = request.form.get('theme', 'dark')
            session['theme'] = cfg['theme']
            save_panel_config(cfg); flash('theme_changed')
        elif action == 'change_language':
            cfg['language'] = request.form.get('language', 'en')
            session['lang'] = cfg['language']
            save_panel_config(cfg); flash('lang_changed')
        return redirect(url_for('settings'))
    return render_template('settings.html', cfg=cfg, active='settings')

# ── API ───────────────────────────────────────────────────────
@app.route('/api/service/<svc_name>/<action>', methods=['POST'])
@login_required
def api_service_action(svc_name, action):
    if not re.match(r'^paqet-[a-zA-Z0-9_-]+$', svc_name):
        return jsonify({'ok': False, 'error': 'Invalid name'})
    if action not in ('start','stop','restart','enable','disable'):
        return jsonify({'ok': False, 'error': 'Invalid action'})
    _, err, code = run_cmd(f"systemctl {action} {svc_name}.service 2>&1")
    status, _, _ = run_cmd(f"systemctl is-active {svc_name}.service")
    return jsonify({'ok': code == 0, 'status': status.strip(), 'error': err})

@app.route('/api/service/<cfg_name>/delete', methods=['POST'])
@login_required
def api_service_delete(cfg_name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', cfg_name):
        return jsonify({'ok': False, 'error': 'Invalid name'})
    svc = f"paqet-{cfg_name}"
    run_cmd(f"systemctl stop {svc}.service")
    run_cmd(f"systemctl disable {svc}.service")
    run_cmd(f"rm -f {SERVICE_DIR}/{svc}.service")
    run_cmd(f"rm -f {CONFIG_DIR}/{cfg_name}.yaml")
    run_cmd("systemctl daemon-reload")
    run_cmd(f"crontab -l 2>/dev/null | grep -v 'systemctl restart {svc}' | crontab -")
    return jsonify({'ok': True})

@app.route('/api/service/<cfg_name>/config', methods=['POST'])
@login_required
def api_save_config(cfg_name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', cfg_name):
        return jsonify({'ok': False, 'error': 'Invalid name'})
    content = request.json.get('content', '')
    with open(f"{CONFIG_DIR}/{cfg_name}.yaml", 'w') as f: f.write(content)
    return jsonify({'ok': True})

@app.route('/api/service/<svc_name>/logs')
@login_required
def api_logs(svc_name):
    if not re.match(r'^paqet-[a-zA-Z0-9_-]+$', svc_name):
        return jsonify({'ok': False, 'error': 'Invalid name'})
    return jsonify({'ok': True, 'logs': get_service_logs(svc_name, 100)})

@app.route('/api/cron/<svc_name>/<interval>', methods=['POST'])
@login_required
def api_cron(svc_name, interval):
    if not re.match(r'^paqet-[a-zA-Z0-9_-]+$', svc_name):
        return jsonify({'ok': False, 'error': 'Invalid name'})
    intervals = {
        '1min':'*/1 * * * *','5min':'*/5 * * * *','15min':'*/15 * * * *',
        '30min':'*/30 * * * *','1hour':'0 */1 * * *','12hour':'0 */12 * * *',
        '1day':'0 0 * * *'
    }
    cmd = f"systemctl restart {svc_name}"
    run_cmd(f"crontab -l 2>/dev/null | grep -v '{cmd}' | crontab -")
    if interval != 'remove':
        iv = intervals.get(interval)
        if not iv: return jsonify({'ok': False, 'error': 'Bad interval'})
        run_cmd(f"(crontab -l 2>/dev/null; echo '{iv} {cmd}') | crontab -")
    return jsonify({'ok': True})

@app.route('/api/stats')
@login_required
def api_stats():
    return jsonify(get_system_stats())

@app.route('/api/generate-key')
@login_required
def api_generate_key():
    return jsonify({'key': generate_key()})

@app.route('/api/install-paqet', methods=['POST'])
@login_required
def api_install_paqet():
    arch_out, _, _ = run_cmd("uname -m")
    arch = arch_out.strip()
    tag = 'amd64' if arch in ('x86_64','amd64') else 'arm64' if arch in ('aarch64','arm64') else None
    if not tag: return jsonify({'ok': False, 'error': f'Unsupported arch: {arch}'})
    ver, _, _ = run_cmd("curl -s https://api.github.com/repos/hanselime/paqet/releases/latest | grep '\"tag_name\"' | cut -d'\"' -f4")
    ver = ver.strip() or 'v1.0.0-alpha.16'
    url = f"https://github.com/hanselime/paqet/releases/download/{ver}/paqet-linux-{tag}-{ver}.tar.gz"
    _, _, rc = run_cmd(
        f"mkdir -p /root/paqet && curl -fsSL '{url}' -o /root/paqet/paqet.tar.gz && "
        f"cd /root/paqet && tar xzf paqet.tar.gz && "
        f"cp -f $(find /root/paqet -name 'paqet' -type f | head -1) /usr/local/bin/paqet && "
        f"chmod +x /usr/local/bin/paqet", timeout=120)
    return jsonify({'ok': rc == 0, 'version': ver})

@app.route('/api/optimize/<action>', methods=['POST'])
@login_required
def api_optimize(action):
    if action == 'bbr':
        _, _, rc = run_cmd("bash <(curl -fsSL https://raw.githubusercontent.com/teddysun/across/master/bbr.sh)", timeout=120)
    elif action == 'sysctl':
        with open('/etc/sysctl.d/99-paqet-tunnel.conf', 'w') as f:
            f.write("net.core.rmem_max=134217728\nnet.core.wmem_max=134217728\n"
                    "net.ipv4.tcp_rmem=4096 87380 67108864\nnet.ipv4.tcp_wmem=4096 65536 67108864\n"
                    "net.core.netdev_max_backlog=250000\nnet.ipv4.tcp_mtu_probing=1\n")
        _, _, rc = run_cmd("sysctl -p /etc/sysctl.d/99-paqet-tunnel.conf")
    else:
        return jsonify({'ok': False, 'error': 'Unknown action'})
    return jsonify({'ok': rc == 0})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=7777, debug=False)
