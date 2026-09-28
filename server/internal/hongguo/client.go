package hongguo

// 红果短剧客户端 —— 移植自 _reference/guoapp（native/core/provider_hongguo_*）
// 仅个人自用：签名请求 App 接口 + 网页兜底 + 三级取流，控制请求频率

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/bits"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	appBaseURL   = "https://api5-normal-sinfonlineb.fqnovel.com"
	webBaseURL   = "https://hongguoduanju.com"
	appUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1"
	mediaReferer = "https://novel.snssdk.com/"
)

// Drama 短剧条目（目录/搜索/详情共用）
type Drama struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Cover      string `json:"cover"`
	Intro      string `json:"intro,omitempty"`
	Category   string `json:"category,omitempty"`
	Tags       []string `json:"tags,omitempty"`
	Remark     string `json:"remark,omitempty"` // 如 "共80集"
	EpisodeCnt string `json:"episode_count,omitempty"`
	Finished   bool   `json:"finished"`
	Score      string `json:"score,omitempty"`
	PlayCount  string `json:"play_count,omitempty"`
}

// Episode 一集
type Episode struct {
	Vid   string `json:"vid"`
	Index int    `json:"index"` // 1-based
}

// Quality 一条播放线路（URL 已是代理地址）
type Quality struct {
	Name    string `json:"name"`
	URL     string `json:"url"`
	Quality int    `json:"quality"`
}

// Client 红果客户端（并发安全）
type Client struct {
	HTTP     *http.Client
	deviceID string
	iid      string

	mu       sync.Mutex
	sessions map[string]string             // genre -> 目录翻页 session_id
	details  map[string]detailCache        // series_id -> 详情缓存
	media    map[string]mediaCache         // sid|vid -> 取流缓存
	searches map[string]searchCache        // keyword -> 搜索缓存
	panels   map[string]panelCache         // genre -> 二级筛选面板缓存
	rawPanels map[string]map[string]any    // genre -> 面板原始响应（解析兜底）
}

type detailCache struct {
	drama     *Drama
	episodes  []Episode
	expiresAt time.Time
}

type mediaCache struct {
	media     []Media // URL 为原始地址（未包代理），由 handler 每次包装
	expiresAt time.Time
}

type searchCache struct {
	dramas    []Drama
	expiresAt time.Time
}

type panelCache struct {
	dims      []FilterDim
	expiresAt time.Time
}

const (
	detailTTL = 5 * time.Minute
	mediaTTL  = 5 * time.Minute
	searchTTL = 3 * time.Minute
)

var numericID = regexp.MustCompile(`^[0-9]{1,32}$`)

func NewClient() *Client {
	// 强制 IPv4 + 浏览器特征，与 fanqie 包同款策略
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", addr)
		},
	}
	return &Client{
		HTTP:     &http.Client{Timeout: 20 * time.Second, Transport: transport},
		deviceID: newDeviceID(),
		iid:      newDeviceID(),
		sessions: map[string]string{},
		details:  map[string]detailCache{},
		media:    map[string]mediaCache{},
		searches: map[string]searchCache{},
		panels:   map[string]panelCache{},
		rawPanels: map[string]map[string]any{},
	}
}

func newDeviceID() string {
	// 19 位数字设备 ID（与 guoapp newHongguoDeviceID 一致形态）
	var b [8]byte
	_, _ = crandRead(b[:])
	return strconv.FormatUint(1_000_000_000_000_000_000+binaryUint64(b)%8_000_000_000_000_000_000, 10)
}

// ─── App 接口（X-Gorgon 签名） ────────────────────────────────────────

var appGenres = []struct {
	key   string
	scene string
	name  string
}{
	{"short_play", "default", "真人剧"},
	{"comic_series", "comic_series", "漫剧"},
	{"ai_series", "ai_series", "AI剧"},
}

// Genres 供 handler 暴露分类列表
func Genres() []map[string]string {
	out := make([]map[string]string, 0, len(appGenres))
	for _, g := range appGenres {
		out = append(out, map[string]string{"key": g.key, "name": g.name})
	}
	return out
}

func genreName(key string) string {
	for _, g := range appGenres {
		if g.key == key {
			return g.name
		}
	}
	return "短剧"
}

// appRequest 签名请求 App JSON 接口
func (c *Client) appRequest(ctx context.Context, path string, payload map[string]any) (map[string]any, error) {
	query := url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {"73532"}, "version_name": {"7.3.5.32"},
		"manifest_version_code": {"73532"}, "update_version_code": {"73532"}, "channel": {"update_64"},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
		"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"}, "device_id": {c.deviceID}, "iid": {c.iid},
	}
	var body []byte
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		body = b
	}
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			select {
			case <-time.After(time.Second):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		now := time.Now()
		query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, appBaseURL+path+"?"+query.Encode(), bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		req.Header.Set("User-Agent", appUserAgent)
		req.Header.Set("Accept", "application/json")
		req.Header.Set("X-XS-From-Web", "0")
		req.Header.Set("Sdk-Version", "2")
		if body != nil {
			req.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
		signAppRequest(req, body, now)
		resp, err := c.HTTP.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		resp.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果接口 HTTP %d", resp.StatusCode)
			if resp.StatusCode >= 400 && resp.StatusCode < 500 {
				return nil, lastErr
			}
			continue
		}
		var result map[string]any
		dec := json.NewDecoder(bytes.NewReader(content))
		dec.UseNumber()
		if err := dec.Decode(&result); err != nil || result == nil {
			return nil, errors.New("红果接口返回格式异常")
		}
		code := mapString(result, "code", "status_code")
		if code == "" {
			code = mapString(nestedMap(result, "BaseResp"), "StatusCode")
		}
		if code != "" && code != "0" {
			return nil, fmt.Errorf("红果接口暂不可用（%s）", truncate(code, 20))
		}
		return result, nil
	}
	return nil, lastErr
}

