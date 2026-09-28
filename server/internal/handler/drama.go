package handler

// 短剧（红果）HTTP 接口：目录/搜索/详情/取流 + m3u8 重写代理
// stream/seg 为公开端点但带 HMAC 签名参数（时效 12h），防代理被滥用

import (
	"bytes"
	"container/list"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"xiaoshuo/internal/database"
	"xiaoshuo/internal/hongguo"
	"xiaoshuo/internal/middleware"
	"xiaoshuo/internal/model"
)

// maxDirect 单个媒体文件缓冲上限（单集短剧一般 5-10MB）
const maxDirect = 64 << 20

// cencCacheLimit 解密结果缓存总字节上限（约 12 集 1080p），LRU 淘汰
const cencCacheLimit = 128 << 20

// DramaHandler 短剧
type DramaHandler struct {
	HG       *hongguo.Client
	DB       *database.DBStore // 观看记录（可为 nil：不记录进度）
	Secret   string            // 复用 JWTSecret 作为代理 URL 签名密钥
	cenc     *cencCache
	covers   *coverGate // 封面代理闸门（singleflight/限速/负缓存/熔断）
	coverDir string     // 封面磁盘缓存目录
}

// cencCache 解密后整集 MP4 的 LRU 缓存：命中省去整集重下+解密（seek/回看瞬时响应）
type cencCache struct {
	mu      sync.Mutex
	entries map[string]*list.Element // key(源站URL) -> element(*cencEntry)
	order   *list.List               // Front=最旧，Back=最新
	bytes   int
}

type cencEntry struct {
	key  string
	data []byte
}

func newCENCCache() *cencCache {
	return &cencCache{entries: map[string]*list.Element{}, order: list.New()}
}

func (cc *cencCache) get(key string) []byte {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	if el, ok := cc.entries[key]; ok {
		cc.order.MoveToBack(el)
		return el.Value.(*cencEntry).data
	}
	return nil
}

func (cc *cencCache) put(key string, data []byte) {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	if el, ok := cc.entries[key]; ok {
		e := el.Value.(*cencEntry)
		cc.bytes += len(data) - len(e.data)
		e.data = data
		cc.order.MoveToBack(el)
	} else {
		cc.entries[key] = cc.order.PushBack(&cencEntry{key: key, data: data})
		cc.bytes += len(data)
	}
	for cc.bytes > cencCacheLimit && cc.order.Len() > 0 {
		el := cc.order.Front()
		e := el.Value.(*cencEntry)
		cc.order.Remove(el)
		delete(cc.entries, e.key)
		cc.bytes -= len(e.data)
	}
}

const proxyTTL = 12 * time.Hour

// NewDramaHandler 构造短剧 handler（含解密结果 LRU 缓存 + 封面代理闸门）
func NewDramaHandler(hg *hongguo.Client, store *database.DBStore, secret string) *DramaHandler {
	return &DramaHandler{HG: hg, DB: store, Secret: secret, cenc: newCENCCache(),
		covers: newCoverGate(), coverDir: coverDirDefault()}
}

