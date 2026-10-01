# -*- coding: utf-8 -*-
"""Pass A2: spawn 模式拉起番茄, 验证签名 hook"""
import json
import subprocess
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
ADB = r'C:\Users\94985\AppData\Local\Android\Sdk\platform-tools\adb.exe'
sig_count = 0


def adb(*args, t=20):
    subprocess.run([ADB, *args], capture_output=True, timeout=t)


def on_message(message, data):
    global sig_count
    if message['type'] != 'send':
        if message['type'] == 'error':
            print('[script-error]', str(message)[:150], flush=True)
        return
    p = message['payload']
    if p['kind'] == 'SIG':
        sig_count += 1
        with open(HERE / 'samples.jsonl', 'a', encoding='utf-8') as f:
            f.write(json.dumps(p['data'], ensure_ascii=False) + '\n')
        if sig_count % 5 == 0:
            print(f'SIG x{sig_count}', flush=True)
    elif p['kind'] == 'OK':
        print('[hook-ok]', p['data'], flush=True)
    elif p['kind'] == 'ERR':
        print('[hook-err]', p['data'], flush=True)


def main():
    device = frida.get_usb_device(timeout=10)
    print('spawn com.dragon.read ...', flush=True)
    pid = device.spawn(['com.dragon.read'])
    print('spawned pid=', pid, flush=True)
    session = device.attach(pid)
    script = session.create_script(open(HERE / 'pass_a.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    print('resumed, 等冷启动 ...', flush=True)

    t0 = time.time()
    last_sig = 0
    while time.time() - t0 < 150:
        time.sleep(6)
        print(f'  t={int(time.time()-t0)}s sig={sig_count}', flush=True)
        if sig_count >= 30:
            break
        if sig_count == last_sig and time.time() - t0 > 40:
            # 没新签名就滑一下驱动流量
            try:
                adb('shell', 'input', 'swipe', '540', '1100', '540', '500', '250', t=15)
            except Exception:
                pass
        last_sig = sig_count
    print(f'Pass A2 完成: SIG={sig_count}', flush=True)


if __name__ == '__main__':
    main()
