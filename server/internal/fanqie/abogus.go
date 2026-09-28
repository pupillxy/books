package fanqie

// a_bogus 反爬签名生成器 —— 移植自 _reference/fanqie-rank-mcp/a_bogus.py
// 注意：此 SM3 为字节系 JS 客户端的非标准变体（TT1 直接用 SS1，未异或 ROTL(A,12)），
// 不能替换成标准国密库，否则签名失效。

import (
	"crypto/rand"
	"encoding/binary"
	"strings"
	"time"
)

// ─── RC4 流密码 ───────────────────────────────────────────────────────

func rc4(plaintext, key []byte) []byte {
	s := make([]int, 256)
	for i := range s {
		s[i] = i
	}
	j := 0
	for i := 0; i < 256; i++ {
		j = (j + s[i] + int(key[i%len(key)])) & 0xFF
		s[i], s[j] = s[j], s[i]
	}
	ii, jj := 0, 0
	out := make([]byte, len(plaintext))
	for n, b := range plaintext {
		ii = (ii + 1) & 0xFF
		jj = (jj + s[ii]) & 0xFF
		s[ii], s[jj] = s[jj], s[ii]
		out[n] = byte(s[(s[ii]+s[jj])&0xFF]) ^ b
	}
	return out
}

// ─── SM3（非标准变体，照抄 Python 实现）────────────────────────────────

func rotl32(x uint32, n int) uint32 {
	n %= 32
	return x<<n | x>>(32-n)
}

func sm3FFj(j int, x, y, z uint32) uint32 {
	if j < 16 {
		return x ^ y ^ z
	}
	return (x & y) | (x & z) | (y & z)
}

func sm3GGj(j int, x, y, z uint32) uint32 {
	if j < 16 {
		return x ^ y ^ z
	}
	return (x & y) | (^x & z)
}

func sm3Tj(j int) uint32 {
	if j < 16 {
		return 0x79CC4519
	}
	return 0x7A879D8A
}

func sm3P0(x uint32) uint32 { return x ^ rotl32(x, 9) ^ rotl32(x, 17) }
func sm3P1(x uint32) uint32 { return x ^ rotl32(x, 15) ^ rotl32(x, 23) }

func sm3Compress(reg *[8]uint32, block []byte) {
	w := make([]uint32, 132)
	for i := 0; i < 16; i++ {
		w[i] = binary.BigEndian.Uint32(block[4*i:])
	}
	for n := 16; n < 68; n++ {
		a := w[n-16] ^ w[n-9] ^ rotl32(w[n-3], 15)
		a = a ^ rotl32(a, 15) ^ rotl32(a, 23)
		w[n] = a ^ rotl32(w[n-13], 7) ^ w[n-6]
	}
	for n := 0; n < 64; n++ {
		w[n+68] = w[n] ^ w[n+4]
	}
	v := *reg
	for c := 0; c < 64; c++ {
		ss1 := (rotl32(v[0], 12) + v[4] + rotl32(sm3Tj(c), c))
		ss1 = rotl32(ss1, 7) ^ rotl32(v[0], 12)
		tt1 := sm3FFj(c, v[0], v[1], v[2]) + v[3] + ss1 + w[c+68]
		tt2 := sm3GGj(c, v[4], v[5], v[6]) + v[7] + (ss1 + rotl32(v[0], 12)) + w[c]
		v[3] = v[2]
		v[2] = rotl32(v[1], 9)
		v[1] = v[0]
		v[0] = tt1
		v[7] = v[6]
		v[6] = rotl32(v[5], 19)
		v[5] = v[4]
		v[4] = sm3P0(tt2)
	}
	for i := 0; i < 8; i++ {
		reg[i] ^= v[i]
	}
}

var sm3IV = [8]uint32{
	0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
	0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
}

type sm3 struct {
	reg   [8]uint32
	chunk []byte
	size  int
}

func newSM3() *sm3 {
	s := &sm3{}
	s.reset()
	return s
}

func (s *sm3) reset() {
	s.reg = sm3IV
	s.chunk = s.chunk[:0]
	s.size = 0
}

// urlEncodeBytes 复刻 Python _url_encode_bytes：保留字母数字与 " -_.~"（含空格），大写 hex
func urlEncodeBytes(s string) []byte {
	const hexChars = "0123456789ABCDEF"
	var out []byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
			c == ' ' || c == '-' || c == '_' || c == '.' || c == '~' {
			out = append(out, c)
		} else {
			out = append(out, '%', hexChars[c>>4], hexChars[c&0x0F])
		}
	}
	return out
}

func (s *sm3) writeBytes(data []byte) {
	s.size += len(data)
	if len(s.chunk)+len(data) < 64 {
		s.chunk = append(s.chunk, data...)
		return
	}
	fill := 64 - len(s.chunk)
	s.chunk = append(s.chunk, data[:fill]...)
	var block [64]byte
	copy(block[:], s.chunk)
	sm3Compress(&s.reg, block[:])
	s.chunk = s.chunk[:0]

	offset := fill
	for offset+64 <= len(data) {
		sm3Compress(&s.reg, data[offset:offset+64])
		offset += 64
	}
	if offset < len(data) {
		s.chunk = append(s.chunk, data[offset:]...)
	}
}

