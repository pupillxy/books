"""异步枚举 ms.bd.* 已加载类，找声明 onCallToAddSecurityFactor 的签名类"""
import sys
import time
import frida

PID = int(sys.argv[1])

dev = frida.get_usb_device(timeout=10)
session = dev.attach(PID)
script = session.create_script(r"""
var found = [];
function inspect(name) {
    try {
        var cls = Java.use(name);
        var ms = cls.class.getDeclaredMethods();
        for (var i = 0; i < ms.length; i++) {
            var mn = ms[i].getName();
            if (mn === 'onCallToAddSecurityFactor' || mn === 'addSecurityFactor') {
                var ps = ms[i].getParameterTypes();
                var p = '';
                for (var j = 0; j < ps.length; j++) p += ps[j].getSimpleName() + (j < ps.length - 1 ? ',' : '');
                found.push(name + ' -> ' + mn + '(' + p + ')');
                return;
            }
        }
    } catch (e) { /* ignore */ }
}
Java.perform(function() {
    var all = [];
    Java.enumerateLoadedClasses({
        onMatch: function(name) {
            if (name.indexOf('ms.bd.') === 0) all.push(name);
        },
        onComplete: function() {
            send('MSBD_COUNT ' + all.length);
            // 分批处理，避免卡死桥
            var idx = 0;
            function step() {
                var end = Math.min(idx + 40, all.length);
                for (; idx < end; idx++) inspect(all[idx]);
                if (idx < all.length) setImmediate(step);
                else send('DONE\n' + (found.length ? found.join('\n') : '未找到 onCallToAddSecurityFactor'));
            }
            setImmediate(step);
        }
    });
});
""")

results = []

def on_message(m, data):
    if m['type'] == 'send':
        print(m['payload'][:2000], flush=True)
        if m['payload'].startswith('DONE'):
            results.append(m['payload'])
    else:
        print('ERR:', str(m.get('description', ''))[:150], flush=True)

script.on('message', on_message)
script.load()
for _ in range(120):
    if results:
        break
    time.sleep(2)
session.detach()
