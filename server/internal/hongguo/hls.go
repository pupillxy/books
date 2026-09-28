package hongguo

// m3u8 重写 —— 移植自 _reference/guoapp app_stream.go（nativeRewrite）
// 分片与 key 改写到代理端点（附 UA/Referer 由服务端补齐），播放器零特殊逻辑

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

var rePlaylistURI = regexp.MustCompile(`URI="([^"]+)"`)

// RewritePlaylist 重写 m3u8：所有引用改写为代理 URL。
// proxy(rawurl, kind) 返回代理地址；kind: "stream"(子播放列表) / "seg"(分片、key、init 段)
func RewritePlaylist(body, baseURL string, proxy func(rawurl string, kind string) string) (string, error) {
	base, err := url.Parse(baseURL)
	if err != nil {
		return "", errors.New("播放列表基准地址无效")
	}
	var output []string
	nextPlaylist := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		text := strings.TrimSpace(line)
		rewrite := func(reference, kind string) string {
			if strings.HasPrefix(reference, "data:") {
				return reference
			}
			relative, err := url.Parse(reference)
			if err != nil {
				return ""
			}
			address := base.ResolveReference(relative).String()
			if !isHTTPMediaURL(address) {
				return ""
			}
			return proxy(address, kind)
		}
		if text != "" && !strings.HasPrefix(text, "#") {
			kind := "seg"
			if nextPlaylist {
				kind = "stream"
			}
			nextPlaylist = false
			line = rewrite(text, kind)
			if line == "" {
				return "", errors.New("播放列表中的媒体地址无效")
			}
		} else if strings.Contains(text, "URI=") {
			invalid := false
			line = rePlaylistURI.ReplaceAllStringFunc(line, func(match string) string {
				reference := rePlaylistURI.FindStringSubmatch(match)[1]
				kind := "seg"
				switch {
				case strings.HasPrefix(text, "#EXT-X-KEY:"), strings.HasPrefix(text, "#EXT-X-SESSION-KEY:"):
					kind = "seg" // key 字节直接代理下载
				case strings.HasPrefix(text, "#EXT-X-MEDIA:"),
					strings.HasPrefix(text, "#EXT-X-I-FRAME-STREAM-INF:"),
					strings.HasPrefix(text, "#EXT-X-RENDITION-REPORT:"):
					kind = "stream"
				}
				updated := rewrite(reference, kind)
				if updated == "" {
					invalid = true
				}
				return `URI="` + updated + `"`
			})
			if invalid {
				return "", errors.New("播放列表中的附属地址无效")
			}
		}
		if strings.HasPrefix(text, "#EXT-X-STREAM-INF:") {
			nextPlaylist = true
		}
		output = append(output, line)
	}
	return strings.Join(output, "\n"), nil
}

// IsPlaylistContent 判断响应是否为 m3u8（内容嗅探兜底）
func IsPlaylistContent(body string) bool {
	return strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(body, "\uFEFF")), "#EXTM3U")
}
