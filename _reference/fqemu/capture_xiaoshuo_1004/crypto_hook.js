'use strict';
// hook javax.crypto.Cipher（init/doFinal）+ BitmapFactory.decodeByteArray：
// 官方 App 加载加密漫画图时会在此暴露算法/密钥/明文。只打印摘要避免刷屏。
var logCount = 0;

function bytesToHex(arr, max) {
    var len = Math.min(arr.length, max || 32);
    var hex = '';
    for (var i = 0; i < len; i++) {
        var b = (arr[i] & 0xff).toString(16);
        hex += (b.length < 2 ? '0' : '') + b;
    }
    return hex;
}

function jarrToJs(javaArr) {
    var out = [];
    var len = javaArr.length;
    for (var i = 0; i < len; i++) out.push(javaArr[i] & 0xff);
    return out;
}

Java.perform(function () {
    var Cipher = Java.use('javax.crypto.Cipher');
    var SecretKeySpec = Java.use('javax.crypto.spec.SecretKeySpec');
    var IvParameterSpec = Java.use('javax.crypto.spec.IvParameterSpec');
    var GCMParameterSpec = Java.use('javax.crypto.spec.GCMParameterSpec');
    var seq = 0;

    SecretKeySpec.$init.overload('[B', 'java.lang.String').implementation = function (key, alg) {
        var arr = jarrToJs(key);
        send({ kind: 'KEY', data: { alg: alg, key: bytesToHex(arr, 32), keyLen: arr.length, seq: ++seq } });
        return this.$init(key, alg);
    };
    SecretKeySpec.$init.overload('[B', 'int', 'int', 'java.lang.String').implementation = function (key, off, len, alg) {
        var arr = jarrToJs(key).slice(off, off + len);
        send({ kind: 'KEY', data: { alg: alg, key: bytesToHex(arr, 32), keyLen: arr.length, seq: ++seq, note: 'sub' } });
        return this.$init(key, off, len, alg);
    };
    IvParameterSpec.$init.overload('[B').implementation = function (iv) {
        var arr = jarrToJs(iv);
        send({ kind: 'IV', data: { iv: bytesToHex(arr, 32), len: arr.length, seq: ++seq } });
        return this.$init(iv);
    };
    IvParameterSpec.$init.overload('[B', 'int', 'int').implementation = function (iv, off, len) {
        var arr = jarrToJs(iv).slice(off, off + len);
        send({ kind: 'IV', data: { iv: bytesToHex(arr, 32), len: arr.length, seq: ++seq, note: 'sub' } });
        return this.$init(iv, off, len);
    };
    GCMParameterSpec.$init.overload('int', '[B').implementation = function (tLen, iv) {
        var arr = jarrToJs(iv);
        send({ kind: 'GCMIV', data: { tLen: tLen, iv: bytesToHex(arr, 32), len: arr.length, seq: ++seq } });
        return this.$init(tLen, iv);
    };
    Cipher.doFinal.overload('[B').implementation = function (input) {
        var inArr = jarrToJs(input);
        var out = this.doFinal(input);
        var outArr = out ? jarrToJs(out) : [];
        logCount++;
        send({
            kind: 'DOFINAL', data: {
                alg: this.getAlgorithm(),
                inLen: inArr.length, inHead: bytesToHex(inArr, 24),
                outLen: outArr.length, outHead: bytesToHex(outArr, 24),
                n: logCount, seq: ++seq
            }
        });
        return out;
    };

    var BMP = Java.use('android.graphics.BitmapFactory');
    BMP.decodeByteArray.overload('[B', 'int', 'int').implementation = function (data, off, len) {
        var arr = jarrToJs(data);
        send({ kind: 'BMP', data: { len: len, head: bytesToHex(arr.slice(off, off + 32), 32) } });
        return this.decodeByteArray(data, off, len);
    };
    send({ kind: 'OK', data: { hooked: 'crypto+bmp' } });
});
