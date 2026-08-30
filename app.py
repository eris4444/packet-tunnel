#!/usr/bin/env python3
"""
Erisrtg Packet Tunnel - Web Panel
Port: 7777 | github.com/eris4444/packet-tunnel
All files flat in one directory — no subdirectories.
"""

import os, json, subprocess, re, secrets, hashlib, glob, ssl
import hmac, time, socket, threading, uuid, sqlite3
import urllib.request, urllib.error, urllib.parse
from functools import wraps
import bcrypt
import requests
from flask import (Flask, render_template, request, jsonify,
                   session, redirect, url_for, flash)

# Flask با template_folder='.' یعنی همون دایرکتوری خود app.py
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__, template_folder=BASE_DIR)
app.secret_key = os.environ.get('PANEL_SECRET', secrets.token_hex(32))


class ScriptNamePrefix:
    """Honour the mount point Ex-ui's Packet tab proxies this panel under.

    Ex-ui serves us at /panel/packet/ on its own port. url_for() would still
    emit '/services', which inside the tab resolves against the panel root and
    404s, so SCRIPT_NAME is taken from the proxy's X-Script-Name header and
    Werkzeug prefixes every generated URL with it. Only loopback requests are
    trusted, matching the login bypass, so an outside caller cannot forge the
    prefix and poison generated links.
    """

    def __init__(self, wsgi_app):
        self.wsgi_app = wsgi_app

    def __call__(self, environ, start_response):
        prefix = environ.get('HTTP_X_SCRIPT_NAME', '')
        if prefix and environ.get('REMOTE_ADDR') in ('127.0.0.1', '::1'):
            prefix = '/' + prefix.strip('/')
            environ['SCRIPT_NAME'] = prefix
            path = environ.get('PATH_INFO', '')
            if path.startswith(prefix):
                environ['PATH_INFO'] = path[len(prefix):]
        return self.wsgi_app(environ, start_response)


app.wsgi_app = ScriptNamePrefix(app.wsgi_app)


@app.context_processor
def inject_base_path():
    """Expose the mount point to templates as {{ base }}.

    Templates hardcode absolute paths like /services rather than calling
    url_for(), so SCRIPT_NAME alone would not reach them and every link
    would escape the Ex-ui tab and hit the panel root. Standalone this is
    '' and the paths are unchanged.
    """
    return {'base': request.environ.get('SCRIPT_NAME', '')}

# ── Paths ────────────────────────────────────────────────────
CONFIG_DIR   = '/etc/paqet'
SERVICE_DIR  = '/etc/systemd/system'
BIN_PATH     = '/usr/local/bin/paqet'
PANEL_CONFIG = '/etc/paqet-panel/config.json'
PANEL_VERSION = '3.1.0'
PANEL_PORT   = int(os.environ.get('PANEL_PORT', '7777'))

os.makedirs('/etc/paqet-panel', exist_ok=True)
os.makedirs(CONFIG_DIR, exist_ok=True)

# ── Panel config ─────────────────────────────────────────────
def load_panel_config():
    default = {
        'username': 'admin',
        'password_hash': hashlib.sha256('admin123'.encode()).hexdigest(),
        'theme': 'dark',
        'language': 'en',
        'node_token': '',
        'telegram_token': '',
        'telegram_chat_id': '',
        'telegram_proxy_host': '',
        'telegram_proxy_port': '',
        'telegram_proxy_username': '',
        'telegram_proxy_password': '',
        'panel_port': PANEL_PORT,
        'ssl_enabled': False,
        'ssl_cert_path': '',
        'ssl_key_path': ''
    }
    try:
        with open(PANEL_CONFIG) as f:
            data = json.load(f)
        changed = False
        for k, v in default.items():
            if k not in data:
                data[k] = v
                changed = True
        # every panel is a potential node — make sure it has a token
        if not data.get('node_token'):
            data['node_token'] = secrets.token_hex(24)
            changed = True
        if changed:
            save_panel_config(data)
        return data
    except Exception:
        default['node_token'] = secrets.token_hex(24)
        save_panel_config(default)
        return default

