package fanqie

// 网页端搜索：POST /api/author/search/search_book/v1（免签名、字段明文，2026-09-28 实测）。
// 作为 App 源搜索的兜底（oracle 离线时仍可用）。
// 风控注意：高频请求会触发番茄风控，返回 code!=0「参数有误」（非真实参数问题），
// 因此除补全浏览器特征头外，对业务码失败做退避重试。

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// humanizeCount 数字转中文量级（14874 → "1.5万"）
func humanizeCount(n int) string {
	switch {
	case n >= 100000000:
		return fmt.Sprintf("%.1f亿", float64(n)/1e8)
	case n >= 10000:
		return fmt.Sprintf("%.1f万", float64(n)/1e4)
	default:
		return strconv.Itoa(n)
	}
}

// randomMSToken 生成仿浏览器的 msToken（116 位 base64url 字符 + '='）。
// 网页版搜索请求固定携带 msToken + a_bogus 签名，缺失时更容易被风控拦截（返回「参数有误」）。
func randomMSToken() string {
	const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	b := make([]byte, 116)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(chars))))
		if err != nil {
			b[i] = chars[i%len(chars)]
			continue
		}
		b[i] = chars[n.Int64()]
	}
	return string(b) + "="
}

// searchWebOnce 单次搜索请求（POST + msToken + a_bogus 签名，与网页版一致；
// 该接口仅接受 POST，GET 返回空体）。上游间歇性风控返回 code!=0（消息形如
// 「参数有误」，实为限流），此时返回可重试错误。
func (c *Client) searchWebOnce(keyword string, pageIndex, count int) ([]LibraryBook, error) {
	q := url.Values{}
	q.Set("filter", "127,127,127,127")
	q.Set("page_count", strconv.Itoa(count))
	q.Set("page_index", strconv.Itoa(pageIndex))
	q.Set("query_type", "0")
	q.Set("query_word", keyword)
	q.Set("msToken", randomMSToken())
	query := q.Encode()
	api := "https://fanqienovel.com/api/author/search/search_book/v1?" + query +
		"&a_bogus=" + GenerateABogus(query, UAWeb)

	req, err := http.NewRequest(http.MethodPost, api, nil)
	if err != nil {
		return nil, err
	}
	// 与 get() 相同的浏览器特征补全：裸 UA 请求在部分出口（如 NAS 容器）会被风控
	req.Header.Set("User-Agent", UAWeb)
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	req.Header.Set("Referer", "https://fanqienovel.com/")
	if c.Cookie != "" {
		req.Header.Set("Cookie", strings.NewReplacer("\r", "", "\n", "").Replace(c.Cookie))
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("网页搜索 HTTP %d", resp.StatusCode)
	}
	var parsed struct {
		Code int    `json:"code"`
		Msg  string `json:"message"`
		Data struct {
			BookList []struct {
				BookID         string      `json:"book_id"`
				BookName       string      `json:"book_name"`
				Author         string      `json:"author"`
				BookAbstract   string      `json:"book_abstract"`
				ThumbURL       string      `json:"thumb_url"`
				Category       string      `json:"category"`
				CreationStatus json.Number `json:"creation_status"`
				WordCount      json.Number `json:"word_count"`
				ReadCount      json.Number `json:"read_count"`
			} `json:"search_book_data_list"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("网页搜索解析失败: %w", err)
	}
	if parsed.Code != 0 {
		return nil, fmt.Errorf("网页搜索错误: %s", parsed.Msg)
	}
	books := make([]LibraryBook, 0, len(parsed.Data.BookList))
	for _, b := range parsed.Data.BookList {
		if b.BookID == "" {
			continue
		}
		readCnt := ""
		if n, err := b.ReadCount.Int64(); err == nil && n > 0 {
			readCnt = humanizeCount(int(n)) + "人在读"
		}
		wordCnt := ""
		if n, err := b.WordCount.Int64(); err == nil && n > 0 {
			wordCnt = humanizeCount(int(n)) + "万字"
		}
		books = append(books, LibraryBook{
			ID:        b.BookID,
			Title:     b.BookName,
			Author:    b.Author,
			Synopsis:  b.BookAbstract,
			Cover:     b.ThumbURL,
			Finished:  b.CreationStatus.String() == "0",
			WordCount: wordCnt,
			ReadCount: readCnt,
		})
	}
	return books, nil
}

// SearchWeb 网页端关键词搜索。offset 为条目偏移（内部换算 page_index）。
// 上游仅接受 page_count=10（其他值一律 code:-2「参数有误」，2026-09-30 实测），
// 调用方传入更大 count 时按 10 拆页取回后截断。
func (c *Client) SearchWeb(keyword string, offset, count int) ([]LibraryBook, error) {
	if count <= 0 {
		count = 10
	}
	pageIndex := offset / count
	if count > 10 {
		// 多于 10 条的请求：按 10 的页宽拉到足够覆盖，再截取前 count 条
		pages := (count + 9) / 10
		var out []LibraryBook
		for p := 0; p < pages; p++ {
			books, err := c.searchWebOnce(keyword, pageIndex+p, 10)
			if err != nil {
				if p == 0 {
					return nil, err
				}
				break // 后续页失败不阻塞已取到的结果
			}
			out = append(out, books...)
			if len(books) < 10 {
				break
			}
		}
		if len(out) > count {
			out = out[:count]
		}
		return out, nil
	}
	return c.searchWebOnce(keyword, pageIndex, count)
}
