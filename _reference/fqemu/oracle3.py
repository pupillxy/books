"""oracle v3：签名 + 立即请求，一口气验证"""
import sys
import time
import urllib.request
import frida

PID = int(sys.argv[1])
URL = sys.argv[2]

UA = 'com.dragon.read/73733 (Linux; U; Android 15; zh_CN; sdk_gphone64_x86_64; Build/AP3A.241105.008;tt-ok/3.12.13.20)'

dev = frida.get_usb_device(timeout=10)
session = dev.attach(PID)
script = session.create_script(r"""
Java.perform(function() {
    var NP = Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
    var HM = Java.use('java.util.HashMap');
    var AL = Java.use('java.util.ArrayList');
    var h = HM.$new();
    var ua = AL.$new(); ua.add('__UA__');
    h.put('User-Agent', ua);
    var r = NP.tryAddSecurityFactor('__URL__', h);
    var parts = [];
    if (r !== null) {
                var it = r.keySet().iterator();
                while (it.hasNext()) {
                    var k = it.next().toString();
                    parts.push([k, r.get(k).toString()]);
                }
    }
    send(JSON.stringify(parts));
});
""".replace('__URL__', URL).replace('__UA__', UA))

result = {}

def on_message(m, data):
    if m['type'] == 'send':
        import json
        result['headers'] = json.loads(m['payload'])
    else:
        print('ERR:', str(m.get('description', ''))[:200], flush=True)

script.on('message', on_message)
script.load()
deadline = time.time() + 15
while 'headers' not in result and time.time() < deadline:
    time.sleep(0.3)

headers = result.get('headers', [])
print('签名头数量:', len(headers), flush=True)
req = urllib.request.Request(URL, headers={k: v for k, v in headers} | {'User-Agent': UA})
t0 = time.time()
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        body = r.read()
        print(f'HTTP {r.status}, {len(body)}B, {time.time()-t0:.1f}s', flush=True)
        txt = body.decode('utf-8', 'replace')
        import json as J
        try:
            d = J.loads(txt)
            code = d.get('code')
            data = d.get('data') or {}
            cells = data.get('data') or []
            n = 0
            names = []
            for cell in cells:
                for b in cell.get('book_data') or []:
                    n += 1
                    names.append(b.get('book_name') or '')
            print(f'code={code} books={n} msg={str(d.get("message"))[:40]}', flush=True)
            print('书名:', names[:5], flush=True)
        except Exception:
            print('非JSON:', txt[:200], flush=True)
except Exception as e:
    print('请求失败:', e, flush=True)
session.detach()
