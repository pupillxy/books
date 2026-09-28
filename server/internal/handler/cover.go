package handler

// 封面代理：磁盘缓存 + singleflight 去重 + 全局限速/并发 + 负缓存 + 熔断
// 目标：上游（红果 CDN）视角是匀速低并发的正常客户端，绝无突发，避免风控封 IP。
// 稳态：磁盘命中 → 零上游请求；上游只在首次见到某封面时被请求一次。
// 不重试：重试是放大请求量、触发风控的典型行为。

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

const (
	coverNegTTL    = time.Hour              // 上游 404/410 负缓存
	coverInterval  = 150 * time.Millisecond // 上游请求最小间隔（≈6.7 req/s 匀速）
	coverConc      = 3                      // 上游并发上限
	coverMaxBytes  = 8 << 20                // 单张封面上限 8MB
	coverFailLimit = 5                      // 连续上游失败熔断阈值
	coverBreakOpen = time.Minute            // 熔断开启时长
	coverTTL       = 365 * 24 * time.Hour   // 封面签名时效（长时效：历史记录存的链接不失效）

	coverUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1"
)

var errCoverGated = errors.New("封面暂时不可用（熔断或负缓存）")

// coverGate 上游访问闸门：singleflight 去重 + 匀速限速 + 并发上限 + 负缓存 + 熔断。
// 不重试：重试是放大请求量、触发风控封 IP 的典型行为。
type coverGate struct {
	mu       sync.Mutex
	next     time.Time             // 下次允许发起上游请求的时刻（匀速间隔）
	neg      map[string]time.Time  // url -> 负缓存到期（404/410）
	fails    int                   // 连续上游失败计数
	openAt   time.Time             // 熔断开启截止时刻
	inflight map[string]*coverCall // singleflight：同 URL 并发合并为一次上游抓取
	sem      chan struct{}         // 并发上限
}

type coverCall struct {
	done  chan struct{}
	data  []byte
	ctype string
	err   error
}

func newCoverGate() *coverGate {
	return &coverGate{
		// next 必须初始化：零值 time.Time 是公元 1 年，now.Sub() 得到天文数字会把请求睡死
		next:     time.Now(),
		neg:      map[string]time.Time{},
		inflight: map[string]*coverCall{},
		sem:      make(chan struct{}, coverConc),
	}
}

// do singleflight：同 key 并发请求合并为一次上游抓取，等待者共享结果
func (g *coverGate) do(key string, fn func() ([]byte, string, error)) ([]byte, string, error) {
	g.mu.Lock()
	if call, hit := g.inflight[key]; hit {
		g.mu.Unlock()
		<-call.done
		return call.data, call.ctype, call.err
	}
	call := &coverCall{done: make(chan struct{})}
	g.inflight[key] = call
	g.mu.Unlock()

	defer func() {
		g.mu.Lock()
		delete(g.inflight, key)
		g.mu.Unlock()
		close(call.done)
	}()
	call.data, call.ctype, call.err = fn()
	return call.data, call.ctype, call.err
}

// acquire 取得一次上游请求资格：熔断 → 负缓存 → 匀速间隔 → 并发闸。
// !ok = 本地快速失败（熔断中或负缓存命中），完全不碰上游。
func (g *coverGate) acquire(key string) (release func(), ok bool) {
	g.mu.Lock()
	now := time.Now()
	if now.Before(g.openAt) { // 熔断中：快速失败，不碰上游
		g.mu.Unlock()
		return nil, false
	}
	if until, bad := g.neg[key]; bad && now.Before(until) { // 负缓存命中
		g.mu.Unlock()
		return nil, false
	}
	if g.next.Before(now) { // 空闲已久：从现在起算，不累积突发信用
		g.next = now
	}
	wait := g.next.Sub(now)
	g.next = g.next.Add(coverInterval) // 从上一槽位顺延：突发时 0/150/300ms 依次放行
	g.mu.Unlock()

	if wait > 0 {
		time.Sleep(wait) // 在闸外等待，不占并发名额
	}
	g.sem <- struct{}{}
	return func() { <-g.sem }, true
}