def save_panel_config(cfg):
    with open(PANEL_CONFIG, 'w') as f:
        json.dump(cfg, f, indent=2)
    try:
        os.chmod(PANEL_CONFIG, 0o600)
    except Exception:
        pass

# ── Auth ──────────────────────────────────────────────────────
# Shared secret used by Ex-ui's server-side reverse proxy (internal/web/controller/packet.go)
# to skip this panel's own login when it's already gated behind Ex-ui's session auth. Only
# set when deployed alongside Ex-ui; empty/unset means the bypass is never checked.
PACKET_PROXY_SECRET = os.environ.get('PACKET_PROXY_SECRET', '')

def _is_ex_ui_proxy_request():
    # The secret alone is not enough: PANEL_BIND can put this app back on a public
    # interface, where a request straight from the internet could carry a guessed
    # or leaked header. Only loopback traffic — i.e. what actually came through
    # Ex-ui's same-host proxy — is eligible for the bypass.
    if not PACKET_PROXY_SECRET:
        return False
    if request.remote_addr not in ('127.0.0.1', '::1'):
        return False
    return hmac.compare_digest(request.headers.get('X-Packet-Secret', ''), PACKET_PROXY_SECRET)

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if _is_ex_ui_proxy_request():
            return f(*args, **kwargs)
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

def _is_sha256_hex(h):
    return bool(re.fullmatch(r'[0-9a-fA-F]{64}', h or ''))

def hash_password(plain):
    return bcrypt.hashpw(plain.encode(), bcrypt.gensalt()).decode()

def check_password(plain, hashed):
    """Bcrypt is the current format. A hash left over from an older
    install (raw SHA-256, 64 hex chars) still verifies here — the actual
    migration to bcrypt happens in the login route, which has the config
    object to save the upgraded hash into."""
    if not hashed:
        return False
    if hashed.startswith(('$2a$', '$2b$', '$2y$')):
        try:
            return bcrypt.checkpw(plain.encode(), hashed.encode())
        except ValueError:
            return False
    if _is_sha256_hex(hashed):
        return hashlib.sha256(plain.encode()).hexdigest() == hashed
    return False

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
        pw = request.form.get('password', '')
        if (request.form.get('username') == cfg['username'] and
                check_password(pw, cfg['password_hash'])):
            # one-time upgrade of a legacy SHA-256 hash to bcrypt
            if _is_sha256_hex(cfg['password_hash']):
                cfg['password_hash'] = hash_password(pw)
                save_panel_config(cfg)
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
                           traffic=get_traffic(), nodes=load_nodes(),
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

