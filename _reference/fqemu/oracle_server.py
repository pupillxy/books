"""番茄签名 oracle 常驻服务

frida RPC 挂常驻模拟器里的番茄 App，对外暴露 HTTP：
  GET /health            → 存活检查
  GET /sign?url=<完整URL> → 返回签名头 JSON {"headers": {...}}
  GET /fetch?url=<完整URL> → 签名 + 代发请求，返回上游原始响应体（透传 content-type）

用法：
  python oracle_server.py [端口=8765]
  （需先：模拟器跑起来 + adb root + frida-server 16.x 运行 + 番茄已启动）
"""
import json
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import frida

ADB = r'C:\Users\94985\AppData\Local\Android\Sdk\platform-tools\adb.exe'
EMU = 'emulator-5554'
PACKAGE = 'com.dragon.read'
UA = ('com.dragon.read/73733 (Linux; U; Android 15; zh_CN; sdk_gphone64_x86_64; '
      'Build/AP3A.240806.043;tt-ok/3.12.13.20)')

JS = r"""
rpc.exports = {
    sign: function(url) {
        var out = {};
        Java.perform(function() {
            var NP = Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
            var HM = Java.use('java.util.HashMap');
            var AL = Java.use('java.util.ArrayList');
            var h = HM.$new();
            var ua = AL.$new(); ua.add('__UA__');
            h.put('User-Agent', ua);
            var r = NP.tryAddSecurityFactor(url, h);
            if (r !== null) {
                var it = r.keySet().iterator();
                while (it.hasNext()) {
                    var k = it.next().toString();
                    out[k] = r.get(k).toString();
                }
            }
        });
        return JSON.stringify(out);
    }
};
""".replace('__UA__', UA)

lock = threading.Lock()
state = {'session': None, 'script': None, 'pid': None}


def find_pid():
    r = subprocess.run([ADB, '-s', EMU, 'shell', 'pidof', PACKAGE],
                       capture_output=True, text=True, timeout=10)
    pids = r.stdout.split()
    return int(pids[0]) if pids else None


def ensure_session():
    with lock:
        pid = find_pid()
        if pid is None:
            raise RuntimeError('番茄未运行')
        if state['script'] is not None and state['pid'] == pid:
            return state['script']
        if state['session'] is not None:
            try:
                state['session'].detach()
            except Exception:
                pass
        dev = frida.get_usb_device(timeout=10)
        session = dev.attach(pid)
        script = session.create_script(JS)
        script.load()
        state.update(session=session, script=script, pid=pid)
        print(f'[oracle] attached pid={pid}', flush=True)
        return script


def sign(url: str) -> dict:
    script = ensure_session()
    raw = script.exports_sync.sign(url)
    return json.loads(raw)


def fetch(url: str, timeout: int = 20):
    headers = sign(url)
    headers['User-Agent'] = UA
    headers.setdefault('Accept', 'application/json')
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.headers.get('Content-Type', 'application/json'), r.read()


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj, ctype='application/json'):
        body = obj if isinstance(obj, bytes) else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if u.path == '/health':
            try:
                ensure_session()
                self._json(200, {'ok': True, 'pid': state['pid']})
            except Exception as e:
                self._json(503, {'ok': False, 'error': str(e)})
        elif u.path == '/sign':
            url = qs.get('url', [''])[0]
            if not url.startswith('http'):
                self._json(400, {'error': 'url 必须是完整 URL'})
                return
            try:
                self._json(200, {'headers': sign(url)})
            except Exception as e:
                self._json(502, {'error': str(e)})
        elif u.path == '/fetch':
            url = qs.get('url', [''])[0]
            if not url.startswith('http'):
                self._json(400, {'error': 'url 必须是完整 URL'})
                return
            try:
                code, ctype, body = fetch(url)
                self._json(code, body, ctype)
            except Exception as e:
                self._json(502, {'error': str(e)})
        else:
            self._json(404, {'error': 'not found'})

    def log_message(self, fmt, *args):
        print('[http]', fmt % args, flush=True)


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ensure_session()
    print(f'[oracle] HTTP 服务 0.0.0.0:{port}（/health /sign /fetch）', flush=True)
    ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()