// record 上游结果记账：成功清零；404/410 负缓存；连续失败熔断
func (g *coverGate) record(key string, ok bool, status int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if ok {
		g.fails = 0
		delete(g.neg, key)
		return
	}
	if status == http.StatusNotFound || status == http.StatusGone {
		if len(g.neg) > 8192 { // 防膨胀（封面总量有限，一般到不了）
			g.neg = map[string]time.Time{}
		}
		g.neg[key] = time.Now().Add(coverNegTTL)
		return
	}
	g.fails++
	if g.fails >= coverFailLimit {
		g.openAt = time.Now().Add(coverBreakOpen)
		g.fails = 0
		log.Printf("[drama] cover 上游连续失败 %d 次，熔断 %s（期间快速失败，不碰上游）", coverFailLimit, coverBreakOpen)
	}
}

// ─── 磁盘缓存 ─────────────────────────────────────────────────────────

// coverDirDefault 封面缓存目录：Docker 数据卷 /data/covers；本机开发 data/covers（与 DB 重定向同级）
func coverDirDefault() string {
	if d := os.Getenv("XS_COVER_DIR"); d != "" {
		return d
	}
	if st, err := os.Stat("/data"); err == nil && st.IsDir() {
		return "/data/covers"
	}
	return "data/covers"
}

// coverKey 磁盘文件名：sha256(url) 前 32 hex（无需扩展名，serve 时嗅探类型）
func coverKey(rawurl string) string {
	sum := sha256.Sum256([]byte(rawurl))
	return hex.EncodeToString(sum[:])[:32]
}

func loadCover(dir, key string) ([]byte, string) {
	data, err := os.ReadFile(filepath.Join(dir, key))
	if err != nil {
		return nil, ""
	}
	return data, http.DetectContentType(data)
}

// storeCover 原子落盘（临时文件 + rename，Windows/Linux 都安全）
func storeCover(dir, key string, data []byte) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return
	}
	name := tmp.Name()
	if _, werr := tmp.Write(data); werr != nil {
		tmp.Close()
		os.Remove(name)
		return
	}
	if cerr := tmp.Close(); cerr != nil {
		os.Remove(name)
		return
	}
	if rerr := os.Rename(name, filepath.Join(dir, key)); rerr != nil {
		os.Remove(name)
	}
}

// ─── 上游抓取 ─────────────────────────────────────────────────────────

type coverStatusError struct{ code int }

func (e *coverStatusError) Error() string { return fmt.Sprintf("上游 HTTP %d", e.code) }

func coverStatus(err error) int {
	var se *coverStatusError
	if errors.As(err, &se) {
		return se.code
	}
	return 0
}

// fetchCover 单次上游抓取（不重试：重试是放大请求量、触发风控封 IP 的典型行为）。
// 用 hongguo 客户端的 HTTP（与 API 请求同一连接池/TLS 指纹，上游视角是同一个客户端）。
func (h *DramaHandler) fetchCover(rawurl string) ([]byte, string, error) {
	req, err := http.NewRequest(http.MethodGet, rawurl, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("User-Agent", coverUserAgent)
	req.Header.Set("Accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
	resp, err := h.HG.HTTP.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", &coverStatusError{code: resp.StatusCode}
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, coverMaxBytes+1))
	if err != nil {
		return nil, "", err
	}
	if len(data) > coverMaxBytes {
		return nil, "", fmt.Errorf("封面超过 %dMB 上限", coverMaxBytes>>20)
	}
	ctype := strings.TrimSpace(strings.SplitN(resp.Header.Get("Content-Type"), ";", 2)[0])
	if !strings.HasPrefix(ctype, "image/") {
		ctype = http.DetectContentType(data)
	}
	return data, ctype, nil
}

// ─── 签名 ─────────────────────────────────────────────────────────────

