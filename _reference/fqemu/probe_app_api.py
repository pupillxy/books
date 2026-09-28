"""番茄 App 协议探测：设备注册 + X-Gorgon(红果同款算法) 打 /reading/bookapi/search/tab/v
临时脚本，不属于项目代码。目的：验证是否老版本/海版 UA 可免 X-Helios/Medusa。"""
import hashlib
import json
import struct
import time
import urllib.request
import uuid

BASE = "https://api5-normal-sinfonlinec.fqnovel.com"
UA_71332 = "com.dragon.read/71332 (Linux; U; Android 15; zh_CN; sdk_gphone64_arm64; Build/AP3A.241105.008;tt-ok/3.12.13.20)"
UA_OVERSEA = "com.dragon.read.oversea.gp/68132 (Linux; U; Android 10; zh_CN; OnePlus11; Build/V291IR;tt-ok/3.12.13.4-tiktok)"

CDID = str(uuid.uuid4())
OPENUDID = uuid.uuid4().hex[:16]


def md5(b: bytes) -> bytes:
    return hashlib.md5(b).digest()


def reverse8(x: int) -> int:
    return int(f"{x:08b}"[::-1], 2)


def sign_gorgon(query: str, body: bytes | None, ts: int):
    payload = bytearray(20)
    payload[0:4] = md5(query.encode())[:4]
    if body:
        payload[4:8] = md5(body)[:4]
    payload[12:16] = bytes([0, 6, 11, 28])
    struct.pack_into(">I", payload, 16, ts & 0xFFFFFFFF)
    key = bytes([0x44, 0xB9, 0xB9, 0xD9, 0xA4, 0xAE, 0xF9, 0xFC, 0xA4, 0x93,
                 0xAA, 0x75, 0x7C, 0xA3, 0xC2, 0xC4, 0xA4, 0x96, 0x93, 0x8F])
    for i in range(20):
        payload[i] ^= key[i]
    for i in range(20):
        mixed = ((payload[i] << 4 | payload[i] >> 4) & 0xFF) ^ payload[(i + 1) % 20]
        payload[i] = reverse8(mixed) ^ 0xFF ^ 20
    sig = bytes([0x84, 0x04, 0x40, 0x1C, 0, 0]) + bytes(payload)
    return sig.hex(), str(ts)


def http(url: str, data=None, headers=None, timeout=15):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def register_device(ver_code: int, ver_name: str) -> tuple[str, str]:
    body = json.dumps({
        "magic_tag": "ss_app_log",
        "header": {
            "display_name": "novelapp",
            "update_version_code": ver_code, "manifest_version_code": ver_code,
            "aid": 1967, "channel": "googleplay", "package": "com.dragon.read",
            "app_name": "novelapp", "version_code": ver_code, "version_name": ver_name,
            "device_model": "sdk_gphone64_arm64", "device_brand": "google",
            "device_manufacturer": "Google", "os_version": "15", "os_api": 35,
            "device_platform": "android", "language": "zh", "region": "CN",
            "resolution": "1080x2160", "dpi": 420,
            "rom_version": "PQ3B.190801.002",
            "cdid": CDID, "openudid": OPENUDID,
        },
        "_gen_time": int(time.time()),
    }).encode()
    for host in ("https://log.snssdk.com/service/2/device_register/",
                 "https://log.isnssdk.com/service/2/device_register/"):
        try:
            raw = http(host, data=body, headers={"Content-Type": "application/json",
                                                 "User-Agent": UA_71332})
            v = json.loads(raw)
            did = str(v.get("device_id_str") or v.get("device_id") or "")
            iid = str(v.get("install_id_str") or v.get("install_id") or "")
            if did and did != "0":
                print(f"[注册] device_id={did} install_id={iid}")
                return did, iid
            print(f"[注册] {host} 返回: {str(v)[:200]}")
        except Exception as e:  # noqa: BLE001
            print(f"[注册] {host} 失败: {e}")
    return "", ""


def common_query(did: str, iid: str, ver_code: int, ver_name: str, app_name="novelapp") -> str:
    ts = int(time.time() * 1000)
    pairs = [
        ("ac", "wifi"), ("aid", "1967"), ("app_name", app_name),
        ("version_code", str(ver_code)), ("version_name", ver_name),
        ("device_platform", "android"), ("os", "android"), ("ssmix", "a"),
        ("device_type", "sdk_gphone64_arm64"), ("device_brand", "google"),
        ("os_api", "35"), ("os_version", "15"),
        ("device_id", did), ("iid", iid), ("_rticket", str(ts)),
        ("cdid", CDID), ("openudid", OPENUDID),
    ]
    import urllib.parse
    return "&".join(f"{k}={urllib.parse.quote(str(v), safe='')}" for k, v in pairs)


def try_search(did, iid, ver_code, ver_name, ua, label, sign=True):
    q = common_query(did, iid, ver_code, ver_name) + "&" + "&".join([
        "query=%E5%89%91%E6%9D%A5", "offset=0", "count=5", "search_source=1",
        "is_first_enter_search=true", "use_correct=false", "from_rs=false",
        "only_feed=false", "only_large_card=false", "from_half_screen=false",
    ])
    url = f"{BASE}/reading/bookapi/search/tab/v?{q}"
    now = int(time.time())
    headers = {
        "User-Agent": ua,
        "Accept": "application/json",
        "Sdk-Version": "2",
        "lc": "101",
        "X-SS-REQ-TICKET": str(int(time.time() * 1000)),
    }
    if sign:
        g, k = sign_gorgon(q, None, now)
        headers["X-Gorgon"] = g
        headers["X-Khronos"] = k
        headers["X-XS-From-Web"] = "0"
    try:
        raw = http(url, headers=headers)
        v = json.loads(raw)
        code = v.get("code")
        data = v.get("data") or {}
        cells = data.get("data") or []
        n = 0
        first = ""
        for cell in cells:
            for b in cell.get("book_data") or []:
                n += 1
                if not first:
                    first = b.get("book_name") or ""
        print(f"[{label}] code={code} books={n} 首本={first!r} msg={str(v.get('message'))[:40]}")
    except Exception as e:  # noqa: BLE001
        msg = ""
        try:
            msg = e.read().decode("utf-8", "replace")[:120]  # type: ignore[union-attr]
        except Exception:  # noqa: BLE001
            pass
        print(f"[{label}] 异常: {type(e).__name__} {e} {msg}")


DID, IID = register_device(71332, "7.1.3.32")
if not DID:
    print("设备注册失败，终止")
    raise SystemExit(1)

print()
try_search(DID, IID, 71332, "7.1.3.32", UA_71332, "v7.13.32+Gorgon")
time.sleep(1)
try_search(DID, IID, 71332, "7.1.3.32", UA_71332, "v7.13.32无签名", sign=False)
time.sleep(1)
try_search(DID, IID, 70532, "7.0.5.32", UA_71332.replace("/71332", "/70532").replace("7.1.3.32", "7.0.5.32"),
           "v7.05.32+Gorgon")
time.sleep(1)
try_search(DID, IID, 69932, "6.9.9.32", UA_71332.replace("/71332", "/69932").replace("7.1.3.32", "6.9.9.32"),
           "v6.99.32+Gorgon")
time.sleep(1)
try_search(DID, IID, 68132, "6.8.1.32", UA_OVERSEA, "海版68132+Gorgon")
