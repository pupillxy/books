"""spawn 模式：被动捕获 App 真实的 tryAddSecurityFactor 调用（完整 URL + 返回签名头）"""
import sys
import time
import frida

PACKAGE = 'com.dragon.read'
DURATION = 50
MAX = 6

dev = frida.get_usb_device(timeout=10)
pid = dev.spawn([PACKAGE])
session = dev.attach(pid)
script = session.create_script(r"""
var n = 0;
Java.perform(function() {
    var NP = Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
    var over = NP.tryAddSecurityFactor.overloads;
    for (var i = 0; i < over.length; i++) {
        (function(ov) {
            ov.implementation = function() {
                var url = arguments[0] ? arguments[0].toString() : 'null';
                var arg1 = 'null';
                try { arg1 = arguments[1] ? arguments[1].toString().substring(0, 200) : 'null'; } catch (e) {}
                var ret = ov.apply(this, arguments);
                var parts = [];
                try {
                    if (ret !== null) {
                        var it = ret.keySet().iterator();
                        while (it.hasNext()) {
                            var k = it.next().toString();
                            parts.push(k + '=' + ret.get(k).toString());
                        }
                    }
                } catch (e) { parts.push('ERR'); }
                n++;
                if (n <= __MAX__) {
                    send('CAPTURED#' + n + ' (' + url.length + ' chars)\nURL: ' + url + '\nSIG: ' + parts.join('||'));
                }
                return ret;
            };
        })(over[i]);
    }
    send('HOOKED');
});
""".replace('__MAX__', str(MAX)))

captured = []

def on_message(m, data):
    if m['type'] == 'send':
        print(m['payload'][:2600], flush=True)
        if m['payload'].startswith('CAPTURED'):
            captured.append(m['payload'])
    else:
        print('ERR:', str(m.get('description', ''))[:150], flush=True)

script.on('message', on_message)
script.load()
dev.resume(pid)
print(f'--- 冷启动捕获 {DURATION}s ---', flush=True)
time.sleep(DURATION)
session.detach()
open('captured_urls.txt', 'w', encoding='utf-8').write('\n\n'.join(captured))
print(f'--- 已保存 {len(captured)} 条到 captured_urls.txt ---', flush=True)
