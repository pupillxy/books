'use strict';
// Pass A3: 枚举类加载器找到 App 的 loader 再 hook (解决 spawn 早期 dex 未加载问题)
var attempts = 0;

function hookJava() {
    attempts++;
    Java.perform(function () {
        var targetLoader = null;
        try {
            var loaders = Java.enumerateClassLoadersSync();
            for (var i = 0; i < loaders.length; i++) {
                try {
                    var c = loaders[i].loadClass('com.bytedance.frameworks.baselib.network.http.NetworkParams');
                    if (c !== null) { targetLoader = loaders[i]; break; }
                } catch (e) { }
            }
        } catch (e) {
            send({ kind: 'ERR', data: { where: 'enumerate', msg: '' + e } });
        }
        if (targetLoader === null) {
            if (attempts % 5 === 1) send({ kind: 'OK', data: { wait: 'class not loaded yet, attempt ' + attempts } });
            setTimeout(hookJava, 2500);
            return;
        }
        Java.classFactory.loader = targetLoader;
        try {
            var NP = Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
            NP.tryAddSecurityFactor.overload('java.lang.String', 'java.util.Map')
                .implementation = function (url, headers) {
                    var ret = this.tryAddSecurityFactor(url, headers);
                    try {
                        var hmap = {};
                        if (ret !== null) {
                            var it = ret.keySet().iterator();
                            while (it.hasNext()) {
                                var k = it.next().toString();
                                hmap[k] = ret.get(k).toString();
                            }
                        }
                        send({ kind: 'SIG', data: { url: url.toString(), headers: hmap } });
                    } catch (e) {
                        send({ kind: 'ERR', data: { where: 'convert', msg: '' + e } });
                    }
                    return ret;
                };
            send({ kind: 'OK', data: { hooked: 'tryAddSecurityFactor', attempt: attempts } });
        } catch (e) {
            send({ kind: 'ERR', data: { where: 'hook', msg: '' + e } });
            setTimeout(hookJava, 2500);
        }
    });
}
setTimeout(hookJava, 800);
