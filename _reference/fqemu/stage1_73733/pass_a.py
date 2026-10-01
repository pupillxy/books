# -*- coding: utf-8 -*-
"""Pass A: 附加运行中的番茄进程, 验证签名 hook 是否出数据"""
import json
import subprocess
import sys
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
    pids = [p.pid for p in device.enumerate_processes() if p.name == 'com.dragon.read']
    print('目标进程:', pids, flush=True)
    scripts = []
    for pid in pids:
        try:
            s = device.attach(pid)
            sc = s.create_script(open(HERE / 'pass_a.js', encoding='utf-8').read())
            sc.on('message', on_message)
            sc.load()
            scripts.append((pid, s, sc))
            print(f'已注入 pid={pid}', flush=True)
        except Exception as e:
            print(f'注入 pid={pid} 失败: {e}', flush=True)

    t0 = time.time()
    while time.time() - t0 < 100:
        time.sleep(5)
        if sig_count >= 30:
            break
        # 驱动流量: 滑动
        try:
            adb('shell', 'input', 'swipe', '540', '1100', '540', '500', '250', t=15)
        except Exception:
            pass
    print(f'Pass A 完成: SIG={sig_count}', flush=True)
    for _, s, _ in scripts:
        try:
            s.detach()
        except Exception:
            pass


if __name__ == '__main__':
    main()
