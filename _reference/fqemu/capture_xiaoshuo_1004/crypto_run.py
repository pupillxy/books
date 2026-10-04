# -*- coding: utf-8 -*-
"""crypto_run: spawn 番茄 + hook javax.crypto/BitmapFactory，观察加密漫画图的运行时解密。
UI 由外部 adb input 驱动；输出摘要到 stdout。
"""
import json
import sys
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
RUN_SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 600
n = 0


def on_message(message, data):
    global n
    if message['type'] != 'send':
        if message['type'] == 'error':
            print('[script-error]', str(message)[:300], flush=True)
        return
    p = message['payload']
    k = p.get('kind')
    d = p.get('data', {})
    if k == 'DOFINAL':
        n += 1
        # 只显示较大的调用（图片解密 >10KB），小包（协议文本）折叠
        if d['inLen'] > 8192 or d['outLen'] > 8192:
            print(f"[{d['n']}] DOFINAL {d['alg']} in={d['inLen']}({d['inHead']}) out={d['outLen']}({d['outHead']})", flush=True)
        else:
            print(f"[{d['n']}] DOFINAL {d['alg']} in={d['inLen']} out={d['outLen']}", flush=True)
    elif k == 'KEY':
        print(f"KEY {d['alg']} len={d['keyLen']} {d['key']}", flush=True)
    elif k == 'IV':
        print(f"IV len={d['len']} {d['iv']}", flush=True)
    elif k == 'BMP':
        print(f"BMP len={d['len']} head={d['head']}", flush=True)
    elif k == 'OK':
        print('[hook-ok]', d, flush=True)


def main():
    device = frida.get_device('emulator-5554', timeout=10)
    print('spawn com.dragon.read ...', flush=True)
    pid = device.spawn(['com.dragon.read'])
    session = device.attach(pid)
    script = session.create_script(open(HERE / 'crypto_hook.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    print('resumed; 窗口', RUN_SECONDS, 's', flush=True)
    t0 = time.time()
    while time.time() - t0 < RUN_SECONDS:
        time.sleep(5)
    print('窗口结束', flush=True)


if __name__ == '__main__':
    main()
