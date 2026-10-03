# -*- coding: utf-8 -*-
"""番茄签名桥：真 App 进程代签 + 代发正文请求，暴露 HTTP 给 NAS server。

用法（PC 常驻，模拟器保持运行）：
    python bridge_server.py
    # NAS 侧 compose 加 XS_APP_BRIDGE_URL=http://<PC_IP>:9998

端点：
    GET  /health                -> {"ready": bool, "app": pid}
    POST /content               -> body {"path": "/reading/reader/batch_full/v",
                                        "query": "item_ids=..&key_register_ts=0&book_id=..&req_type=1"}
                                 返回上游原始 JSON（Go 侧自行解析 txtContent）
"""
import gzip
import io
import json
import sys
import threading
import time
import urllib.request
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import frida

HERE = Path(__file__).parent
DEVICE_TAIL = (HERE / 'device_tail.txt').read_text(encoding='utf-8').strip()
BASE = 'https://api5-normal-sinfonlineb.fqnovel.com'
LISTEN = ('0.0.0.0', 9998)

device = frida.get_device('emulator-5554', timeout=10)
session = None
script = None
lock = threading.Lock()


def ensure_app():
    """附加到运行中的番茄；没跑就 spawn 一个。"""
    global session, script
    with lock:
        if script is not None:
            try:
                script.exports_sync.ready()
                return
            except Exception:
                try:
                    session.detach()
                except Exception:
                    pass
                script = None
        try:
            session = device.attach('com.dragon.read')
        except Exception:
            pid = device.spawn(['com.dragon.read'])
            device.resume(pid)
            time.sleep(3)
            session = device.attach(pid)
        script = session.create_script((HERE / 'bridge_sign.js').read_text(encoding='utf-8'))
        script.on('message', lambda m, d: print('[frida]', str(m)[:120], flush=True))
        script.load()
        # 等待 App 自发请求产生基础头模板（冷启动后几秒内必有遥测请求）
        for _ in range(40):
            if script.exports_sync.ready():
                break
            time.sleep(0.5)
        print('[bridge] ready=', script.exports_sync.ready(), flush=True)


UNIDBG_URL = 'http://192.168.31.16:9999'  # Java 签名/解密服务（NAS，局域网绑定）


def decrypt_via_java(content_b64, key_version):
    """密文正文交 Java 服务解密（密钥走它的 registerkey 流程）"""
    body = json.dumps({'content': content_b64, 'keyVersion': key_version}).encode('utf-8')
    req = urllib.request.Request(
        UNIDBG_URL + '/api/fqnovel/decrypt-content', data=body,
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as resp:
        out = json.loads(resp.read().decode('utf-8', 'replace'))
    return out.get('txtContent', '')


def content(path, query):
    """App 身份代取正文 → Java 解密 → 输出与 Java batch 端点同形。"""
    url = f'{BASE}{path}?{query}&{DEVICE_TAIL}'
    ensure_app()
    headers = script.exports_sync.sign(url)
    if isinstance(headers, dict) and 'error' in headers and 'User-Agent' not in headers:
        raise RuntimeError('sign 失败: ' + headers['error'][:180])
    if not headers:
        raise RuntimeError('sign 失败: 返回空')
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
        if resp.headers.get('Content-Encoding') == 'gzip':
            raw = gzip.decompress(raw)
        else:
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
    upstream = json.loads(raw.decode('utf-8', 'replace'))
    if upstream.get('code') != 0:
        return {'code': upstream.get('code', -1),
                'message': str(upstream.get('message'))[:100]}
    data = upstream.get('data') or {}
    items = data.get('data') if isinstance(data.get('data'), dict) else data
    chapters = {}
    for item_id, item in items.items():
        if not isinstance(item, dict) or not item.get('content'):
            continue
        txt = decrypt_via_java(item['content'], item.get('key_version'))
        if txt:
            chapters[item_id] = {'txtContent': txt}
    if not chapters:
        return {'code': -1, 'message': 'bridge 解密后无正文'}
    return {'code': 0, 'data': {'chapters': chapters}}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/health':
            try:
                ready = script is not None and script.exports_sync.ready()
            except Exception:
                ready = False
            self._send(200, {'ready': ready})
            return
        self._send(404, {'error': 'not found'})

    def do_POST(self):
        if self.path != '/content':
            self._send(404, {'error': 'not found'})
            return
        try:
            n = int(self.headers.get('Content-Length', '0'))
            req = json.loads(self.rfile.read(n).decode('utf-8'))
            # content() 已返回规范形状 {code, data:{chapters:{id:{txtContent}}}}
            self._send(200, content(req['path'], req['query']))
        except Exception as e:
            self._send(502, {'code': -1, 'error': str(e)[:200]})

    def log_message(self, fmt, *args):
        print('[http]', fmt % args, flush=True)


if __name__ == '__main__':
    print('[bridge] device tail loaded,', len(DEVICE_TAIL), 'chars', flush=True)
    threading.Thread(target=ensure_app, daemon=True).start()
    print(f'[bridge] listening on {LISTEN}', flush=True)
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