@app.route('/prefs', methods=['POST'])
def prefs():
    """Public UI preferences (theme / language) — usable from the login page."""
    cfg = load_panel_config()
    theme = request.form.get('theme')
    lang = request.form.get('language')
    if theme in ('dark', 'light'):
        cfg['theme'] = theme
        session['theme'] = theme
    if lang in ('en', 'fa'):
        cfg['language'] = lang
        session['lang'] = lang
    save_panel_config(cfg)
    return {'ok': True}


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
                cfg['password_hash'] = hash_password(new)
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
        elif action == 'change_network':
            try:
                new_port = int(request.form.get('panel_port', '').strip())
                assert 1 <= new_port <= 65535
            except Exception:
                flash('port_invalid')
                return redirect(url_for('settings'))

            ssl_enabled = request.form.get('ssl_enabled') == 'on'
            if ssl_enabled:
                cert_pem = request.form.get('ssl_cert', '').strip()
                key_pem = request.form.get('ssl_key', '').strip()
                have_existing = bool(cfg.get('ssl_cert_path')) and os.path.exists(cfg.get('ssl_cert_path', ''))

                if cert_pem or key_pem:
                    # a new pair was pasted — both fields are required together,
                    # and it replaces whatever was saved before
                    if not (cert_pem and key_pem):
                        flash('ssl_missing')
                        return redirect(url_for('settings'))
                    ssl_dir = os.path.join(os.path.dirname(PANEL_CONFIG), 'ssl')
                    os.makedirs(ssl_dir, exist_ok=True)
                    cert_path = os.path.join(ssl_dir, 'cert.pem')
                    key_path = os.path.join(ssl_dir, 'key.pem')
                    tmp_cert, tmp_key = cert_path + '.tmp', key_path + '.tmp'
                    with open(tmp_cert, 'w') as f: f.write(cert_pem + '\n')
                    with open(tmp_key, 'w') as f: f.write(key_pem + '\n')
                    os.chmod(tmp_key, 0o600)
                    try:
                        # this is the same check gunicorn/openssl will do on
                        # boot — catching a bad or mismatched pair here means
                        # a typo can't take the panel down after restart
                        ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(tmp_cert, tmp_key)
                    except Exception:
                        os.remove(tmp_cert)
                        os.remove(tmp_key)
                        flash('ssl_invalid')
                        return redirect(url_for('settings'))
                    os.replace(tmp_cert, cert_path)
                    os.replace(tmp_key, key_path)
                    os.chmod(key_path, 0o600)
                    cfg['ssl_cert_path'] = cert_path
                    cfg['ssl_key_path'] = key_path
                elif not have_existing:
                    # enabling HTTPS for the first time but nothing was pasted
                    flash('ssl_missing')
                    return redirect(url_for('settings'))
                # else: just re-enabling with the certificate already on disk

                cfg['ssl_enabled'] = True
            else:
                cfg['ssl_enabled'] = False

            cfg['panel_port'] = new_port
            save_panel_config(cfg)

            # best-effort: open the new port the same way install.sh does
            run_cmd(f"iptables -I INPUT -p tcp --dport {new_port} -j ACCEPT 2>/dev/null")
            run_cmd(f"ufw allow {new_port}/tcp 2>/dev/null")
            run_cmd(f"firewall-cmd --permanent --add-port={new_port}/tcp 2>/dev/null && firewall-cmd --reload 2>/dev/null")

            flash('network_changed')
            # restart in the background so this request still gets a response
            def _delayed_restart():
                time.sleep(1)
                run_cmd("systemctl restart paqet-panel 2>/dev/null || true")
            threading.Thread(target=_delayed_restart, daemon=True).start()
        return redirect(url_for('settings'))
    return render_template('settings.html', cfg=cfg, active='settings')


@app.route('/telegram', methods=['GET', 'POST'])
@login_required
def telegram_page():
    cfg = load_panel_config()
    if request.method == 'POST':
        cfg['telegram_token'] = request.form.get('telegram_token', '').strip()
        cfg['telegram_chat_id'] = request.form.get('telegram_chat_id', '').strip()
        cfg['telegram_proxy_host'] = request.form.get('telegram_proxy_host', '').strip()
        cfg['telegram_proxy_port'] = request.form.get('telegram_proxy_port', '').strip()
        cfg['telegram_proxy_username'] = request.form.get('telegram_proxy_username', '').strip()
        cfg['telegram_proxy_password'] = request.form.get('telegram_proxy_password', '').strip()
        save_panel_config(cfg)
        flash('telegram_changed')
        return redirect(url_for('telegram_page'))
    return render_template('telegram.html', cfg=cfg, active='telegram')

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
    data = get_system_stats()
    data['traffic'] = get_traffic()
    return jsonify(data)

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

# ═══════════════════════════════════════════════════
#  NODES — read-only fleet monitoring between panels
#
#  Every panel exposes ONE token-authenticated endpoint,
#  /api/node/summary, that returns stats only. The token
#  never reaches a control route: a leaked token cannot
#  start, stop, delete or reconfigure anything.
# ═══════════════════════════════════════════════════

NODES_FILE    = '/etc/paqet-panel/nodes.json'
TRAFFIC_STATE = '/etc/paqet-panel/traffic.json'
TRAFFIC_DB    = os.path.join(BASE_DIR, 'data', 'traffic.db')

SKIP_IFACE_PREFIX = ('lo', 'veth', 'docker', 'br-', 'virbr', 'dummy')


