# -*- coding: utf-8 -*-
"""run_imgdecrypt: spawn 番茄 + hook javax.crypto，抓漫画图片解密。
用法: python run_imgdecrypt.py [秒数]；UI 由外部 adb input 驱动。"""
import sys
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
RUN_SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 240
n = 0


def on_message(message, data):
    global n
    if message['type'] != 'send':
        if message['type'] == 'error':
            print('[script-error]', str(message)[:300], flush=True)
        return
    p = message['payload']
    k = p.get('kind')
    if k == 'CIPHER':
        n += 1
        print(f"CIPHER#{n} {p.get('tr')} in={p.get('inLen')} {p.get('inHead','')[:24]} out={p.get('outLen')} {p.get('outHead','')[:24]}", flush=True)
    elif k == 'KEY':
        print(f"KEY {p.get('algo')} len={p.get('len')} hex={p.get('hex','')[:64]}", flush=True)
    elif k == 'IV':
        print(f"IV len={p.get('len')} hex={p.get('hex','')[:64]} gcm={p.get('gcmT','')}", flush=True)
    elif k == 'TR':
        print(f"TR {p.get('tr')}", flush=True)
    elif k == 'OK':
        print('[hook-ok]', p.get('data'), flush=True)
    elif k == 'ERR':
        print('[hook-err]', p.get('data'), flush=True)


def main():
    device = frida.get_device('emulator-5554', timeout=10)
    print('spawn com.dragon.read ...', flush=True)
    pid = device.spawn(['com.dragon.read'])
    session = device.attach(pid)
    script = session.create_script(open(HERE / 'hook_imgdecrypt.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    print('resumed; 采集窗口', RUN_SECONDS, 's —— 现在驱动 UI', flush=True)
    t0 = time.time()
    while time.time() - t0 < RUN_SECONDS:
        time.sleep(3)
    print(f'窗口结束 CIPHER={n}', flush=True)


if __name__ == '__main__':
    main()