// signCover 原始 CDN 封面 URL → 带签名的相对代理地址。
// TTL 长（封面是公开 CDN 地址，长时效无风险；历史记录里存的链接不会过期失效）。
func (h *DramaHandler) signCover(rawurl string) string {
	if rawurl == "" {
		return ""
	}
	if strings.HasPrefix(rawurl, "/") {
		return rawurl // 已是相对代理路径
	}
	expires := time.Now().Add(coverTTL).Unix()
	payload := rawurl + "||" + strconv.FormatInt(expires, 10)
	encoded := base64.RawURLEncoding.EncodeToString([]byte(payload))
	mac := hmac.New(sha256.New, []byte(h.Secret))
	mac.Write([]byte(encoded))
	signature := hex.EncodeToString(mac.Sum(nil))[:32]
	return "/api/drama/cover?p=" + encoded + "&s=" + signature
}

// coverLink 观看记录里的封面 → 最新签名地址。
// 兼容三种存量：原始 CDN URL / 绝对代理地址（含过期签名） / 相对代理路径。
func (h *DramaHandler) coverLink(stored string) string {
	if stored == "" {
		return ""
	}
	if strings.HasPrefix(stored, "/") {
		return stored // 已是相对代理路径
	}
	if u, err := url.Parse(stored); err == nil && u.Path == "/api/drama/cover" {
		// 旧记录存了绝对代理地址：解出原始 URL 重签（续期，不回源）
		if p := u.Query().Get("p"); p != "" {
			if payload, derr := base64.RawURLEncoding.DecodeString(p); derr == nil {
				if parts := strings.SplitN(string(payload), "|", 2); len(parts) > 0 && parts[0] != "" {
					return h.signCover(parts[0])
				}
			}
		}
	}
	return h.signCover(stored)
}

// ─── HTTP ─────────────────────────────────────────────────────────────

// isCoverURL 仅允许 http/https（签名已防伪造，这里只是兜底）
func isCoverURL(rawurl string) bool {
	return strings.HasPrefix(rawurl, "http://") || strings.HasPrefix(rawurl, "https://")
}

// Cover 封面代理：磁盘命中 → singleflight → 限速/并发 → 上游一次 → 落盘 → 透传。
// 公开端点（与 stream/seg 一致：签名即鉴权，Flutter 的 Image.network 带不了 Authorization）。
func (h *DramaHandler) Cover(c *gin.Context) {
	rawurl, _, _, ok := h.proxyParams(c)
	if !ok || !isCoverURL(rawurl) {
		c.JSON(http.StatusForbidden, gin.H{"error": "封面地址无效或已过期"})
		return
	}
	key := coverKey(rawurl)
	if data, ctype := loadCover(h.coverDir, key); data != nil { // 磁盘命中：零上游
		serveCover(c, data, ctype, "hit")
		return
	}
	data, ctype, err := h.covers.do(key, func() ([]byte, string, error) {
		release, allowed := h.covers.acquire(key)
		if !allowed { // 熔断中或负缓存命中：快速失败，不碰上游
			return nil, "", errCoverGated
		}
		defer release()
		data, ctype, err := h.fetchCover(rawurl)
		h.covers.record(key, err == nil, coverStatus(err))
		if err != nil {
			return nil, "", err
		}
		storeCover(h.coverDir, key, data)
		log.Printf("[drama] cover 上游抓取 %s (%d bytes, %s)", rawurl, len(data), ctype)
		return data, ctype, nil
	})
	if err != nil {
		if err == errCoverGated || coverStatus(err) == http.StatusNotFound || coverStatus(err) == http.StatusGone {
			c.JSON(http.StatusNotFound, gin.H{"error": "封面暂不可用"})
			return
		}
		c.JSON(http.StatusBadGateway, gin.H{"error": "封面获取失败"})
		return
	}
	serveCover(c, data, ctype, "miss")
}

func serveCover(c *gin.Context, data []byte, ctype, cache string) {
	c.Header("Cache-Control", "public, max-age=31536000, immutable")
	c.Header("X-Cover-Cache", cache)
	c.Data(http.StatusOK, ctype, data)
}