def get_traffic():
    """Cumulative rx/tx across real interfaces, plus rate since the last sample."""
    total_rx = total_tx = 0
    per_iface = {}
    try:
        with open('/proc/net/dev') as f:
            for line in f.readlines()[2:]:
                name, _, rest = line.partition(':')
                name = name.strip()
                if not name or name.startswith(SKIP_IFACE_PREFIX):
                    continue
                cols = rest.split()
                if len(cols) < 9:
                    continue
                rx, tx = int(cols[0]), int(cols[8])
                per_iface[name] = {'rx': rx, 'tx': tx}
                total_rx += rx
                total_tx += tx
    except Exception:
        pass

    now = time.time()
    rx_rate = tx_rate = 0.0
    prev = None
    try:
        with open(TRAFFIC_STATE) as f:
            prev = json.load(f)
    except Exception:
        prev = None

    # Only trust a sample that is at least 2s old — several callers hit this
    # (browser polling and remote hubs), and a sub-second delta is pure noise.
    dt = (now - prev['t']) if prev else 0
    if prev and 2 <= dt < 3600:
        rx_rate = max(0.0, (total_rx - prev['rx']) / dt)
        tx_rate = max(0.0, (total_tx - prev['tx']) / dt)

    if not prev or dt >= 2:
        try:
            with open(TRAFFIC_STATE, 'w') as f:
                json.dump({'t': now, 'rx': total_rx, 'tx': total_tx}, f)
        except Exception:
            pass

    return {
        'rx_bytes': total_rx, 'tx_bytes': total_tx,
        'rx_rate': round(rx_rate, 1), 'tx_rate': round(tx_rate, 1),
        'interfaces': per_iface,
    }


