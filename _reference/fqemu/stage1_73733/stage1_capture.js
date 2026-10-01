'use strict';
// 阶段1采集: hook tryAddSecurityFactor 抓 (url, 6签名头) + 跟踪签名期间 SO 的 malloc/free 缓冲区(抓 Medusa 明文)
// 用法: frida -f com.dragon.read -l stage1_capture.js  (由 stage1_run.py 驱动)

var flag = Memory.alloc(1);
flag.writeU8(0);
var sigId = 0;
var tracked = {};        // addr -> {size, buf}
var hooksReady = false;
var MAX_TRACK = 4000;
var DEV_ID = '4052162698366793';   // 模拟器里当前设备的 device_id (captured_urls.txt)

function logT(tag, obj) {
    send({ kind: tag, data: obj });
}

function isInteresting(addr, size) {
    // Medusa body ~768B (+24B header); 明文里应有 device_id ASCII 或 长度落在 body 量级
    if (size >= 600 && size <= 1600) return true;
    try {
        var found = Memory.scanSync(addr, size, stringToPattern(DEV_ID));
        return found.length > 0;
    } catch (e) { return false; }
}

function stringToPattern(s) {
    var hex = '';
    for (var i = 0; i < s.length; i++) {
        hex += ('0' + s.charCodeAt(i).toString(16)).slice(-2);
    }
    return hex;
}

function hookMalloc() {
    if (hooksReady) return;
    var libc = Process.getModuleByName('libc.so');
    var mallocPtr = libc.getExportByName('malloc');
    var freePtr = libc.getExportByName('free');
    var reallocPtr = libc.getExportByName('realloc');

    Interceptor.attach(mallocPtr, {
        onLeave: function (retval) {
            if (flag.readU8() !== 1 || retval.isNull()) return;
            var size = this.context ? 0 : 0;
            // malloc onLeave 拿不到 size 参数, 用 onEnter 记
        }
    });
    // 改用 onEnter 拿 size
    Interceptor.revert(mallocPtr);
    Interceptor.attach(mallocPtr, {
        onEnter: function (args) { this.sz = args[0].toInt32(); },
        onLeave: function (retval) {
            if (flag.readU8() !== 1 || retval.isNull()) return;
            var sz = this.sz;
            if (sz < 24 || sz > 65536 || Object.keys(tracked).length > MAX_TRACK) return;
            tracked[retval.toString()] = { size: sz, addr: retval };
        }
    });

    Interceptor.attach(reallocPtr, {
        onEnter: function (args) {
            this.old = args[0]; this.sz = args[1].toInt32();
        },
        onLeave: function (retval) {
            if (flag.readU8() !== 1) return;
            var k = this.old.toString();
            if (tracked[k] && !retval.isNull() && this.sz >= 24 && this.sz <= 65536) {
                delete tracked[k];
                tracked[retval.toString()] = { size: this.sz, addr: retval };
            }
        }
    });

    Interceptor.attach(freePtr, {
        onEnter: function (args) {
            var k = args[0].toString();
            if (tracked[k]) {
                emitBuf(tracked[k], 'free');
                delete tracked[k];
            }
        }
    });

    hooksReady = true;
    logT('OK', { hooked: 'malloc/free/realloc' });
}

function emitBuf(rec, why) {
    try {
        var bytes = Memory.readByteArray(rec.addr, Math.min(rec.size, 16384));
        var devIdHit = false;
        try {
            devIdHit = Memory.scanSync(rec.addr, Math.min(rec.size, 16384), stringToPattern(DEV_ID)).length > 0;
        } catch (e) { }
        send({
            kind: 'BUF', data: {
                sigId: sigId, why: why, size: rec.size,
                addr: rec.addr.toString(), devIdHit: devIdHit
            }
        }, bytes);
    } catch (e) { }
}

function flushAll() {
    var n = 0;
    for (var k in tracked) { emitBuf(tracked[k], 'flush'); n++; }
    tracked = {};
    return n;
}

function hookJava() {
    Java.perform(function () {
        try {
            var NP = Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
            NP.tryAddSecurityFactor.overload('java.lang.String', 'java.util.Map')
                .implementation = function (url, headers) {
                    flag.writeU8(1);
                    if (!hooksReady) { try { hookMalloc(); } catch (e) { logT('ERR', { where: 'hookMalloc', msg: '' + e }); } }
                    tracked = {};
                    sigId++;
                    var ret = this.tryAddSecurityFactor(url, headers);
                    flag.writeU8(0);
                    try {
                        var hmap = {};
                        if (ret !== null) {
                            var it = ret.keySet().iterator();
                            while (it.hasNext()) {
                                var k = it.next().toString();
                                hmap[k] = ret.get(k).toString();
                            }
                        }
                        logT('SIG', { sigId: sigId, url: url.toString(), headers: hmap });
                        flushAll();
                    } catch (e) {
                        logT('ERR', { where: 'sig-convert', msg: '' + e });
                    }
                    return ret;
                };
            logT('OK', { hooked: 'tryAddSecurityFactor' });
        } catch (e) {
            logT('ERR', { where: 'hookJava', msg: '' + e });
            setTimeout(hookJava, 2000);
        }
    });
}

setTimeout(hookJava, 500);
logT('OK', { stage: 'loaded' });
