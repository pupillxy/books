'use strict';
/* hook javax.crypto 系：抓漫画图片解密的算法/密钥/IV/输入输出
 * 事件: KEY(SecretKeySpec) / IV(IvParameterSpec) / CIPHER(doFinal in/out) / TR(transform) */

function hexOf(arr, limit) {
    var n = Math.min(arr.length, limit || 24);
    var s = '';
    for (var i = 0; i < n; i++) {
        var b = arr[i] & 0xff;
        s += (b < 16 ? '0' : '') + b.toString(16);
    }
    return s;
}

function stackHead(depth) {
    var out = [];
    var st = Thread.backtrace(context2, Backtracer.ACCURATE);
    return out;
}

Java.perform(function () {
    send({ kind: 'OK', data: 'imgdecrypt hooks loading' });

    var SecretKeySpec = Java.use('javax.crypto.spec.SecretKeySpec');
    SecretKeySpec.$init.overload('[B', 'java.lang.String').implementation = function (key, algo) {
        try {
            send({ kind: 'KEY', algo: algo, hex: hexOf(key, 64), len: key.length });
        } catch (e) { }
        return this.$init(key, algo);
    };

    var IvParameterSpec = Java.use('javax.crypto.spec.IvParameterSpec');
    IvParameterSpec.$init.overload('[B').implementation = function (iv) {
        try {
            send({ kind: 'IV', hex: hexOf(iv, 64), len: iv.length });
        } catch (e) { }
        return this.$init(iv);
    };

    var GCM = null;
    try { GCM = Java.use('javax.crypto.spec.GCMParameterSpec'); } catch (e) { }
    if (GCM) {
        GCM.$init.overload('int', '[B').implementation = function (tLen, iv) {
            try {
                send({ kind: 'IV', hex: hexOf(iv, 64), len: iv.length, gcmT: tLen });
            } catch (e) { }
            return this.$init(tLen, iv);
        };
    }

    var Cipher = Java.use('javax.crypto.Cipher');
    Cipher.getInstance.overload('java.lang.String').implementation = function (tr) {
        send({ kind: 'TR', tr: tr });
        return this.getInstance(tr);
    };
    Cipher.getInstance.overload('java.lang.String', 'java.security.Provider').implementation = function (tr, p) {
        send({ kind: 'TR', tr: tr, prov: p ? p.getName() : null });
        return this.getInstance(tr, p);
    };
    Cipher.getInstance.overload('java.lang.String', 'java.lang.String').implementation = function (tr, p) {
        send({ kind: 'TR', tr: tr, prov: p });
        return this.getInstance(tr, p);
    };

    function dumpCipher(self, input, output) {
        try {
            var tr = self.getAlgorithm ? self.getAlgorithm() : '?';
            var inHex = input ? hexOf(input, 24) : '';
            var outHex = output ? hexOf(output, 24) : '';
            send({
                kind: 'CIPHER', tr: tr,
                inLen: input ? input.length : -1, inHead: inHex,
                outLen: output ? output.length : -1, outHead: outHex,
            });
        } catch (e) {
            send({ kind: 'ERR', data: 'dumpCipher ' + e });
        }
    }

    Cipher.doFinal.overload('[B').implementation = function (input) {
        var out = this.doFinal(input);
        dumpCipher(this, input, out);
        return out;
    };
    Cipher.doFinal.overload('[B', 'int', 'int').implementation = function (input, off, len) {
        var out = this.doFinal(input, off, len);
        try {
            var tr = this.getAlgorithm();
            send({
                kind: 'CIPHER', tr: tr, off: off, len: len,
                inLen: len, inHead: hexOf(input, 24),
                outLen: out ? out.length : -1, outHead: out ? hexOf(out, 24) : '',
            });
        } catch (e) { }
        return out;
    };

    send({ kind: 'OK', data: 'imgdecrypt hooks loaded' });
});
