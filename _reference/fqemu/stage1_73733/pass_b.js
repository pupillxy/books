'use strict';
// Pass B: 签名 hook + malloc/calloc/realloc/free 跟踪 (抓 Medusa 明文)
// malloc hooks 在 Java hook 成功后立即挂载, flag 门控
var flag = Memory.alloc(1);
flag.writeU8(0);
var sigId = 0;
var tracked = {};
var bufCap = 800;      // 每次签名最多记录缓冲区数
var maxSigs = 25;      // 只在前 N 次签名抓缓冲区
var hooksReady = false;
var DEV_ID = '4052162698366793';
var CD_ID = 'b49e8968';

function toPattern(s) {
    var hex = '';
    for (var i = 0; i < s.length; i++) hex += ('0' + s.charCodeAt(i).toString(16)).slice(-2);
    return hex;
}
var DEV_PAT = null, CD_PAT = null;

function emitBuf(rec, why) {
    try {
        var sz = Math.min(rec.size, 16384);
        var bytes = Memory.readByteArray(rec.addr, sz);
        if (bytes === null || bytes === undefined) return;
        var devid = false, cdid = false;
        try {
            devid = Memory.scanSync(rec.addr, sz, DEV_PAT).length > 0;
            cdid = Memory.scanSync(rec.addr, sz, CD_PAT).length > 0;
        } catch (e) { }
        send({ kind: 'BUF', data: { sigId: sigId, why: why, size: rec.size, addr: rec.addr.toString(), devid: devid, cdid: cdid } }, bytes);
    } catch (e) { }
}

function trackEnter() {
    tracked = {};
    sigId++;
    flag.writeU8(1);
}

function trackLeave() {
    flag.writeU8(0);
    for (var k in tracked) { emitBuf(tracked[k], 'flush'); }
    tracked = {};
}

function hookNativeAlloc() {
    if (hooksReady) return;
    hooksReady = true;
    DEV_PAT = toPattern(DEV_ID);
    CD_PAT = toPattern(CD_ID);
    var libc = Process.getModuleByName('libc.so');
    ['malloc', 'calloc', 'realloc'].forEach(function (fn) {
        Interceptor.attach(libc.getExportByName(fn), {
            onEnter: function (args) {
                if (flag.readU8() !== 1) { this.t = false; return; }
                var sz;
                if (fn === 'calloc') sz = args[0].toInt32() * args[1].toInt32();
                else if (fn === 'realloc') sz = args[1].toInt32();
                else sz = args[0].toInt32();
                this.t = (sz >= 16 && sz <= 16384 && Object.keys(tracked).length < bufCap);
                this.sz = sz;
                this.old = args[0];
            },
            onLeave: function (retval) {
                if (!this.t || retval.isNull()) return;
                if (fn === 'realloc' && !this.old.isNull()) {
                    var ok = this.old.toString();
                    if (tracked[ok]) delete tracked[ok];
                }
                tracked[retval.toString()] = { size: this.sz, addr: retval };
            }
        });
    });
    Interceptor.attach(libc.getExportByName('free'), {
        onEnter: function (args) {
            if (flag.readU8() !== 1) return;
            var k = args[0].toString();
            if (tracked[k]) { emitBuf(tracked[k], 'free'); delete tracked[k]; }
        }
    });
    send({ kind: 'OK', data: { hooked: 'malloc/calloc/realloc/free' } });
}

function hookJava() {
    Java.perform(function () {
        var targetLoader = null;
        try {
            var loaders = Java.enumerateClassLoadersSync();
            for (var i = 0; i < loaders.length; i++) {
                try {
                    if (loaders[i].loadClass('com.bytedance.frameworks.baselib.network.http.NetworkParams') !== null) {
                        targetLoader = loaders[i]; break;
                    }
                } catch (e) { }
            }
        } catch (e) { }
        if (targetLoader === null) { setTimeout(hookJava, 2500); return; }
        Java.classFactory.loader = targetLoader;
        try {
            var NP = Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
            NP.tryAddSecurityFactor.overload('java.lang.String', 'java.util.Map')
                .implementation = function (url, headers) {
                    if (sigId < maxSigs) { hookNativeAlloc(); trackEnter(); }
                    var ret = this.tryAddSecurityFactor(url, headers);
                    if (sigId <= maxSigs) { trackLeave(); }
                    try {
                        var hmap = {};
                        if (ret !== null) {
                            var it = ret.keySet().iterator();
                            while (it.hasNext()) {
                                var k = it.next().toString();
                                hmap[k] = ret.get(k).toString();
                            }
                        }
                        send({ kind: 'SIG', data: { sigId: sigId, url: url.toString(), headers: hmap } });
                    } catch (e) {
                        send({ kind: 'ERR', data: { where: 'convert', msg: '' + e } });
                    }
                    return ret;
                };
            send({ kind: 'OK', data: { hooked: 'tryAddSecurityFactor' } });
        } catch (e) {
            send({ kind: 'ERR', data: { where: 'hook', msg: '' + e } });
            setTimeout(hookJava, 2500);
        }
    });
}
setTimeout(hookJava, 800);
