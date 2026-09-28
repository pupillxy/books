package hongguo

// 三级取流 fallback —— 移植自 _reference/guoapp
// provider_hongguo_native_media.go / provider_hongguo.go / provider_hongguo_playback.go

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const playbackAPI = "https://djapi.999888456.xyz/api/hongguo/play"

// Media 一条可播线路（URL 为原始地址，代理包装由 handler 完成）
type Media struct {
	URL     string
	Referer string
	Quality int
	Name    string
	CENCKey []byte // CENC 内容密钥（16 字节）；nil 表示明文线路
}

var qualityNumber = regexp.MustCompile(`[0-9]+`)

// ResolveMedia 三级 fallback：App 取流 → 网页取流 → 第三方聚合 API
func (c *Client) ResolveMedia(ctx context.Context, seriesID, videoID string) ([]Media, error) {
	if !numericID.MatchString(seriesID) || !numericID.MatchString(videoID) {
		return nil, errors.New("红果剧集 ID 无效")
	}
	cacheKey := seriesID + "|" + videoID
	c.mu.Lock()
	if cached, ok := c.media[cacheKey]; ok && time.Now().Before(cached.expiresAt) {
		c.mu.Unlock()
		return cached.media, nil
	}
	c.mu.Unlock()

	media, appErr := c.resolveAppMedia(ctx, videoID)
	if appErr != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		media, pageErr := c.resolveWebMedia(ctx, seriesID, videoID)
		if pageErr != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			media, apiErr := c.resolvePlaybackAPI(ctx, seriesID, videoID)
			if apiErr != nil {
				return nil, fmt.Errorf("App 取流失败：%v；网页取流失败：%v；备用取流失败：%w", appErr, pageErr, apiErr)
			}
			cacheMedia(c, cacheKey, media)
			return media, nil
		}
		cacheMedia(c, cacheKey, media)
		return media, nil
	}
	cacheMedia(c, cacheKey, media)
	return media, nil
}

func cacheMedia(c *Client, key string, media []Media) {
	c.mu.Lock()
	c.media[key] = mediaCache{media: media, expiresAt: time.Now().Add(mediaTTL)}
	c.mu.Unlock()
}

// ─── 一级：App 取流 ───────────────────────────────────────────────────

func (c *Client) resolveAppMedia(ctx context.Context, videoID string) ([]Media, error) {
	result, err := c.appRequest(ctx, "/novel/player/video_model/v1/", map[string]any{
		"video_id": videoID, "content_type": 1,
		"biz_param": map[string]any{"need_all_video_definition": true, "video_platform": 3},
	})
	if err != nil {
		return nil, err
	}
	data := nestedMap(result, "data")
	model, _ := data["video_model"].(map[string]any)
	if encoded, ok := data["video_model"].(string); ok {
		dec := json.NewDecoder(strings.NewReader(encoded))
		dec.UseNumber()
		if err := dec.Decode(&model); err != nil {
			return nil, errors.New("红果 App 播放信息格式异常")
		}
	}
	return selectAppMedia(model)
}

func selectAppMedia(model map[string]any) ([]Media, error) {
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	type scored struct {
		media Media
		score int
	}
	var choices []scored
	var keyErr error
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		addresses := mediaAddresses(variant)
		if len(addresses) == 0 {
			continue
		}
		// 加密线路：spade_a 必须能解出内容密钥，否则视为不可用；key 交给服务端解密
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		var contentKey []byte
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			key, err := hongguoContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
			contentKey = key
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(qualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		for _, address := range addresses {
			choices = append(choices, scored{media: Media{
				URL: address, Referer: mediaReferer, Quality: height,
				Name: qualityLabel(height), CENCKey: contentKey,
			}, score: quality})
		}
	}
	if len(choices) == 0 {
		if keyErr != nil {
			return nil, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
		}
		return nil, errors.New("红果 App 未返回兼容的媒体")
	}
	sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
	out := make([]Media, 0, len(choices))
	seen := map[string]bool{}
	for _, choice := range choices {
		if !seen[choice.media.URL] {
			seen[choice.media.URL] = true
			out = append(out, choice.media)
		}
	}
	return out, nil
}

func qualityLabel(height int) string {
	if height <= 0 {
		return "默认"
	}
	return strconv.Itoa(height) + "p"
}