def require_node_token(f):
    """Bearer-token auth for the read-only node endpoint."""
    @wraps(f)
    def decorated(*args, **kwargs):
        token = load_panel_config().get('node_token', '')
        auth = request.headers.get('Authorization', '')
        given = auth[7:].strip() if auth[:7].lower() == 'bearer ' else ''
        if not token or not given or not hmac.compare_digest(given, token):
            return jsonify({'ok': False, 'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return decorated


# ── Node registry (this panel acting as the hub) ──────────────
def load_nodes():
    try:
        with open(NODES_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def save_nodes(nodes):
    with open(NODES_FILE, 'w') as f:
        json.dump(nodes, f, indent=2)
    try:
        os.chmod(NODES_FILE, 0o600)
    except Exception:
        pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A node must answer directly; never follow it somewhere else."""
    def redirect_request(self, *a, **kw):
        return None


def fetch_node(node, timeout=6):
    """Ask one node for its summary. Never raises."""
    url = node.get('url', '').rstrip('/') + '/api/node/summary'
    req = urllib.request.Request(url, headers={
        'Authorization': 'Bearer ' + node.get('token', ''),
        'User-Agent': 'erisrtg-panel-hub',
    })
    started = time.time()
    try:
        opener = urllib.request.build_opener(_NoRedirect)
        with opener.open(req, timeout=timeout) as r:
            body = r.read(512 * 1024)
        data = json.loads(body.decode('utf-8', 'replace'))
        data['ok'] = True
        data['latency_ms'] = int((time.time() - started) * 1000)
        return data
    except urllib.error.HTTPError as e:
        msg = 'Bad token' if e.code == 401 else 'HTTP %s' % e.code
        return {'ok': False, 'error': msg}
    except urllib.error.URLError as e:
        return {'ok': False, 'error': 'Unreachable (%s)' % (getattr(e, 'reason', e),)}
    except Exception as e:
        return {'ok': False, 'error': type(e).__name__}


def poll_nodes(nodes, timeout=6):
    """Fetch every node in parallel so one dead box cannot stall the page."""
    results = [None] * len(nodes)

    def work(i, n):
        r = fetch_node(n, timeout=timeout)
        r['id'] = n.get('id')
        r['name'] = n.get('name')
        r['url'] = n.get('url')
        results[i] = r

    threads = [threading.Thread(target=work, args=(i, n), daemon=True)
               for i, n in enumerate(nodes)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout + 2)
    return [r for r in results if r is not None]


def _valid_node_url(url):
    try:
        p = urllib.parse.urlparse(url)
    except Exception:
        return False
    return p.scheme in ('http', 'https') and bool(p.hostname)


# ── Node endpoint (this panel acting as a node) ───────────────
@app.route('/api/node/summary')
@require_node_token
def api_node_summary():
    svcs = get_services()
    return jsonify({
        'hostname': socket.gethostname(),
        'panel_version': PANEL_VERSION,
        'stats': get_system_stats(),
        'traffic': get_traffic(),
        'services': [{
            'cfg_name': s['cfg_name'], 'status': s['status'],
            'role': s['role'], 'mode': s['mode'], 'port': s['port'],
        } for s in svcs],
        'services_total': len(svcs),
        'services_active': sum(1 for s in svcs if s['status'] == 'active'),
    })


# ── Hub routes ────────────────────────────────────────────────
@app.route('/nodes')
@login_required
def nodes_page():
    cfg = load_panel_config()
    return render_template('nodes.html',
                           nodes=load_nodes(),
                           node_token=cfg.get('node_token', ''),
                           local_port=PANEL_PORT,
                           cfg=cfg, active='nodes')


@app.route('/api/nodes')
@login_required
def api_nodes_poll():
    return jsonify({'ok': True, 'nodes': poll_nodes(load_nodes())})


@app.route('/api/nodes/add', methods=['POST'])
@login_required
def api_nodes_add():
    body = request.get_json(silent=True) or {}
    name = (body.get('name') or '').strip()
    url = (body.get('url') or '').strip().rstrip('/')
    token = (body.get('token') or '').strip()

    if not url.startswith(('http://', 'https://')):
        url = 'http://' + url
    if not name:
        return jsonify({'ok': False, 'error': 'Name is required'})
    if not _valid_node_url(url):
        return jsonify({'ok': False, 'error': 'Invalid URL'})
    if not token:
        return jsonify({'ok': False, 'error': 'Token is required'})

    nodes = load_nodes()
    if any(n.get('url') == url for n in nodes):
        return jsonify({'ok': False, 'error': 'This node is already added'})

    probe = fetch_node({'url': url, 'token': token}, timeout=8)
    if not probe.get('ok'):
        return jsonify({'ok': False, 'error': probe.get('error', 'Node did not answer')})

    nodes.append({'id': uuid.uuid4().hex[:12], 'name': name,
                  'url': url, 'token': token})
    save_nodes(nodes)
    return jsonify({'ok': True, 'hostname': probe.get('hostname', '')})


@app.route('/api/nodes/<node_id>/delete', methods=['POST'])
@login_required
def api_nodes_delete(node_id):
    nodes = load_nodes()
    kept = [n for n in nodes if n.get('id') != node_id]
    if len(kept) == len(nodes):
        return jsonify({'ok': False, 'error': 'Node not found'})
    save_nodes(kept)
    return jsonify({'ok': True})


@app.route('/api/node/token/regenerate', methods=['POST'])
@login_required
def api_node_token_regenerate():
    cfg = load_panel_config()
    cfg['node_token'] = secrets.token_hex(24)
    save_panel_config(cfg)
    return jsonify({'ok': True, 'token': cfg['node_token']})


# ═══════════════════════════════════════════════════
#  TRAFFIC HISTORY — sampled every 60s into SQLite
# ═══════════════════════════════════════════════════

def _traffic_db_connect():
    os.makedirs(os.path.dirname(TRAFFIC_DB), exist_ok=True)
    conn = sqlite3.connect(TRAFFIC_DB, timeout=5)
    conn.execute('PRAGMA journal_mode=WAL')
    return conn

def init_traffic_db():
    conn = _traffic_db_connect()
    try:
        conn.execute('''CREATE TABLE IF NOT EXISTS traffic_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            iface TEXT NOT NULL,
            rx_bytes INTEGER NOT NULL,
            tx_bytes INTEGER NOT NULL
        )''')
        conn.execute('CREATE INDEX IF NOT EXISTS idx_traffic_ts ON traffic_samples(ts)')
        conn.commit()
    finally:
        conn.close()

def record_traffic_sample():
    data = get_traffic()
    ts = int(time.time())
    conn = _traffic_db_connect()
    try:
        for iface, v in data['interfaces'].items():
            conn.execute(
                'INSERT INTO traffic_samples (ts, iface, rx_bytes, tx_bytes) VALUES (?,?,?,?)',
                (ts, iface, v['rx'], v['tx']))
        # keep a little over 7 days on disk
        conn.execute('DELETE FROM traffic_samples WHERE ts < ?', (ts - 8 * 86400,))
        conn.commit()
    finally:
        conn.close()

def traffic_recorder_loop():
    init_traffic_db()
    while True:
        try:
            record_traffic_sample()
        except Exception:
            pass
        time.sleep(60)

def get_traffic_history(hours):
    """List of {time, rx_mbps, tx_mbps} across the requested window.

    Raw samples are per-interface cumulative byte counters taken every
    60s. Interfaces are summed per timestamp, then bucketed (bucket size
    grows with the window so a 7-day chart isn't 10k points) keeping the
    *last* sample of each bucket as its representative cumulative value.
    Rates come from the delta between consecutive bucket values — never
    from summing counters, which would double-count.
    """
    hours = max(1, min(hours, 24 * 30))
    since = int(time.time()) - hours * 3600
    if hours <= 6:
        bucket = 300      # 5 min
    elif hours <= 24:
        bucket = 900       # 15 min
    elif hours <= 72:
        bucket = 3600        # 1 hour
    else:
        bucket = 7200          # 2 hours

    try:
        conn = _traffic_db_connect()
        rows = conn.execute(
            'SELECT ts, SUM(rx_bytes) AS rx, SUM(tx_bytes) AS tx '
            'FROM traffic_samples WHERE ts >= ? GROUP BY ts ORDER BY ts',
            (since,)
        ).fetchall()
        conn.close()
    except Exception:
        rows = []

    buckets = {}
    for ts, rx, tx in rows:
        buckets[ts // bucket] = (ts, rx, tx)
    points = [buckets[k] for k in sorted(buckets)]

    out = []
    for (ts1, rx1, tx1), (ts2, rx2, tx2) in zip(points, points[1:]):
        dt = ts2 - ts1
        if dt <= 0:
            continue
        rx_mbps = max(0.0, (rx2 - rx1) * 8 / dt / 1_000_000)
        tx_mbps = max(0.0, (tx2 - tx1) * 8 / dt / 1_000_000)
        out.append({'time': ts2 * 1000, 'rx_mbps': round(rx_mbps, 3), 'tx_mbps': round(tx_mbps, 3)})
    return out

@app.route('/api/traffic/history')
@login_required
def api_traffic_history():
    hours = request.args.get('hours', 168, type=int) or 168
    return jsonify(get_traffic_history(hours))


# ═══════════════════════════════════════════════════
#  TELEGRAM ALERTS — fires when a node goes online -> offline
# ═══════════════════════════════════════════════════

_node_prev_state = {}
_node_state_lock = threading.Lock()

def _telegram_proxies(cfg):
    """requests-style proxies dict, or None. socks5h (not socks5) so DNS
    for api.telegram.org resolves through the proxy too — the whole
    point of this is reaching Telegram from a network that blocks it
    directly, so a direct DNS lookup would defeat it."""
    host = cfg.get('telegram_proxy_host', '').strip()
    port = cfg.get('telegram_proxy_port', '').strip()
    if not host or not port:
        return None
    user = cfg.get('telegram_proxy_username', '').strip()
    pwd = cfg.get('telegram_proxy_password', '').strip()
    auth = ''
    if user:
        auth = urllib.parse.quote(user, safe='')
        if pwd:
            auth += ':' + urllib.parse.quote(pwd, safe='')
        auth += '@'
    proxy_url = 'socks5h://%s%s:%s' % (auth, host, port)
    return {'http': proxy_url, 'https': proxy_url}

def _telegram_send(text):
    """POST one message to Telegram. Returns (ok, error_or_none) and
    never raises — callers decide whether a failure matters to them."""
    cfg = load_panel_config()
    token = cfg.get('telegram_token', '').strip()
    chat_id = cfg.get('telegram_chat_id', '').strip()
    if not token or not chat_id:
        return False, 'Telegram is not configured'
    try:
        r = requests.post(
            'https://api.telegram.org/bot%s/sendMessage' % token,
            data={'chat_id': chat_id, 'text': text},
            proxies=_telegram_proxies(cfg), timeout=12)
        if r.status_code == 200:
            return True, None
        try:
            return False, r.json().get('description', 'HTTP %s' % r.status_code)
        except Exception:
            return False, 'HTTP %s' % r.status_code
    except Exception as e:
        return False, str(e)

def send_telegram_alert(text):
    """Fire-and-forget for the node watcher — a failed notification must
    never break monitoring, so the result is discarded on purpose."""
    _telegram_send(text)

@app.route('/api/telegram/test', methods=['POST'])
@login_required
def api_telegram_test():
    ok, err = _telegram_send('\u2705 Test message from Erisrtg Panel')
    return jsonify({'ok': ok, 'error': err})

def _process_node_poll(results):
    """Update online/offline state per node, alerting only on the
    online -> offline transition. Split out from node_watcher_loop so
    the transition logic can be exercised directly without a live poll.
    """
    with _node_state_lock:
        for r in results:
            nid = r.get('id')
            if not nid:
                continue
            now_ok = bool(r.get('ok'))
            prev_ok = _node_prev_state.get(nid)
            if prev_ok is True and not now_ok:
                send_telegram_alert(
                    "\U0001F534 Node '%s' is OFFLINE\n%s" % (r.get('name', ''), r.get('url', '')))
            _node_prev_state[nid] = now_ok

def node_watcher_loop():
    while True:
        try:
            nodes = load_nodes()
            if nodes:
                _process_node_poll(poll_nodes(nodes, timeout=8))
        except Exception:
            pass
        time.sleep(30)


# ═══════════════════════════════════════════════════
#  BACKGROUND JOBS — one worker only, even with gunicorn -w N
# ═══════════════════════════════════════════════════

_lock_handles = []  # kept open for the process lifetime; closing releases the flock

def _try_singleton_lock(name):
    """True if THIS process should run the given background job.

    gunicorn runs multiple worker processes, each importing app.py once;
    without this guard every worker would record duplicate traffic
    samples and send duplicate Telegram alerts. flock is advisory and
    POSIX-only, so on a platform without fcntl (e.g. local dev on
    Windows) every process just runs the job — fine for local testing,
    where there's only ever one process anyway.
    """
    try:
        import fcntl
    except ImportError:
        return True
    path = os.path.join(os.path.dirname(PANEL_CONFIG), '.%s.lock' % name)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fh = open(path, 'w')
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    _lock_handles.append(fh)
    return True

def start_background_jobs():
    if _try_singleton_lock('traffic'):
        threading.Thread(target=traffic_recorder_loop, daemon=True).start()
    if _try_singleton_lock('nodewatch'):
        threading.Thread(target=node_watcher_loop, daemon=True).start()

start_background_jobs()


if __name__ == '__main__':
    _cfg = load_panel_config()
    _port = _cfg.get('panel_port', PANEL_PORT)
    _ssl_ctx = None
    if _cfg.get('ssl_enabled') and _cfg.get('ssl_cert_path') and _cfg.get('ssl_key_path'):
        _ssl_ctx = (_cfg['ssl_cert_path'], _cfg['ssl_key_path'])
    # Behind Ex-ui the only client is its reverse proxy on this same host, so
    # binding loopback keeps the port off the public interface entirely: nothing
    # outside the box can reach this panel or its login. PANEL_BIND=0.0.0.0
    # restores the standalone behaviour for an install without Ex-ui.
    _host = os.environ.get('PANEL_BIND', '127.0.0.1')
    app.run(host=_host, port=_port, debug=False, ssl_context=_ssl_ctx)
