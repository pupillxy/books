"""决定性实验：oracle 签 App 自己的真实 URL → 立即 curl 验证"""
import sys
import time
import urllib.request
import frida

PID = int(sys.argv[1])
URL = sys.argv[2]  # App 刚发过的真实 URL（含全部参数）

UA = 'com.dragon.read/73733 (Linux; U; Android 15; zh_CN; sdk_gphone64_x86_64; Build/AP3A.240806.043;tt-ok/3.12.13.20)'

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
        print('ERR:', str(m.get('description', ''))[:150], flush=True)

script.on('message', on_message)
script.load()
deadline = time.time() + 15
while 'headers' not in result and time.time() < deadline:
    time.sleep(0.3)

headers = dict(result.get('headers', []))
print('签名头:', sorted(headers.keys()), flush=True)
req = urllib.request.Request(URL, headers={**headers, 'User-Agent': UA, 'Accept': 'application/json',
                                           'sdk-version': '2', 'lc': '101',
                                           'X-SS-REQ-TICKET': str(int(time.time() * 1000))})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        body = r.read()
        print(f'HTTP {r.status}, {len(body)}B', flush=True)
        print('body头200字符:', body.decode('utf-8', 'replace')[:200], flush=True)
except Exception as e:
    print('请求失败:', e, flush=True)
session.detach()