func (s *sm3) writeStr(str string) { s.writeBytes(urlEncodeBytes(str)) }

// sumBytes 复刻 Python sum_bytes / sum_bytes_from_bytes（输入先 URL 编码，除非 rawBytes）
func (s *sm3) sumBytes(input string, rawBytes []byte) []byte {
	s.reset()
	if rawBytes != nil {
		s.writeBytes(rawBytes)
	} else {
		s.writeStr(input)
	}
	// SM3 填充
	bitLen := uint64(8 * s.size)
	s.chunk = append(s.chunk, 0x80)
	for len(s.chunk)%64 < 56 {
		s.chunk = append(s.chunk, 0)
	}
	var lenBytes [8]byte
	binary.BigEndian.PutUint64(lenBytes[:], bitLen)
	s.chunk = append(s.chunk, lenBytes[:]...)
	for i := 0; i+64 <= len(s.chunk); i += 64 {
		sm3Compress(&s.reg, s.chunk[i:i+64])
	}
	out := make([]byte, 32)
	for i, r := range s.reg {
		binary.BigEndian.PutUint32(out[4*i:], r)
	}
	s.reset()
	return out
}

// ─── 自定义 Base64 ────────────────────────────────────────────────────

var encodeTables = map[string]string{
	"s0": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=",
	"s3": "ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe",
	"s4": "Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe",
}

func resultEncrypt(data []byte, tableName string) string {
	table := encodeTables[tableName]
	var sb strings.Builder
	for r := 0; r+3 <= len(data); r += 3 {
		li := uint32(data[r])<<16 | uint32(data[r+1])<<8 | uint32(data[r+2])
		sb.WriteByte(table[(li>>18)&63])
		sb.WriteByte(table[(li>>12)&63])
		sb.WriteByte(table[(li>>6)&63])
		sb.WriteByte(table[li&63])
	}
	return sb.String()
}

// ─── 签名主流程 ───────────────────────────────────────────────────────

const windowEnvStr = "1536|747|1536|834|0|30|0|0|1536|834|1536|864|1525|747|24|24|Win32"

// pyReplaceDecode 复刻 CPython bytes.decode('utf-8', errors='replace')：
// 序列校验失败时，消耗"首字节+已匹配的合法 continuation"整体替换为 1 个 U+FFFD
func pyReplaceDecode(b []byte) []byte {
	const repl = "\xEF\xBF\xBD"
	var out []byte
	i := 0
	for i < len(b) {
		c := b[i]
		if c < 0x80 {
			out = append(out, c)
			i++
			continue
		}
		var seqLen int
		var lo2, hi2 byte // 首字节合法时第二字节的范围（CPython accept 表）
		switch {
		case c >= 0xC2 && c < 0xE0:
			seqLen, lo2, hi2 = 2, 0x80, 0xBF
		case c >= 0xE0 && c < 0xF0:
			seqLen = 3
			switch c {
			case 0xE0:
				lo2, hi2 = 0xA0, 0xBF
			case 0xED:
				lo2, hi2 = 0x80, 0x9F
			default:
				lo2, hi2 = 0x80, 0xBF
			}
		case c >= 0xF0 && c < 0xF5:
			seqLen = 4
			switch c {
			case 0xF0:
				lo2, hi2 = 0x90, 0xBF
			case 0xF4:
				lo2, hi2 = 0x80, 0x8F
			default:
				lo2, hi2 = 0x80, 0xBF
			}
		default: // 0x80-0xC1（含 overlong 首字节）、0xF5-0xFF
			out = append(out, repl...)
			i++
			continue
		}
		k := 1
		valid := true
		for k < seqLen {
			if i+k >= len(b) { // 截断
				valid = false
				break
			}
			nb := b[i+k]
			lo, hi := byte(0x80), byte(0xBF)
			if k == 1 {
				lo, hi = lo2, hi2
			}
			if nb < lo || nb > hi {
				valid = false
				break
			}
			k++
		}
		if !valid {
			out = append(out, repl...)
			i += k // 消耗已匹配前缀
			continue
		}
		out = append(out, b[i:i+seqLen]...)
		i += seqLen
	}
	return out
}

func generateRC4BBStr(urlSearchParams, userAgent string, startMS, endMS uint32) []byte {
	bb := buildBB(urlSearchParams, userAgent, startMS, endMS)
	return rc4(pyReplaceDecode(bb), []byte{121})
}

