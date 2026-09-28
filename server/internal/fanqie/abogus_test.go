package fanqie

import (
	"encoding/hex"
	"testing"
)

// 对照向量由 testdata/gen_vector.py 生成（Python 参考实现，固定随机种子 + 固定时间戳）
const (
	vecRandomStr = "ab520d38ab500000ab140f00"
	vecStartMS   = 119612416
	vecQuery     = "app_id=2503&rank_list_type=3&offset=0&limit=20&category_id=257&rank_version=&gender=1&rankMold=2"
	vecUA        = "Dalvik/2.1.0 (Linux; U; Android 10; SM-G975F Build/QP1A) com.ss.android.article.news/831"
	vecSM3ABC    = "5f99119d900874d41965297e112f4220cb48bce3e6dd58c99ecad05ca824f09d"
	vecRC4S0     = "u/MW6NlArwrT"
	vecABogus    = "O7m0/QzfDDdPhDSD5R/LfY3q6UTIZ618xuvKEPJAUftctyf4RylZvtnYw7zvMY8rgT6JITSjyThsLDPnus5D0pkV9YJwW2qBm6RdSaP/5IUj53ijejumE0DF-vzWt-Bd5id3Ech/ovKrKmG0AocJ5vI5OfOja3Lk96EtrNqL2o/X="
)

func TestSM3Vector(t *testing.T) {
	got := hexLower(newSM3().sumBytes("abc", nil))
	if got != vecSM3ABC {
		t.Fatalf("sm3 mismatch:\n got %s\nwant %s", got, vecSM3ABC)
	}
}

func TestRC4Vector(t *testing.T) {
	got := resultEncrypt(rc4([]byte("Plaintext"), []byte("Key")), "s0")
	if got != vecRC4S0 {
		t.Fatalf("rc4+s0 mismatch:\n got %s\nwant %s", got, vecRC4S0)
	}
}

func TestABogusVector(t *testing.T) {
	rs, err := hex.DecodeString(vecRandomStr)
	if err != nil {
		t.Fatal(err)
	}
	var rsArr [12]byte
	copy(rsArr[:], rs)
	got := buildABogus(vecQuery, vecUA, vecStartMS, vecStartMS, rsArr)
	if got != vecABogus {
		t.Fatalf("a_bogus mismatch:\n got %s\nwant %s", got, vecABogus)
	}
}
