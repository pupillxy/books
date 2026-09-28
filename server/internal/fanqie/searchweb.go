package fanqie

// 网页端搜索：POST /api/author/search/search_book/v1（免签名、字段明文，2026-09-28 实测）。
// 作为 App 源搜索的兜底（oracle 离线时仍可用）。

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
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

// SearchWeb 网页端关键词搜索。offset 为条目偏移（内部换算 page_index）。
func (c *Client) SearchWeb(keyword string, offset, count int) ([]LibraryBook, error) {
	pageIndex := 0
	if count > 0 {
		pageIndex = offset / count
	}
	q := url.Values{}
	q.Set("filter", "127,127,127,127")
	q.Set("page_count", strconv.Itoa(count))
	q.Set("page_index", strconv.Itoa(pageIndex))
	q.Set("query_type", "0")
	q.Set("query_word", keyword)
	api := "https://fanqienovel.com/api/author/search/search_book/v1?" + q.Encode()

	req, err := http.NewRequest(http.MethodPost, api, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", UAWeb)
	req.Header.Set("Referer", "https://fanqienovel.com/")
	req.Header.Set("Accept", "application/json, text/plain, */*")
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
