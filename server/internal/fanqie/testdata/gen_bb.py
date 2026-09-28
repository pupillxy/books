"""拦截 rc4 输入，导出 Python 版 bb 明文字节流用于 Go 对照"""
import random
import sys

sys.path.insert(0, r'd:\dev\xiaoshuo\_reference\fanqie-rank-mcp')
random.seed(42)
import a_bogus as _ab


class _FakeTime:
    @staticmethod
    def time():
        return 1735286400.0


_ab.time = _FakeTime

captured = []
_orig_rc4 = _ab.rc4_encrypt


def _spy(plaintext, key):
    captured.append((plaintext.hex(), key.hex()))
    return _orig_rc4(plaintext, key)


_ab.rc4_encrypt = _spy

UA = "Dalvik/2.1.0 (Linux; U; Android 10; SM-G975F Build/QP1A) com.ss.android.article.news/831"
QUERY = "app_id=2503&rank_list_type=3&offset=0&limit=20&category_id=257&rank_version=&gender=1&rankMold=2"

random.seed(42)
print("a_bogus =", _ab.generate_a_bogus(QUERY, UA))
# 第一次 rc4: UA；第二次 rc4: bb_utf8（即 pyReplaceDecode(bb) 的结果）
bb_utf8_hex = captured[1][0]
print("bb_utf8_len =", len(bb_utf8_hex) // 2)
print("bb_utf8 =", bb_utf8_hex)
