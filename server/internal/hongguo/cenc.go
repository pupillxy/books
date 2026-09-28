package hongguo

// CENC（'cenc' 方案，AES-128-CTR）渐进式 MP4 服务端解密。
// 红果部分直链是 CENC 加密的 HEVC/AAC（stsd 采样条目为 encv/enca，stbl 内带 senc），
// ExoPlayer/浏览器没有 DRM 会话无法播放。这里在服务端就地解密 mdat 中的样本，
// 并把采样条目四码还原为 frma 声明的原始编码（hvc1/mp4a）。
// 关键设计：不增删任何盒子（只改四码），moov 大小不变，stco 偏移无需修正。

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"errors"
	"fmt"
)

type mp4Box struct {
	typ  string
	off  int // 盒头起点
	hdr  int // 头长度（8 或 16）
	size int // 盒总大小
}

func (b mp4Box) end() int { return b.off + b.size }

func iterBoxes(data []byte, start, end int, fn func(mp4Box) bool) {
	off := start
	for off+8 <= end {
		size := int(binary.BigEndian.Uint32(data[off : off+4]))
		typ := string(data[off+4 : off+8])
		hdr := 8
		if size == 1 {
			if off+16 > end {
				return
			}
			size = int(binary.BigEndian.Uint64(data[off+8 : off+16]))
			hdr = 16
		} else if size == 0 {
			size = end - off
		}
		if size < hdr || off+size > end {
			return
		}
		if !fn(mp4Box{typ: typ, off: off, hdr: hdr, size: size}) {
			return
		}
		off += size
	}
}

// findBox 在 path 容器链下递归找第一个 want 盒
func findBox(data []byte, start, end int, want string, path map[string]bool) (mp4Box, bool) {
	var hit mp4Box
	var found bool
	iterBoxes(data, start, end, func(b mp4Box) bool {
		if b.typ == want {
			hit, found = b, true
			return false
		}
		if path[b.typ] {
			if inner, ok := findBox(data, b.off+b.hdr, b.end(), want, path); ok {
				hit, found = inner, true
				return false
			}
		}
		return true
	})
	return hit, found
}

type cencSubsample struct{ Clear, Protected int }

type cencTrack struct {
	entryOff   int    // stsd 采样条目盒偏移（encv/enca）
	entryTyp   string // encv / enca
	original   string // frma 原始四码
	defaultIV  int    // tenc default_IV_size（0 表示用常量 IV）
	constantIV []byte
	kid        string
	sizes      []uint32
	offsets    []uint64
	sencData   []byte // senc 载荷（sample_count 起始，不含 version/flags）
	sencFlags  uint32
}