func buildBB(urlSearchParams, userAgent string, startMS, endMS uint32) []byte {
	h := newSM3()

	// URL 参数双重 SM3：hex(str) 再取 bytes(hex_str)
	urlHashHex := hexLower(h.sumBytes(urlSearchParams, nil))
	urlSearchParamsList := h.sumBytes(urlHashHex, []byte(urlHashHex))

	cusHashHex := hexLower(h.sumBytes("cus", nil))
	cusList := h.sumBytes(cusHashHex, []byte(cusHashHex))

	// RC4 加密 UA + 自定义 base64 + SM3（原始字节输入）
	rc4Key := []byte{0x01, 0x00, 0x0E}
	uaEnc := rc4([]byte(userAgent), rc4Key)
	uaB64 := resultEncrypt(uaEnc, "s3")
	uaList := h.sumBytes("", []byte(uaB64))

	// b 字典
	b := make([]int, 73)
	b[8] = 3
	b[10] = int(endMS)
	b[16] = int(startMS)
	b[18] = 44

	b[20] = (b[16] >> 24) & 0xFF
	b[21] = (b[16] >> 16) & 0xFF
	b[22] = (b[16] >> 8) & 0xFF
	b[23] = b[16] & 0xFF

	b[26], b[27], b[28], b[29] = 0, 0, 0, 0
	b[30], b[31], b[32], b[33], b[34], b[35], b[36], b[37] = 0, 1, 0, 0, 0, 0, 0, 14

	b[38] = int(urlSearchParamsList[21])
	b[39] = int(urlSearchParamsList[22])
	b[40] = int(cusList[21])
	b[41] = int(cusList[22])
	b[42] = int(uaList[23])
	b[43] = int(uaList[24])

	b[44] = (b[10] >> 24) & 0xFF
	b[45] = (b[10] >> 16) & 0xFF
	b[46] = (b[10] >> 8) & 0xFF
	b[47] = b[10] & 0xFF
	b[48] = b[8]

	const pageID, aid = 6241, 6383
	b[51] = pageID
	b[52] = (pageID >> 24) & 0xFF
	b[53] = (pageID >> 16) & 0xFF
	b[54] = (pageID >> 8) & 0xFF
	b[55] = pageID & 0xFF
	b[56] = aid
	b[57] = aid & 0xFF
	b[58] = (aid >> 8) & 0xFF
	b[59] = (aid >> 16) & 0xFF
	b[60] = (aid >> 24) & 0xFF

	envLen := len(windowEnvStr)
	b[64] = envLen
	b[65] = envLen & 0xFF
	b[66] = (envLen >> 8) & 0xFF

	b[72] = b[18] ^ b[20] ^ b[26] ^ b[30] ^ b[38] ^ b[40] ^ b[42] ^
		b[21] ^ b[27] ^ b[31] ^ b[35] ^ b[39] ^ b[41] ^ b[43] ^
		b[22] ^ b[28] ^ b[32] ^ b[36] ^
		b[23] ^ b[29] ^ b[33] ^ b[37] ^
		b[44] ^ b[45] ^ b[46] ^ b[47] ^ b[48] ^ b[49] ^ b[50] ^
		b[24] ^ b[25] ^
		b[52] ^ b[53] ^ b[54] ^ b[55] ^
		b[57] ^ b[58] ^ b[59] ^ b[60] ^
		b[65] ^ b[66] ^
		b[70] ^ b[71]

	bbOrder := []int{
		18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31,
		35, 57, 39, 41, 43, 22, 28, 32, 60, 36, 23, 29, 33, 37, 44, 45,
		59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71,
	}

	bb := make([]byte, 0, len(bbOrder)+envLen+1)
	for _, idx := range bbOrder {
		bb = append(bb, byte(b[idx]&0xFF))
	}
	bb = append(bb, windowEnvStr...)
	bb = append(bb, byte(b[72]&0xFF))
	return bb
}

// rc4PlainForDebug 返回 RC4 加密前的 bb 明文（decode 后），仅测试用
func rc4PlainForDebug(urlSearchParams, userAgent string, startMS, endMS uint32) []byte {
	bb := buildBB(urlSearchParams, userAgent, startMS, endMS)
	return pyReplaceDecode(bb)
}

// GenerateABogus 生成 a_bogus 签名（query 不含 ?，需与实际请求 UA 一致）
func GenerateABogus(urlSearchParams, userAgent string) string {
	now := uint32(time.Now().UnixMilli())
	var rs [12]byte
	if _, err := rand.Read(rs[:]); err != nil {
		// 极端情况兜底：固定随机也有效，只是可预测
		rs = [12]byte{0xab, 0x52, 0x0d, 0x38, 0xab, 0x50, 0x00, 0x00, 0xab, 0x14, 0x0f, 0x00}
	}
	return buildABogus(urlSearchParams, userAgent, now, now, rs)
}

// buildABogus 支持注入随机数与时间戳（测试对照用）
func buildABogus(urlSearchParams, userAgent string, startMS, endMS uint32, randomStr [12]byte) string {
	rc4BB := generateRC4BBStr(urlSearchParams, userAgent, startMS, endMS)
	combined := make([]byte, 0, 12+len(rc4BB))
	combined = append(combined, randomStr[:]...)
	combined = append(combined, rc4BB...)
	return resultEncrypt(combined, "s4") + "="
}

func hexLower(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 0, len(b)*2)
	for _, c := range b {
		out = append(out, digits[c>>4], digits[c&0x0F])
	}
	return string(out)
}
