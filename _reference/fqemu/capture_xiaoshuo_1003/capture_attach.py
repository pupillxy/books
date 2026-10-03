# -*- coding: utf-8 -*-
"""attach 模式采集：附加到正在运行的番茄主进程（不重启 App）"""
import json
import sys
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
OUT = HERE / 'rank_urls.jsonl'
RUN_SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 300
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
        print(f'SIG#{sig_count} {p["data"]["url"][:110]}', flush=True)
    elif p['kind'] == 'OK':
        print('[hook-ok]', p['data'], flush=True)
    elif p['kind'] == 'ERR':
        print('[hook-err]', p['data'], flush=True)


def main():
    device = frida.get_usb_device(timeout=10)
    target = int(sys.argv[2]) if len(sys.argv) > 2 else 'com.dragon.read'
    session = device.attach(target)
    print('attached to', target, flush=True)
    script = session.create_script(open(HERE / 'capture_rank.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    print('hook loaded; 采集窗口', RUN_SECONDS, 's', flush=True)
    t0 = time.time()
    while time.time() - t0 < RUN_SECONDS:
        time.sleep(5)
    print(f'窗口结束: SIG={sig_count}', flush=True)


if __name__ == '__main__':
    main()