// DecryptCENC 就地解密 CENC 加密的 MP4，返回解密后的副本。key 为 16 字节内容密钥。
func DecryptCENC(data []byte, key []byte) ([]byte, error) {
	if len(key) != aes.BlockSize {
		return nil, errors.New("CENC 内容密钥长度无效")
	}
	moov, ok := findBox(data, 0, len(data), "moov", nil)
	if !ok {
		return nil, errors.New("MP4 缺少 moov 盒")
	}
	out := make([]byte, len(data))
	copy(out, data)

	var tracks []cencTrack
	var parseErr error
	iterBoxes(out, moov.off+moov.hdr, moov.end(), func(b mp4Box) bool {
		if b.typ != "trak" {
			return true
		}
		tr, encrypted, err := parseCENCTrack(out, b)
		if err != nil {
			if encrypted { // 加密轨解析失败必须报错，避免产出半解密文件
				err = fmt.Errorf("trak 解析失败: %w", err)
				parseErr = err
			}
			return true
		}
		if encrypted {
			tracks = append(tracks, tr)
		}
		return true
	})
	if parseErr != nil {
		return nil, parseErr
	}
	if len(tracks) == 0 {
		return nil, errors.New("MP4 未发现加密采样条目")
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	for _, tr := range tracks {
		if err := decryptTrack(out, tr, block); err != nil {
			return nil, fmt.Errorf("%s 轨道解密失败: %w", tr.entryTyp, err)
		}
		// 采样条目四码还原：encv/enca -> frma 原始四码（原地改，尺寸不变）
		copy(out[tr.entryOff+4:tr.entryOff+8], tr.original)
	}
	return out, nil
}

// sampleEntryKids 返回采样条目（encv/enca）内子盒列表的起始偏移（相对条目盒 off）。
// 条目盒前段是定长字段而非盒序列：encv 为视觉字段 78 字节（8 头之后），enca 为音频字段。
func sampleEntryKids(data []byte, entry mp4Box) (int, error) {
	switch entry.typ {
	case "encv":
		return 86, nil // 8头 + reserved(6)+dataRef(2) + 视觉字段(70)
	case "enca":
		if entry.off+18 > entry.end() {
			return 0, errors.New("enca 条目过短")
		}
		switch v := int(binary.BigEndian.Uint16(data[entry.off+16 : entry.off+18])); v {
		case 0:
			return 36, nil // 8头 + reserved(6)+dataRef(2) + 音频字段(20)
		case 1:
			return 52, nil // v1 额外加 16 字节
		default:
			return 0, fmt.Errorf("enca version %d 暂不支持", v)
		}
	default:
		return 0, errors.New("未知采样条目类型")
	}
}

func parseCENCTrack(data []byte, trak mp4Box) (cencTrack, bool, error) {
	var tr cencTrack
	// stsd -> 第一个采样条目（version/flags(4) + entry_count(4) 之后）
	stsd, ok := findBox(data, trak.off+trak.hdr, trak.end(), "stsd", map[string]bool{"mdia": true, "minf": true, "stbl": true})
	if !ok || stsd.size < stsd.hdr+16 {
		return tr, false, errors.New("缺少 stsd")
	}
	entry := mp4Box{
		typ: string(data[stsd.off+stsd.hdr+12 : stsd.off+stsd.hdr+16]),
		off: stsd.off + stsd.hdr + 8, hdr: 8,
	}
	entry.size = int(binary.BigEndian.Uint32(data[entry.off:]))
	if entry.size == 1 {
		entry.size = int(binary.BigEndian.Uint64(data[entry.off+8:]))
		entry.hdr = 16
	}
	if entry.typ != "encv" && entry.typ != "enca" {
		return tr, false, errors.New("非加密采样条目") // 明文轨道直接跳过
	}
	tr.entryOff, tr.entryTyp = entry.off, entry.typ
	// 采样条目前段是定长字段（宽高/声道等），子盒列表要从其后开始扫
	kids, err := sampleEntryKids(data, entry)
	if err != nil {
		return tr, true, err
	}

	if frma, ok := findBox(data, entry.off+kids, entry.end(), "frma", map[string]bool{"sinf": true}); ok && frma.size >= frma.hdr+4 {
		tr.original = string(data[frma.off+frma.hdr : frma.off+frma.hdr+4])
	} else {
		return tr, true, errors.New("加密条目缺少 frma")
	}
	if schm, ok := findBox(data, entry.off+kids, entry.end(), "schm", map[string]bool{"sinf": true}); ok && schm.size >= schm.hdr+8 {
		if scheme := string(data[schm.off+schm.hdr+4 : schm.off+schm.hdr+8]); scheme != "cenc" {
			return tr, true, fmt.Errorf("不支持的加密方案 %s", scheme)
		}
	} else {
		return tr, true, errors.New("加密条目缺少 schm")
	}
	// tenc：FullBox（version/flags 之后 reserved 可能是 1~2 字节）：
	// 找 isEncrypted==1 且 default_IV_size ∈ {0,8,16} 的位置，其后是 KID(16)
	tenc, ok := findBox(data, entry.off+kids, entry.end(), "tenc", map[string]bool{"sinf": true, "schi": true})
	if !ok || tenc.size < tenc.hdr+4+3+16 {
		return tr, true, errors.New("加密条目缺少 tenc")
	}
	p := tenc.off + tenc.hdr
	q := -1
	for i := p + 4; i <= p+7 && i+2 <= tenc.end(); i++ {
		if data[i] == 1 && (data[i+1] == 0 || data[i+1] == 8 || data[i+1] == 16) {
			q = i
			break
		}
	}
	if q < 0 || q+18 > tenc.end() {
		return tr, true, errors.New("tenc 字段无法识别")
	}
	tr.defaultIV = int(data[q+1])
	tr.kid = string(data[q+2 : q+18])
	if tr.defaultIV == 0 {
		csize := int(data[q+18])
		if csize <= 0 || q+19+csize > tenc.end() {
			return tr, true, errors.New("tenc 常量 IV 无效")
		}
		tr.constantIV = data[q+19 : q+19+csize]
	}

	stbl, ok := findBox(data, trak.off+trak.hdr, trak.end(), "stbl", map[string]bool{"mdia": true, "minf": true})
	if !ok {
		return tr, true, errors.New("缺少 stbl")
	}
	// stsz：每样本大小
	stsz, ok := findBox(data, stbl.off+stbl.hdr, stbl.end(), "stsz", nil)
	if !ok || stsz.size < stsz.hdr+12 {
		return tr, true, errors.New("缺少 stsz")
	}
	p = stsz.off + stsz.hdr
	uniform, count := binary.BigEndian.Uint32(data[p+4:p+8]), int(binary.BigEndian.Uint32(data[p+8:p+12]))
	tr.sizes = make([]uint32, count)
	if uniform > 0 {
		for i := range tr.sizes {
			tr.sizes[i] = uniform
		}
	} else {
		if stsz.size < stsz.hdr+12+4*count {
			return tr, true, errors.New("stsz 数据不完整")
		}
		for i := 0; i < count; i++ {
			tr.sizes[i] = binary.BigEndian.Uint32(data[p+12+4*i:])
		}
	}
	// stsc + stco/co64 -> 每样本文件偏移
	tr.offsets = make([]uint64, count)
	if err := mapSampleOffsets(data, stbl, tr.sizes, tr.offsets); err != nil {
		return tr, true, err
	}
	// senc：优先 stbl 内直接嵌入（红果变体），否则 saio 指向
	// 载荷从 version/flags 之后切（含 sample_count 头），parseSenc 先读样本数再读条目
	if senc, ok := findBox(data, stbl.off+stbl.hdr, stbl.end(), "senc", nil); ok && senc.size >= senc.hdr+8 {
		tr.sencFlags = binary.BigEndian.Uint32(data[senc.off+senc.hdr:senc.off+senc.hdr+4]) & 0xFFFFFF
		tr.sencData = data[senc.off+senc.hdr+4 : senc.end()]
	} else if saio, ok := findBox(data, stbl.off+stbl.hdr, stbl.end(), "saio", nil); ok {
		pos := saio.off + saio.hdr + 4
		if saioFlags := binary.BigEndian.Uint32(data[saio.off+saio.hdr:saio.off+saio.hdr+4]) & 0xFFFFFF; saioFlags&1 != 0 {
			pos += 8 // aux_info_type + parameter
		}
		if saio.size < pos-saio.off+4 {
			return tr, true, errors.New("saio 数据不完整")
		}
		entryCount := int(binary.BigEndian.Uint32(data[pos:]))
		if entryCount < 1 {
			return tr, true, errors.New("saio 为空")
		}
		var fileOff uint64
		if data[saio.off+saio.hdr] == 0 { // version 0：32 位偏移
			fileOff = uint64(binary.BigEndian.Uint32(data[pos+4:]))
		} else {
			fileOff = binary.BigEndian.Uint64(data[pos+4:])
		}
		if fileOff+16 > uint64(len(data)) || string(data[fileOff+4:fileOff+8]) != "senc" {
			return tr, true, errors.New("saio 指向的不是 senc")
		}
		tr.sencFlags = binary.BigEndian.Uint32(data[fileOff+8:]) & 0xFFFFFF
		tr.sencData = data[fileOff+12:] // parseSenc 按样本数走，尾部多余数据不会读
	}
	return tr, true, nil
}

// mapSampleOffsets 按 stsc/stco 算出每一样本的文件偏移
func mapSampleOffsets(data []byte, stbl mp4Box, sizes []uint32, offsets []uint64) error {
	stsc, ok := findBox(data, stbl.off+stbl.hdr, stbl.end(), "stsc", nil)
	if !ok {
		return errors.New("缺少 stsc")
	}
	p := stsc.off + stsc.hdr + 4
	n := int(binary.BigEndian.Uint32(data[p:]))
	type run struct{ first, per int }
	runs := make([]run, 0, n)
	for i := 0; i < n; i++ {
		runs = append(runs, run{
			first: int(binary.BigEndian.Uint32(data[p+4+12*i:])),
			per:   int(binary.BigEndian.Uint32(data[p+8+12*i:])),
		})
	}
	var chunks []uint64
	if stco, ok := findBox(data, stbl.off+stbl.hdr, stbl.end(), "stco", nil); ok {
		p = stco.off + stco.hdr + 4
		n := int(binary.BigEndian.Uint32(data[p:]))
		chunks = make([]uint64, n)
		for i := 0; i < n; i++ {
			chunks[i] = uint64(binary.BigEndian.Uint32(data[p+4+4*i:]))
		}
	} else if co64, ok := findBox(data, stbl.off+stbl.hdr, stbl.end(), "co64", nil); ok {
		p = co64.off + co64.hdr + 4
		n := int(binary.BigEndian.Uint32(data[p:]))
		chunks = make([]uint64, n)
		for i := 0; i < n; i++ {
			chunks[i] = binary.BigEndian.Uint64(data[p+4+8*i:])
		}
	} else {
		return errors.New("缺少 stco/co64")
	}
	si := 0
	for i, r := range runs {
		last := len(chunks)
		if i+1 < len(runs) {
			last = runs[i+1].first - 1
		}
		if r.first < 1 || r.first > len(chunks) {
			return errors.New("stsc 块序号越界")
		}
		for ch := r.first; ch <= last && si < len(sizes); ch++ {
			off := chunks[ch-1]
			for k := 0; k < r.per && si < len(sizes); k++ {
				offsets[si] = off
				off += uint64(sizes[si])
				si++
			}
		}
	}
	if si != len(sizes) {
		return errors.New("样本数与 stco/stsc 不匹配")
	}
	return nil
}

// decryptTrack 按 senc 的每样本 IV（含可选 subsample）用 AES-CTR 解密样本数据
func decryptTrack(data []byte, tr cencTrack, block cipher.Block) error {
	var ivs [][]byte
	var subs [][]cencSubsample
	if tr.sencData != nil {
		var err error
		ivs, subs, err = parseSenc(tr, tr.sencData)
		if err != nil {
			return err
		}
		if len(ivs) != len(tr.sizes) {
			return fmt.Errorf("senc 样本数 %d 与 stsz %d 不一致", len(ivs), len(tr.sizes))
		}
	}
	for i, size := range tr.sizes {
		off := tr.offsets[i]
		if off+uint64(size) > uint64(len(data)) {
			return fmt.Errorf("样本 %d 偏移越界", i)
		}
		var iv [16]byte
		switch {
		case tr.defaultIV > 0 && i < len(ivs):
			copy(iv[:], ivs[i])
		case len(tr.constantIV) > 0:
			copy(iv[:], tr.constantIV)
		default:
			return errors.New("样本缺少 IV")
		}
		s := &ctrStream{block: block, counter: iv}
		if i < len(subs) && len(subs[i]) > 0 {
			pos := uint64(0)
			for _, ss := range subs[i] {
				pos += uint64(ss.Clear)
				protected := uint64(ss.Protected)
				if pos+protected > uint64(size) {
					protected = uint64(size) - pos
				}
				if protected > 0 {
					s.xorBytes(data[off+pos : off+pos+protected])
					pos += protected
				}
			}
		} else {
			s.xorBytes(data[off : off+uint64(size)])
		}
	}
	return nil
}

// parseSenc 解析 senc 载荷（sample_count 起）。default_IV_size==0 时样本不带 IV（用常量 IV）。
func parseSenc(tr cencTrack, payload []byte) ([][]byte, [][]cencSubsample, error) {
	if len(payload) < 4 {
		return nil, nil, errors.New("senc 数据不完整")
	}
	count := int(binary.BigEndian.Uint32(payload[0:4]))
	p := 4
	// 分配护栏：先校验样本数与数据量自洽，再分配（防误解析把 IV 字节当样本数导致 OOM）
	entryMin := tr.defaultIV
	if tr.sencFlags&2 != 0 {
		entryMin += 2
	}
	if entryMin > 0 && int64(count)*int64(entryMin) > int64(len(payload)-p) {
		return nil, nil, fmt.Errorf("senc 样本数 %d 与数据量 %d 不符", count, len(payload)-p)
	}
	ivsz := tr.defaultIV
	ivs := make([][]byte, 0, count)
	subs := make([][]cencSubsample, 0, count)
	for i := 0; i < count; i++ {
		if ivsz > 0 {
			if p+ivsz > len(payload) {
				return nil, nil, errors.New("senc IV 越界")
			}
			ivs = append(ivs, payload[p:p+ivsz])
			p += ivsz
		} else {
			ivs = append(ivs, nil)
		}
		if tr.sencFlags&2 != 0 {
			if p+2 > len(payload) {
				return nil, nil, errors.New("senc 子区间头越界")
			}
			n6 := int(binary.BigEndian.Uint16(payload[p:]))
			p += 2
			entries := make([]cencSubsample, 0, n6)
			for j := 0; j < n6; j++ {
				if p+6 > len(payload) {
					return nil, nil, errors.New("senc 子区间越界")
				}
				entries = append(entries, cencSubsample{
					Clear:     int(binary.BigEndian.Uint16(payload[p:])),
					Protected: int(binary.BigEndian.Uint32(payload[p+2:])),
				})
				p += 6
			}
			subs = append(subs, entries)
		} else {
			subs = append(subs, nil)
		}
	}
	return ivs, subs, nil
}

// ctrStream 手动 AES-CTR：计数器 128 位低 64 位大端 +1，密钥流跨 protected 区间连续消耗
type ctrStream struct {
	block   cipher.Block
	counter [16]byte
	stream  [16]byte
	pos     int // 当前密钥流块内已消耗字节
}

func (s *ctrStream) refill() {
	s.block.Encrypt(s.stream[:], s.counter[:])
	c := binary.BigEndian.Uint64(s.counter[8:])
	binary.BigEndian.PutUint64(s.counter[8:], c+1)
	s.pos = 0
}

func (s *ctrStream) xorBytes(b []byte) {
	for i := range b {
		if s.pos == 0 {
			s.refill()
		}
		b[i] ^= s.stream[s.pos]
		s.pos++
		if s.pos == 16 {
			s.pos = 0
		}
	}
}