// signAppRequest X-Gorgon/X-Khronos 签名（移植自 provider_hongguo_sign.go）
func signAppRequest(req *http.Request, body []byte, now time.Time) {
	timestamp := uint32(now.Unix())
	queryHash := md5Sum([]byte(req.URL.RawQuery))
	var payload [20]byte
	copy(payload[:4], queryHash[:4])
	if body != nil {
		bodyHash := md5Sum(body)
		copy(payload[4:8], bodyHash[:4])
		req.Header.Set("X-SS-STUB", fmt.Sprintf("%X", bodyHash))
	}
	copy(payload[12:16], []byte{0, 6, 11, 28})
	binaryPutUint32(payload[16:], timestamp)
	key := [...]byte{0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f}
	for i := range payload {
		payload[i] ^= key[i]
	}
	for i := range payload {
		mixed := bits.RotateLeft8(payload[i], 4) ^ payload[(i+1)%len(payload)]
		payload[i] = bits.Reverse8(mixed) ^ 0xff ^ byte(len(payload))
	}
	signature := append([]byte{0x84, 0x04, 0x40, 0x1c, 0, 0}, payload[:]...)
	req.Header.Set("X-Khronos", strconv.FormatUint(uint64(timestamp), 10))
	req.Header.Set("X-Gorgon", hexEncode(signature))
	req.Header.Set("X-SS-Req-Ticket", strconv.FormatInt(now.UnixMilli(), 10))
}

// ─── 网页抓取 ─────────────────────────────────────────────────────────

func (c *Client) fetchText(ctx context.Context, rawurl, referer string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawurl, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", webUserAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d: %s", resp.StatusCode, resp.Status)
	}
	return string(body), nil
}

// ─── JSON 工具 ────────────────────────────────────────────────────────

func nestedMap(v any, keys ...string) map[string]any {
	cur, _ := v.(map[string]any)
	for _, key := range keys {
		if cur == nil {
			return nil
		}
		cur, _ = cur[key].(map[string]any)
	}
	return cur
}

// routerLoaderMap 网页 _ROUTER_DATA.loaderData 里按名字找 page（带前缀兜底）
func routerLoaderMap(data map[string]any, names ...string) map[string]any {
	loader, _ := data["loaderData"].(map[string]any)
	for _, name := range names {
		if page, _ := loader[name].(map[string]any); len(page) > 0 {
			return page
		}
	}
	for key, value := range loader {
		for _, name := range names {
			prefix := strings.TrimSuffix(name, "$")
			if prefix != "" && strings.HasPrefix(key, prefix) {
				if page, _ := value.(map[string]any); len(page) > 0 {
					return page
				}
			}
		}
	}
	return nil
}

func anyList(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	case map[string]any:
		for _, key := range []string{"list", "items", "data"} {
			if out := anyList(x[key]); len(out) > 0 {
				return out
			}
		}
	}
	return nil
}

// mapString 按优先级取字符串字段（兼容 json.Number/float64/bool）
func mapString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		v, ok := m[k]
		if !ok || v == nil {
			continue
		}
		switch x := v.(type) {
		case string:
			if x != "" {
				return x
			}
		case json.Number:
			return x.String()
		case float64:
			return strconv.FormatFloat(x, 'f', -1, 64)
		case bool:
			if x {
				return "1"
			}
		}
	}
	return ""
}

func mapStringSlice(m map[string]any, key string) []string {
	raw, _ := m[key].([]any)
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		if s, ok := item.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

var reTrailingComma = regexp.MustCompile(`,\s*([}\]])`)

// parseRouterData 提取网页内嵌 _ROUTER_DATA JSON
func parseRouterData(raw string) map[string]any {
	marker := regexp.MustCompile(`(?s)(?:window\.)?_ROUTER_DATA\s*=\s*`)
	loc := marker.FindStringIndex(raw)
	if loc == nil {
		return nil
	}
	text := strings.ReplaceAll(raw[loc[1]:], "undefined", "null")
	text = reTrailingComma.ReplaceAllString(text, "$1")
	var data map[string]any
	dec := json.NewDecoder(strings.NewReader(text))
	dec.UseNumber()
	if err := dec.Decode(&data); err != nil {
		return nil
	}
	return data
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// ─── HTTP 小工具 ──────────────────────────────────────────────────────

const httpStatusOK = http.StatusOK

func newGetRequest(ctx context.Context, rawurl, referer string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawurl, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", webUserAgent)
	req.Header.Set("Accept", "application/json, text/html, */*")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	return req, nil
}

func readLimited(resp *http.Response, limit int64) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, errors.New("响应过大")
	}
	return body, nil
}
