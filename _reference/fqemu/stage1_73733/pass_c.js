'use strict';
// Pass C: 转译环境兼容方案 — 签名瞬间全内存扫描明文针(设备字段ASCII), dump 命中窗口
// ndk_translation 下 guest 代码无法 hook, 但内存可读
var sigId = 0;
var maxSigs = 12;
var scanning = false;
var DEV_ID = '4052162698366793';
var CD_ID = 'b49e8968-4212';

function toPattern(s) {
    var hex = '';
    for (var i = 0; i < s.length; i++) hex += ('0' + s.charCodeAt(i).toString(16)).slice(-2);
    return hex;
}
var PATS = {};

function scanAll(tag) {
    if (scanning) return;
    scanning = true;
    try {
        var ranges = Process.enumerateRanges('rw-');
        var hits = 0;
        var sanityHits = 0;
        var needleHits = {};
        var CHUNK = 256 * 1024 * 1024;
        for (var ri = 0; ri < ranges.length; ri++) {
            var r = ranges[ri];
            if (r.size < 4096) continue;
            // 分块扫描: 大段(转译guest堆/ART堆)按256MB切块, 不再跳过
            for (var off = 0; off < r.size; off += CHUNK) {
                var cbase = r.base.add(off);
                var csize = Math.min(CHUNK, r.size - off);
                for (var pi = 0; pi < PATS.length; pi++) {
                    if ((needleHits[PATS[pi].name] || 0) >= PATS[pi].cap) continue;
                    var found;
                    try { found = Memory.scanSync(cbase, csize, PATS[pi].pat); } catch (e) { continue; }
                    for (var hi = 0; hi < found.length && hits < 120; hi++) {
                        if ((needleHits[PATS[pi].name] || 0) >= PATS[pi].cap) break;
                        needleHits[PATS[pi].name] = (needleHits[PATS[pi].name] || 0) + 1;
                        var a = found[hi].address;
                        var lo = a.sub(1024);
                        if (lo.compare(cbase) < 0) lo = cbase;
                        var span = Math.min(3072, Number(cbase.add(csize).sub(lo)));
                        try {
                            var bytes = Memory.readByteArray(lo, span);
                            if (bytes !== null && bytes !== undefined) {
                                hits++;
                                send({ kind: 'HIT', data: { sigId: sigId, needle: PATS[pi].name, addr: a.toString(), lo: lo.toString(), span: span } }, bytes);
                            }
                        } catch (e) { }
                    }
                    if (hits >= 120) break;
                }
                if (hits >= 120) break;
            }
            if (hits >= 120) break;
        }
        send({ kind: 'SCANDONE', data: { sigId: sigId, hits: hits, ranges: ranges.length, byNeedle: JSON.stringify(needleHits) } });
    } catch (e) {
        send({ kind: 'ERR', data: { where: 'scan', msg: '' + e } });
    }
    scanning = false;
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
        var NP = Java.use('com.bytedance.frameworks.baselib.network.http.NetworkParams');
        NP.tryAddSecurityFactor.overload('java.lang.String', 'java.util.Map')
            .implementation = function (url, headers) {
                var ret = this.tryAddSecurityFactor(url, headers);
                sigId++;
                if (sigId <= maxSigs && sigId % 2 === 1) {
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
                        scanAll('after');
                    } catch (e) {
                        send({ kind: 'ERR', data: { where: 'convert', msg: '' + e } });
                    }
                }
                return ret;
            };
        PATS = [
            { name: 'devid_le', pat: '494f35a66b650e00', cap: 30 },
            { name: 'iid_le', pat: '2b0a3ca66be50000', cap: 30 },
            { name: 'cdid', pat: toPattern(CD_ID), cap: 40 },
            { name: 'sanity_xmedusa', pat: toPattern('X-Medusa'), cap: 4 },
            { name: 'devid_ascii', pat: toPattern(DEV_ID), cap: 30 }
        ];
        send({ kind: 'OK', data: { hooked: 'tryAddSecurityFactor+scan' } });
    });
}
setTimeout(hookJava, 800);
