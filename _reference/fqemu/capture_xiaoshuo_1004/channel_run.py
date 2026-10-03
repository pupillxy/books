# -*- coding: utf-8 -*-
"""channel_run: spawn 番茄 + hook tryAddSecurityFactor，采集书城频道/筛选请求到 jsonl
用法: python channel_run.py [秒数]；UI 由外部 adb input 驱动。
"""
import json
import sys
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
OUT = HERE / 'channel_urls.jsonl'
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
        print(f'SIG#{sig_count} {p["data"]["url"][:120]}', flush=True)
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
    script = session.create_script(
        open(HERE.parent / 'capture_xiaoshuo_1003' / 'capture_rank.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    print('resumed; 采集窗口', RUN_SECONDS, 's —— 现在驱动 UI', flush=True)
    t0 = time.time()
    while time.time() - t0 < RUN_SECONDS:
        time.sleep(5)
    print(f'窗口结束: SIG={sig_count}, 已写入 {OUT.name}', flush=True)


if __name__ == '__main__':
    main()
