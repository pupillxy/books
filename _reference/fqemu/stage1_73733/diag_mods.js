'use strict';
// 诊断: 枚举进程模块, 找转译层的 ARM libc
setTimeout(function () {
    Java.perform(function () {
        var mods = Process.enumerateModules();
        var hits = mods.filter(function (m) {
            return /libc\.so$|houdini|arm64|ndk_translation/i.test(m.name + ' ' + m.path);
        });
        var lines = hits.map(function (m) { return m.name + ' | ' + m.path + ' | ' + m.base + ' | ' + m.size; });
        send({ kind: 'MODS', data: { total: mods.length, lines: lines.slice(0, 40) } });
        // 也找 metasec
        var ms = mods.filter(function (m) { return /metasec/i.test(m.name); });
        send({ kind: 'MODS2', data: { lines: ms.map(function (m) { return m.name + ' | ' + m.path + ' | ' + m.base + ' | ' + m.size; }) } });
    });
}, 3000);
