# -*- coding: utf-8 -*-
"""reader_run: spawn 番茄 + hook tryAddSecurityFactor, 采集阅读器 (url, 签名头) 到 scroll_urls.jsonl
复用 capture_rank.js 的 hook；显式指定 emulator-5554（当前另有一个 mDNS TLS 设备条目）。
由外部(adb input/am)驱动 UI; 主进程 Ctrl-C/超时退出。
"""
import json
import sys
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
OUT = HERE / 'scroll_urls.jsonl'
RUN_SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 600
sig_count = 0


def on_message(message, data):
    global sig_count
    if message['type'] != 'send':
        if message['type'] == 'error':
            print('[script-error]', str(message)[:200], flush=True)
        return
    p = message['payload']
    if p['kind'] == 'SIG':
        sig_count += 1
        with open(OUT, 'a', encoding='utf-8') as f:
            f.write(json.dumps(p['data'], ensure_ascii=False) + '\n')
        print(f'SIG#{sig_count} {p["data"]["url"][:130]}', flush=True)
    elif p['kind'] == 'OK':
        print('[hook-ok]', p['data'], flush=True)
    elif p['kind'] == 'ERR':
        print('[hook-err]', p['data'], flush=True)


def main():
    device = frida.get_device('emulator-5554', timeout=10)
    print('spawn com.dragon.read ...', flush=True)
    pid = device.spawn(['com.dragon.read'])
    print('spawned pid=', pid, flush=True)
    session = device.attach(pid)
    script = session.create_script(open(HERE / 'capture_rank.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    print('resumed; 采集窗口', RUN_SECONDS, 's —— 现在可以驱动 UI', flush=True)
    t0 = time.time()
    while time.time() - t0 < RUN_SECONDS:
        time.sleep(5)
    print(f'窗口结束: SIG={sig_count}, 已写入 {OUT.name}', flush=True)


if __name__ == '__main__':
    main()
