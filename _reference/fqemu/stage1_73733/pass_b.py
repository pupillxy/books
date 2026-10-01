# -*- coding: utf-8 -*-
"""Pass B: spawn + malloc跟踪, 抓 Medusa 明文候选缓冲区"""
import json
import subprocess
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
DUMPS = HERE / 'dumps_b'
ADB = r'C:\Users\94985\AppData\Local\Android\Sdk\platform-tools\adb.exe'
sig_count = 0
buf_count = 0


def adb_bg(*args):
    subprocess.Popen([ADB, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def on_message(message, data):
    global sig_count, buf_count
    if message['type'] != 'send':
        if message['type'] == 'error':
            print('[script-error]', str(message)[:160], flush=True)
        return
    p = message['payload']
    if p['kind'] == 'SIG':
        sig_count += 1
        with open(HERE / 'samples_b.jsonl', 'a', encoding='utf-8') as f:
            f.write(json.dumps(p['data'], ensure_ascii=False) + '\n')
        print(f'SIG #{p["data"]["sigId"]} buf={buf_count}', flush=True)
    elif p['kind'] == 'BUF':
        if data is None or len(data) == 0:
            return
        buf_count += 1
        d = p['data']
        outdir = DUMPS / f'sig_{d["sigId"]:03d}'
        outdir.mkdir(parents=True, exist_ok=True)
        tag = ('D' if d['devid'] else '') + ('C' if d['cdid'] else '') + f'{d["size"]}'
        (outdir / f'{d["why"]}_{d["addr"]}_{tag}.bin').write_bytes(data)
    elif p['kind'] == 'OK':
        print('[hook-ok]', p['data'], flush=True)
    elif p['kind'] == 'ERR':
        print('[hook-err]', p['data'], flush=True)


def main():
    DUMPS.mkdir(exist_ok=True)
    device = frida.get_usb_device(timeout=10)
    print('spawn ...', flush=True)
    pid = device.spawn(['com.dragon.read'])
    session = device.attach(pid)
    script = session.create_script(open(HERE / 'pass_b.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    print('resumed', flush=True)

    t0 = time.time()
    last = 0
    while time.time() - t0 < 240:
        time.sleep(8)
        print(f'  t={int(time.time()-t0)}s sig={sig_count} buf={buf_count}', flush=True)
        if sig_count - last == 0 and time.time() - t0 > 60:
            adb_bg('shell', 'input', 'swipe', '540', '1100', '540', '500', '250')
            adb_bg('shell', 'input', 'swipe', '540', '500', '540', '1100', '250')
        if sig_count >= 25:
            break
        last = sig_count
    print(f'Pass B 完成: SIG={sig_count} BUF={buf_count}', flush=True)


if __name__ == '__main__':
    main()
