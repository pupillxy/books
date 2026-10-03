'use strict';
// 签名桥：在真番茄 App 进程内代签请求。
// - 捕获 App 真实请求的入参 header 集作为基础头模板（任何端点均可，多为公共头）
// - rpc.sign(url)：克隆基础头 → 调 NetworkParams.tryAddSecurityFactor 得到安全头 → 合并返回
// 上游收到的是「真 App 进程内、真 SO 签名、真基础头」的请求，与 App 自身请求无差别。
var attempts = 0;
var NP = null;
var lastBase = null; // 最近一次真实请求的基础头（{k:v}）
var lastMap = null; // 最近一次真实请求的原始 Map（Java 对象引用）
var lastMapCls = '';

function findNP() {
    var loaders = Java.enumerateClassLoadersSync();
    for (var i = 0; i < loaders.length; i++) {
        try {
            var c = loaders[i].loadClass('com.bytedance.frameworks.baselib.network.http.NetworkParams');
            if (c !== null) {
                Java.classFactory.loader = loaders[i];
                return Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
            }
        } catch (e) { }
    }
    return null;
}

function hookJava() {
    attempts++;
    Java.perform(function () {
        NP = findNP();
        if (NP === null) {
            setTimeout(hookJava, 2500);
            return;
        }
        try {
            NP.tryAddSecurityFactor.overload('java.lang.String', 'java.util.Map')
                .implementation = function (url, headers) {
                    try {
                        // 记录基础头模板（App 自带的完整 header 集）+ 保留原 Map 对象
                        var base = {};
                        if (headers !== null) {
                            var it = headers.keySet().iterator();
                            while (it.hasNext()) {
                                var k = it.next().toString();
                                base[k] = headers.get(k).toString();
                            }
                        }
                        lastBase = base;
                        lastMap = Java.retain(headers);
                        lastMapCls = headers.getClass().getName();
                    } catch (e) { }
                    return this.tryAddSecurityFactor(url, headers);
                };
            send({ kind: 'OK', data: { hooked: 'ready' } });
        } catch (e) {
            send({ kind: 'ERR', data: { msg: '' + e } });
            setTimeout(hookJava, 2500);
        }
    });
}
setTimeout(hookJava, 800);

function jmapToObj(jmap) {
    var o = {};
    if (jmap === null) return o;
    var it = jmap.keySet().iterator();
    while (it.hasNext()) {
        var k = it.next().toString();
        o[k] = jmap.get(k).toString();
    }
    return o;
}

rpc.exports = {
    // 就绪状态：是否已捕获到基础头模板
    ready: function () {
        return lastBase !== null;
    },
    // 用 App 基础头 + 真实签名代签一个 URL；失败返回 {error:...}
    // （RPC 线程非 Java 线程，perform 可能不同步执行——统一走主线程调度 + 忙等）
    sign: function (url) {
        var done = false, res = null, err = null;
        Java.scheduleOnMainThread(function () {
            try {
                if (NP === null) NP = findNP();
                if (NP === null) { err = 'NP not found'; return; }
                if (lastBase === null) { err = 'base headers not captured yet'; return; }
                var ret = NP.tryAddSecurityFactor.overload('java.lang.String', 'java.util.Map').call(NP, url, lastMap);
                var merged = {};
                for (var b in lastBase) merged[b] = lastBase[b];
                var sec = jmapToObj(ret);
                for (var s in sec) merged[s] = sec[s];
                res = merged;
            } catch (e) {
                err = '' + e;
            }
            done = true;
        });
        var t0 = Date.now();
        while (!done && Date.now() - t0 < 10000) {
            Thread.sleep(0.05);
        }
        if (err) return { error: err };
        if (!done) return { error: 'timeout waiting main thread' };
        return res;
    }
};