// mediaAddresses 递归收集地址字段（值可能是 base64）
func mediaAddresses(info map[string]any) []string {
	var addresses []string
	seen := map[string]bool{}
	var add func(any)
	add = func(value any) {
		switch value := value.(type) {
		case string:
			address := strings.TrimSpace(value)
			if len(address) > 8192 {
				return
			}
			if !isHTTPMediaURL(address) {
				decoded, err := decodeB64(address)
				if err != nil {
					return
				}
				address = strings.TrimSpace(string(decoded))
			}
			if isHTTPMediaURL(address) && !seen[address] {
				seen[address] = true
				addresses = append(addresses, address)
			}
		case []any:
			for _, item := range value {
				add(item)
			}
		}
	}
	for _, key := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list"} {
		add(info[key])
	}
	return addresses
}

func isHTTPMediaURL(address string) bool {
	return strings.HasPrefix(address, "http://") || strings.HasPrefix(address, "https://")
}

// ─── 二级：网页取流 ───────────────────────────────────────────────────

func (c *Client) resolveWebMedia(ctx context.Context, seriesID, videoID string) ([]Media, error) {
	pageURL := webBaseURL + "/player/" + url.PathEscape(seriesID) + "/" + url.PathEscape(videoID)
	body, err := c.fetchText(ctx, pageURL, webBaseURL+"/")
	if err != nil {
		return nil, err
	}
	page := routerLoaderMap(parseRouterData(body), "player_", "player_page")
	if mapString(page, "vid") != videoID || mapString(page, "series_id") != seriesID {
		return nil, errors.New("红果未返回所请求的剧集，可能仅允许网页试看")
	}
	info, _ := page["video_player_info"].(map[string]any)
	addresses := mediaAddresses(info)
	if len(addresses) == 0 {
		return nil, errors.New("红果该集未提供公开播放地址")
	}
	out := make([]Media, 0, len(addresses))
	for _, address := range addresses {
		quality := 0
		if n, err := strconv.Atoi(qualityNumber.FindString(address)); err == nil {
			quality = n
		}
		out = append(out, Media{URL: address, Referer: webBaseURL + "/", Quality: quality, Name: qualityLabel(quality)})
	}
	return out, nil
}

// ─── 三级：第三方聚合 API ─────────────────────────────────────────────

func (c *Client) resolvePlaybackAPI(ctx context.Context, seriesID, videoID string) ([]Media, error) {
	reference, err := json.Marshal(map[string]any{
		"content_type": 1004, "series_id": seriesID, "vid": videoID, "video_platform": 3,
	})
	if err != nil {
		return nil, err
	}
	rawurl := playbackAPI + "?id=" + base64.StdEncoding.EncodeToString(reference)
	body, err := c.fetchText(ctx, rawurl, webBaseURL+"/")
	if err != nil {
		return nil, err
	}
	decoded, err := decodeHongguoPlaybackResponse(body)
	if err != nil {
		return nil, err
	}
	var response struct {
		Parse   json.RawMessage `json:"parse"`
		JX      json.RawMessage `json:"jx"`
		KeyURLs []struct {
			Name   string `json:"name"`
			URL    string `json:"src"`
			KeyID  string `json:"kid"`
			SpadeA string `json:"spade_a"`
		} `json:"key_urls"`
	}
	if err := json.Unmarshal(decoded, &response); err != nil {
		return nil, errors.New("红果备用播放接口返回了无效数据")
	}
	for _, flag := range []json.RawMessage{response.Parse, response.JX} {
		switch strings.TrimSpace(string(flag)) {
		case "", "null", "false", "0", `"0"`, `""`:
		default:
			return nil, errors.New("红果备用播放接口没有返回直接媒体地址")
		}
	}
	var out []Media
	seen := map[string]bool{}
	var keyErr error
	for _, option := range response.KeyURLs {
		mediaURL := strings.TrimSpace(option.URL)
		if len(mediaURL) > 8192 || !isHTTPMediaURL(mediaURL) {
			continue
		}
		keyID, err := hex.DecodeString(strings.TrimSpace(option.KeyID))
		if err != nil || len(keyID) != 16 {
			continue
		}
		key, err := hongguoContentKey(option.SpadeA)
		if err != nil {
			keyErr = err
			continue
		}
		quality, _ := strconv.Atoi(qualityNumber.FindString(option.Name))
		if seen[mediaURL] {
			continue
		}
		seen[mediaURL] = true
		name := option.Name
		if name == "" {
			name = qualityLabel(quality)
		}
		out = append(out, Media{URL: mediaURL, Referer: mediaReferer, Quality: quality, Name: name, CENCKey: key})
	}
	if len(out) == 0 {
		if keyErr != nil {
			return nil, fmt.Errorf("红果备用播放接口未返回可用的媒体和密钥: %w", keyErr)
		}
		return nil, errors.New("红果备用播放接口未返回可用的媒体和密钥")
	}
	return out, nil
}
