"""spawn 捕获 + UI 驱动真实搜索：抓 App 自己的搜索请求完整参数和签名"""
import sys
import time
import subprocess
import frida

ADB = r'C:\Users\94985\AppData\Local\Android\Sdk\platform-tools\adb.exe'
EMU = 'emulator-5554'
PACKAGE = 'com.dragon.read'
DURATION = 70
MAX = 40

def sh(cmd):
    return subprocess.run([ADB, '-s', EMU, 'shell'] + cmd, capture_output=True, text=True, timeout=15)

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
                send('CAP#' + n + ' ' + url);
            };
        })(over[i]);
    }
    send('HOOKED');
});
""")

searches = []

def on_message(m, data):
    if m['type'] == 'send':
        p = m['payload']
        if p.startswith('CAP#'):
            print(p[:250], flush=True)
            if 'search' in p:
                searches.append(p)
    else:
        print('ERR:', str(m.get('description', ''))[:120], flush=True)

script.on('message', on_message)
script.load()
dev.resume(pid)
time.sleep(10)          # 首页加载
sh(['input', 'tap', '460', '306'])   # 点搜索框
time.sleep(5)
sh(['input', 'tap', '540', '620'])   # 点第一个热搜词（搜索页布局）
time.sleep(6)
sh(['input', 'swipe', '540', '1800', '540', '900', '300'])  # 滚动结果页
time.sleep(8)
session.detach()
print(f'--- 捕获到 {len(searches)} 条搜索类请求 ---', flush=True)
open('captured_search.txt', 'w', encoding='utf-8').write('\n\n'.join(searches))
for s in searches[:2]:
    print(s[:1500], flush=True)
