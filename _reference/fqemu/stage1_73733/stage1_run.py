# -*- coding: utf-8 -*-
"""阶段1采集驱动: spawn 番茄 -> 挂脚本 -> 驱动流量(冷启动+monkey+滑动刷新) -> 收样本"""
import base64
import json
import subprocess
import sys
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
DUMPS = HERE / 'dumps'
ADB = r'C:\Users\94985\AppData\Local\Android\Sdk\platform-tools\adb.exe'

sig_count = 0
buf_count = 0


def on_message(message, data):
    global sig_count, buf_count
    if message['type'] != 'send':
        if message['type'] == 'error':
            print('[script-error]', message.get('description', '')[:200])
        return
    payload = message['payload']
    kind = payload['kind']
    d = payload.get('data', {})
    if kind == 'SIG':
        sig_count += 1
        with open(HERE / 'samples.jsonl', 'a', encoding='utf-8') as f:
            f.write(json.dumps(d, ensure_ascii=False) + '\n')
        print(f'[SIG #{d["sigId"]}] {d["url"][:90]}... 头数={len(d["headers"])}')
    elif kind == 'BUF':
        buf_count += 1
        sig = d['sigId']
        outdir = DUMPS / f'sig_{sig:04d}'
        outdir.mkdir(parents=True, exist_ok=True)
        name = f'{d["why"]}_{d["addr"]}_{d["size"]}{"_devid" if d["devIdHit"] else ""}.bin'
        (outdir / name).write_bytes(data)
    elif kind == 'OK':
        print('[hook-ok]', d)
    elif kind == 'ERR':
        print('[hook-err]', d)


def adb(*args):
    subprocess.run([ADB, *args], capture_output=True, timeout=30)


def main():
    (HERE / 'samples.jsonl').unlink(missing_ok=True)
    device = frida.get_usb_device(timeout=10)
    print('设备:', device.name)
    pid = device.spawn(['com.dragon.read'])
    session = device.attach(pid)
    script = session.create_script(open(HERE / 'stage1_capture.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    print('App 已拉起, 等冷启动+自动请求 60s ...')
    time.sleep(60)

    print('monkey 驱动随机流量 ...')
    adb('shell', 'monkey', '-p', 'com.dragon.read', '--throttle', '1200', '--pct-syskeys', '0', '50')
    time.sleep(30)

    print('模拟下拉刷新/翻页 ...')
    for _ in range(4):
        adb('shell', 'input', 'swipe', '540', '1200', '540', '400', '300')
        time.sleep(4)
    for _ in range(3):
        adb('shell', 'input', 'swipe', '540', '400', '540', '1200', '300')
        time.sleep(4)

    print(f'采集结束: SIG样本={sig_count} 缓冲区={buf_count}')
    session.detach()


if __name__ == '__main__':
    main()
