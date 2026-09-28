"""快速探测：ms.bd.c.r4 在 73733 版里是否存在 + 有哪些方法"""
import sys
import frida

dev = frida.get_usb_device(timeout=10)
procs = [p for p in dev.enumerate_processes() if p.name == 'com.dragon.read']
pid = int(sys.argv[1]) if len(sys.argv) > 1 else procs[0].pid
print('attach:', pid)
session = dev.attach(pid)
script = session.create_script("""
Java.perform(function() {
    var out = [];
    ['ms.bd.c.r4', 'ms.bd.c.r3', 'ms.bd.c.r5', 'ms.bd.c.q4', 'ms.bd.c.s4'].forEach(function(cn) {
        try {
            var cls = Java.use(cn);
            var methods = cls.class.getDeclaredMethods();
            var names = [];
            for (var i = 0; i < methods.length; i++) {
                var n = methods[i].getName();
                if (names.indexOf(n) < 0) names.push(n);
            }
            out.push(cn + ' 存在 | 方法: ' + names.slice(0, 12).join(', '));
        } catch (e) {
            out.push(cn + ' 不存在');
        }
    });
    send(out.join('\\n'));
});
""")
script.on('message', lambda m, d: print(m['payload'] if m['type'] == 'send' else 'ERR: ' + str(m.get('description', ''))[:200]))
script.load()
import time
time.sleep(2)
session.detach()
