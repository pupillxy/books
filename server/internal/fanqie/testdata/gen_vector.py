"""生成 a_bogus 对照向量：固定随机种子，输出 Python 参考实现的签名结果"""
import random
import sys

sys.path.insert(0, r'd:\dev\xiaoshuo\_reference\fanqie-rank-mcp')

random.seed(42)
import a_bogus as _ab


class _FakeTime:
    @staticmethod
    def time():
        return 1735286400.0  # 整秒，浮点精确，int(*1000) 无截断误差


_ab.time = _FakeTime
from a_bogus import SM3, rc4_encrypt, result_encrypt, _generate_random_str, generate_a_bogus

UA = "Dalvik/2.1.0 (Linux; U; Android 10; SM-G975F Build/QP1A) com.ss.android.article.news/831"
QUERY = "app_id=2503&rank_list_type=3&offset=0&limit=20&category_id=257&rank_version=&gender=1&rankMold=2"

rs = _generate_random_str()
random.seed(42)  # 复位后 generate 内部生成的随机与 rs 相同

MS = int(1735286400.0 * 1000) & 0xFFFFFFFF
print("random_str =", rs.hex())
print("start_ms =", MS)
print("sm3_abc =", SM3().sum_hex("abc"))
print("rc4_s0 =", result_encrypt(rc4_encrypt(b"Plaintext", b"Key"), "s0"))
print("a_bogus =", generate_a_bogus(QUERY, UA))