// SaveProgress 上报观看进度（切集时 App 调用，幂等 upsert）
func (h *DramaHandler) SaveProgress(c *gin.Context) {
	if h.DB == nil {
		c.JSON(http.StatusOK, gin.H{"ok": false})
		return
	}
	var req struct {
		SID      string `json:"sid" binding:"required"`
		Title    string `json:"title"`
		Cover    string `json:"cover"`
		TotalEps int    `json:"total_eps"`
		EpIndex  int    `json:"ep_index"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if err := h.DB.UpsertDramaProgress(middleware.UserID(c), req.SID, req.Title, req.Cover, req.TotalEps, req.EpIndex); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存进度失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// GetProgress 查询某部剧的观看集数（无记录返回 ep_index=0）
func (h *DramaHandler) GetProgress(c *gin.Context) {
	if h.DB == nil {
		c.JSON(http.StatusOK, gin.H{"ep_index": 0})
		return
	}
	ep, err := h.DB.GetDramaProgress(middleware.UserID(c), c.Param("sid"))
	if err != nil && err != database.ErrNotFound {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ep_index": ep})
}

// History 观看记录列表（最近在前）
func (h *DramaHandler) History(c *gin.Context) {
	if h.DB == nil {
		c.JSON(http.StatusOK, gin.H{"items": []any{}})
		return
	}
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "100"))
	items, err := h.DB.ListDramaHistory(middleware.UserID(c), limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if items == nil {
		items = []*model.DramaHistoryItem{} // 保持空数组而非 null，前端好处理
	}
	for i := range items { // 封面统一走代理（老记录的原始 URL 现签，绝对代理链接续签）
		items[i].Cover = h.coverLink(items[i].Cover)
	}
	c.JSON(http.StatusOK, gin.H{"items": items})
}

// DeleteHistory 删除一条观看记录
func (h *DramaHandler) DeleteHistory(c *gin.Context) {
	if h.DB == nil {
		c.JSON(http.StatusOK, gin.H{"ok": true})
		return
	}
	if err := h.DB.DeleteDramaHistory(middleware.UserID(c), c.Param("sid")); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// Genres 分类列表
func (h *DramaHandler) Genres(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"items": hongguo.Genres()})
}

// Catalog 目录（分页）；tag 为二级筛选（格式 dim|id，可选）
func (h *DramaHandler) Catalog(c *gin.Context) {
	genre := c.Query("genre")
	tag := c.Query("tag")
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if offset < 0 {
		offset = 0
	}
	page, err := h.HG.Catalog(c.Request.Context(), genre, tag, offset)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
		return
	}
	for i := range page.Items { // 封面改走本服务代理（磁盘缓存+限速，避免直连上游触发风控）
		page.Items[i].Cover = h.signCover(page.Items[i].Cover)
	}
	c.JSON(http.StatusOK, page)
}

// Search 搜索
func (h *DramaHandler) Search(c *gin.Context) {
	kw := strings.TrimSpace(c.Query("kw"))
	if kw == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请输入搜索词"})
		return
	}
	dramas, err := h.HG.Search(c.Request.Context(), kw)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
		return
	}
	for i := range dramas { // 封面统一走代理
		dramas[i].Cover = h.signCover(dramas[i].Cover)
	}
	c.JSON(http.StatusOK, gin.H{"items": dramas})
}

// Detail 详情+分集
func (h *DramaHandler) Detail(c *gin.Context) {
	sid := c.Query("sid")
	detail, err := h.HG.Detail(c.Request.Context(), sid)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
		return
	}
	if detail.Drama != nil { // 封面走代理
		detail.Drama.Cover = h.signCover(detail.Drama.Cover)
	}
	c.JSON(http.StatusOK, detail)
}

// Play 取播放线路（三级 fallback），返回代理后的清晰度列表
func (h *DramaHandler) Play(c *gin.Context) {
	sid := c.Query("sid")
	vid := c.Query("vid")
	media, err := h.HG.ResolveMedia(c.Request.Context(), sid, vid)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
		return
	}
	qualities := make([]gin.H, 0, len(media))
	for _, m := range media {
		qualities = append(qualities, gin.H{
			"name":    m.Name,
			"quality": m.Quality,
			"url":     h.signProxy(m.URL, m.Referer, "stream", m.CENCKey),
		})
	}
	c.JSON(http.StatusOK, gin.H{"qualities": qualities})
}

// signProxy 生成带 HMAC 签名与时效的代理 URL；cencKey 非空时编码进载荷（CENC 解密用）
func (h *DramaHandler) signProxy(rawurl, referer, kind string, cencKey []byte) string {
	expires := time.Now().Add(proxyTTL).Unix()
	payload := rawurl + "|" + referer + "|" + strconv.FormatInt(expires, 10)
	if len(cencKey) > 0 {
		payload += "|" + hex.EncodeToString(cencKey)
	}
	encoded := base64.RawURLEncoding.EncodeToString([]byte(payload))
	mac := hmac.New(sha256.New, []byte(h.Secret))
	mac.Write([]byte(encoded))
	signature := hex.EncodeToString(mac.Sum(nil))[:32]
	return "/api/drama/" + kind + "?p=" + encoded + "&s=" + signature
}

// proxyParams 校验并还原代理参数（载荷第 4 段为可选的 CENC 密钥 hex）
func (h *DramaHandler) proxyParams(c *gin.Context) (rawurl, referer, cencKeyHex string, ok bool) {
	encoded := c.Query("p")
	signature := c.Query("s")
	if encoded == "" || signature == "" {
		return "", "", "", false
	}
	payload, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return "", "", "", false
	}
	mac := hmac.New(sha256.New, []byte(h.Secret))
	mac.Write([]byte(encoded))
	if hex.EncodeToString(mac.Sum(nil))[:32] != signature {
		return "", "", "", false
	}
	parts := strings.Split(string(payload), "|")
	if len(parts) != 3 && len(parts) != 4 {
		return "", "", "", false
	}
	expires, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || time.Now().Unix() > expires {
		return "", "", "", false
	}
	if len(parts) == 4 {
		cencKeyHex = parts[3]
	}
	return parts[0], parts[1], cencKeyHex, true
}

// Stream 媒体代理：m3u8 拉取并重写（分片/key → seg，子列表 → stream）；
// fMP4 等直链流式透传（Range/状态码透传）——嗅探：Content-Type / URL 后缀 / 内容前缀；
// 载荷带 CENC 密钥的直链走服务端解密（红果部分线路是 CENC 加密 HEVC，客户端无 DRM 会话无法播放）
func (h *DramaHandler) Stream(c *gin.Context) {
	rawurl, referer, cencKeyHex, ok := h.proxyParams(c)
	if !ok {
		c.JSON(http.StatusForbidden, gin.H{"error": "播放地址无效或已过期"})
		return
	}
	if !isMediaURL(rawurl) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "地址无效"})
		return
	}
	if cencKeyHex != "" {
		h.serveCENC(c, rawurl, referer, cencKeyHex)
		return
	}
	resp, err := h.doMediaRequest(c.Request, rawurl, referer, true)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "读取播放内容失败"})
		return
	}
	defer resp.Body.Close()

	finalURL := rawurl
	if resp.Request != nil && resp.Request.URL != nil {
		finalURL = resp.Request.URL.String()
	}
	looksPlaylist := strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "mpegurl") ||
		strings.HasSuffix(strings.ToLower(finalURL), ".m3u8")

	// 读前 512 字节嗅探内容，读出的部分用 MultiReader 放回去，直链透传不丢字节
	head := make([]byte, 512)
	n, _ := io.ReadFull(resp.Body, head)
	head = head[:n]
	body := io.MultiReader(bytes.NewReader(head), resp.Body)

	if !looksPlaylist && !hongguo.IsPlaylistContent(string(head)) {
		h.passthrough(c, resp, body, "stream")
		return
	}

	rest, err := io.ReadAll(io.LimitReader(body, 4<<20))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "读取播放列表失败"})
		return
	}
	text := strings.TrimPrefix(strings.TrimSpace(string(head)+string(rest)), "\uFEFF")
	rewritten, err := hongguo.RewritePlaylist(text, finalURL, func(target, kind string) string {
		return h.signProxy(target, referer, kind, nil)
	})
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.Data(http.StatusOK, "application/vnd.apple.mpegurl", []byte(rewritten))
}

// Seg 分片/key 代理：流式透传（Range/状态码透传）
func (h *DramaHandler) Seg(c *gin.Context) {
	rawurl, referer, _, ok := h.proxyParams(c)
	if !ok {
		c.JSON(http.StatusForbidden, gin.H{"error": "播放地址无效或已过期"})
		return
	}
	if !isMediaURL(rawurl) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "地址无效"})
		return
	}
	resp, err := h.doMediaRequest(c.Request, rawurl, referer, true)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "读取媒体失败"})
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		c.Status(resp.StatusCode)
		return
	}
	h.passthrough(c, resp, resp.Body, "seg")
}

// serveCENC 服务端解密的媒体直链：全量拉取（解密需要完整样本边界，不向源站转发 Range），
// CENC 就地解密后按客户端 Range 手动切片（206/200）；解密结果按源站 URL 做 LRU 缓存
func (h *DramaHandler) serveCENC(c *gin.Context, rawurl, referer, keyHex string) {
	start := time.Now()
	key, err := hex.DecodeString(keyHex)
	if err != nil || len(key) != 16 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "解密参数无效"})
		return
	}
	if plain := h.cenc.get(rawurl); plain != nil {
		log.Printf("[drama] cenc 缓存命中 bytes=%d", len(plain))
		h.serveDecrypted(c, plain, start, true)
		return
	}
	resp, err := h.doMediaRequest(c.Request, rawurl, referer, false)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "读取播放内容失败"})
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		c.Status(resp.StatusCode)
		return
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxDirect+1))
	if err != nil {
		log.Printf("[drama] cenc 源站读取中断: %v", err)
		c.JSON(http.StatusBadGateway, gin.H{"error": "读取视频数据失败"})
		return
	}
	if len(data) > maxDirect {
		log.Printf("[drama] cenc 源站文件超过 %dMB 上限", maxDirect>>20)
		c.JSON(http.StatusBadGateway, gin.H{"error": "视频文件过大"})
		return
	}
	if resp.ContentLength > 0 && int64(len(data)) != resp.ContentLength {
		log.Printf("[drama] cenc 源站响应不完整: 期望 %d 实际 %d", resp.ContentLength, len(data))
		c.JSON(http.StatusBadGateway, gin.H{"error": "视频数据不完整"})
		return
	}
	plain, err := hongguo.DecryptCENC(data, key)
	if err != nil {
		log.Printf("[drama] cenc 解密失败: %v", err)
		c.JSON(http.StatusBadGateway, gin.H{"error": "视频解密失败"})
		return
	}
	h.cenc.put(rawurl, plain)
	h.serveDecrypted(c, plain, start, false)
}

// serveDecrypted 按客户端 Range 输出解密后的 MP4（206/200）
func (h *DramaHandler) serveDecrypted(c *gin.Context, plain []byte, start time.Time, cached bool) {
	total := int64(len(plain))
	c.Header("Accept-Ranges", "bytes")
	if spec := c.Request.Header.Get("Range"); spec != "" {
		if from, to, ok := parseByteRange(spec, total); ok {
			c.Header("Content-Range", fmt.Sprintf("bytes %d-%d/%d", from, to, total))
			c.Data(http.StatusPartialContent, "video/mp4", plain[from:to+1])
			log.Printf("[drama] cenc 切片 %d-%d/%d 缓存=%v 耗时=%s", from, to, total, cached, time.Since(start).Round(time.Millisecond))
			return
		}
	}
	c.Data(http.StatusOK, "video/mp4", plain)
	log.Printf("[drama] cenc 全量 bytes=%d 缓存=%v 耗时=%s", total, cached, time.Since(start).Round(time.Millisecond))
}

// parseByteRange 解析单一区间 Range 头（bytes=N- / bytes=N-M / bytes=-N）
func parseByteRange(spec string, total int64) (int64, int64, bool) {
	spec = strings.TrimSpace(strings.ToLower(spec))
	if !strings.HasPrefix(spec, "bytes=") || total <= 0 {
		return 0, 0, false
	}
	spec = strings.TrimPrefix(spec, "bytes=")
	if strings.Contains(spec, ",") { // 多区间不支持，退回全量
		return 0, 0, false
	}
	dash := strings.Index(spec, "-")
	if dash < 0 {
		return 0, 0, false
	}
	first, last := strings.TrimSpace(spec[:dash]), strings.TrimSpace(spec[dash+1:])
	if first == "" { // 后缀区间 bytes=-N
		n, err := strconv.ParseInt(last, 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, false
		}
		if n > total {
			n = total
		}
		return total - n, total - 1, true
	}
	s, err := strconv.ParseInt(first, 10, 64)
	if err != nil || s < 0 || s >= total {
		return 0, 0, false
	}
	e := total - 1
	if last != "" {
		if e, err = strconv.ParseInt(last, 10, 64); err != nil || e < s {
			return 0, 0, false
		}
		if e >= total {
			e = total - 1
		}
	}
	return s, e, true
}

func isMediaURL(rawurl string) bool {
	return strings.HasPrefix(rawurl, "http://") || strings.HasPrefix(rawurl, "https://")
}

// passthrough 媒体透传：先从源站完整读入内存并校验字节数，再发给客户端。
// 之前用 io.Copy 边收边发且忽略错误，源站中途断流时会给客户端发一个
// Content-Length 与实际不符的截断响应，ExoPlayer 直接报「视频加载失败」。
func (h *DramaHandler) passthrough(c *gin.Context, resp *http.Response, body io.Reader, label string) {
	start := time.Now()
	data, err := io.ReadAll(io.LimitReader(body, maxDirect+1))
	if err != nil {
		log.Printf("[drama] %s 源站读取中断: %v", label, err)
		c.JSON(http.StatusBadGateway, gin.H{"error": "读取视频数据失败"})
		return
	}
	if len(data) > maxDirect {
		log.Printf("[drama] %s 源站文件超过 %dMB 上限", label, maxDirect>>20)
		c.JSON(http.StatusBadGateway, gin.H{"error": "视频文件过大"})
		return
	}
	if resp.ContentLength > 0 && int64(len(data)) != resp.ContentLength {
		log.Printf("[drama] %s 源站响应不完整: 期望 %d 字节, 实际 %d 字节", label, resp.ContentLength, len(data))
		c.JSON(http.StatusBadGateway, gin.H{"error": "视频数据不完整"})
		return
	}

	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	for _, name := range []string{"Content-Range", "Accept-Ranges"} {
		if value := resp.Header.Get(name); value != "" {
			c.Header(name, value)
		}
	}
	// c.Data 自动按 len(data) 设置 Content-Length，源站缺失/不符的头不再透传
	c.Data(resp.StatusCode, contentType, data)
	log.Printf("[drama] %s 透传 status=%d bytes=%d 耗时=%s", label, resp.StatusCode, len(data), time.Since(start).Round(time.Millisecond))
}

// doMediaRequest 带浏览器 UA/Referer 的媒体请求；forwardRange 控制是否透传客户端 Range
func (h *DramaHandler) doMediaRequest(req *http.Request, rawurl, referer string, forwardRange bool) (*http.Response, error) {
	out, err := http.NewRequestWithContext(req.Context(), req.Method, rawurl, nil)
	if err != nil {
		return nil, err
	}
	out.Header.Set("User-Agent", "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36")
	if referer != "" {
		out.Header.Set("Referer", referer)
	}
	if value := req.Header.Get("Range"); forwardRange && value != "" {
		out.Header.Set("Range", value)
	}
	client := &http.Client{Timeout: 60 * time.Second}
	return client.Do(out)
}
