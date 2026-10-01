# -*- coding: utf-8 -*-
"""Pass C: 扫描法抓明文候选窗口"""
import json
import subprocess
import time
from pathlib import Path

import frida

HERE = Path(__file__).parent
DUMPS = HERE / 'dumps_c'
ADB = r'C:\Users\94985\AppData\Local\Android\Sdk\platform-tools\adb.exe'
hit_count = 0
sig_count = 0


def adb_bg(*args):
    subprocess.Popen([ADB, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def on_message(message, data):
    global hit_count, sig_count
    if message['type'] != 'send':
        return
    p = message['payload']
    k = p['kind']
    d = p['data']
    if k == 'SIG':
        sig_count += 1
        with open(HERE / 'samples_c.jsonl', 'a', encoding='utf-8') as f:
            f.write(json.dumps(d, ensure_ascii=False) + '\n')
        print(f'SIG #{d["sigId"]}', flush=True)
    elif k == 'HIT':
        hit_count += 1
        outdir = DUMPS / f'sig_{d["sigId"]:03d}'
        outdir.mkdir(parents=True, exist_ok=True)
        (outdir / f'{d["needle"]}_{d["addr"]}_{d["span"]}.bin').write_bytes(data)
    elif k == 'SCANDONE':
        print(f'  scan sig#{d["sigId"]}: hits={d["hits"]}/{d["ranges"]}ranges 总计{hit_count}', flush=True)
    elif k == 'OK':
        print('[hook-ok]', d, flush=True)
    elif k == 'ERR':
        print('[hook-err]', d, flush=True)


def main():
    DUMPS.mkdir(exist_ok=True)
    device = frida.get_usb_device(timeout=10)
    print('spawn ...', flush=True)
    pid = device.spawn(['com.dragon.read'])
    session = device.attach(pid)
    script = session.create_script(open(HERE / 'pass_c.js', encoding='utf-8').read())
    script.on('message', on_message)
    script.load()
    device.resume(pid)
    t0 = time.time()
    last = 0
    while time.time() - t0 < 300:
        time.sleep(10)
        print(f'  t={int(time.time()-t0)}s sig={sig_count} hits={hit_count}', flush=True)
        if sig_count - last == 0 and time.time() - t0 > 80:
            adb_bg('shell', 'input', 'swipe', '540', '1100', '540', '500', '250')
        if sig_count >= 12:
            break
        last = sig_count
    print(f'Pass C 完成: SIG={sig_count} HIT={hit_count}', flush=True)


if __name__ == '__main__':
    main()
