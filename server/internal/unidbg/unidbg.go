// Package unidbg 对接 zero199901/fqnovel-unidbg 签名服务（NAS/本机 Java 进程）。
// 该服务内置番茄海外版 SO，用 unidbg 模拟执行让 SO 自算 X-Helios/X-Medusa，
// 服务端直接接受——无需手机、无需安卓模拟器。 XS_UNIDBG_URL 留空禁用。
package unidbg

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"xiaoshuo/internal/database"
)

const (
	batchSize     = 20
	batchInterval = 3 * time.Second // SO 签名出口 + IP 级限流并存：高频会先设备风控后 IP 封禁
)

// Client unidbg 签名服务 HTTP 客户端
type Client struct {
	BaseURL string
	HTTP    *http.Client
}

// New 创建客户端，baseURL 形如 http://127.0.0.1:9999，空串表示禁用
func New(baseURL string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		HTTP:    &http.Client{Timeout: 90 * time.Second},
	}
}

// Enabled 是否已配置启用
func (c *Client) Enabled() bool { return c != nil && c.BaseURL != "" }

// ─── 响应结构（对齐 Java DTO）────────────────────────────────────────

type apiResp struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type searchBook struct {
	BookID      string `json:"bookId"`
	BookName    string `json:"bookName"`
	Author      string `json:"author"`
	Description string `json:"description"`
}

// Book 搜索结果条目
type Book struct {
	BookID      string `json:"book_id"`
	BookName    string `json:"book_name"`
	Author      string `json:"author"`
	Description string `json:"description"`
}

type directoryChapter struct {
	Title        string  `json:"title"`
	ItemID       string  `json:"item_id"`
	ChapterIndex flexInt `json:"chapter_index"`
	VolumeName   string  `json:"volume_name"`
	WordNumber   int     `json:"chapter_word_number"`
}

// flexInt 容忍上游把数字序列化成字符串（不同书 chapter_index 类型不一致）
type flexInt int

func (f *flexInt) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "" || s == "null" {
		*f = 0
		return nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		*f = 0
		return nil
	}
	*f = flexInt(n)
	return nil
}

// ChapterMeta 目录条目（item_id 为番茄章节 ID，正文拉取的主键）
type ChapterMeta struct {
	ItemID string
	Index  int
	Title  string
}

type bookInfo struct {
	BookName       string  `json:"bookName"`
	Author         string  `json:"author"`
	Description    string  `json:"description"`
	CoverURL       string  `json:"coverUrl"`
	CreationStatus string  `json:"creationStatus"` // "1"=已完结
	WordNumber     string  `json:"wordNumber"`
	TotalChapters  flexInt `json:"totalChapters"`
}

// ─── 内部请求 ────────────────────────────────────────────────────────

func (c *Client) getJSON(path string, out any) error {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 2 * time.Second) // 上游偶发 GZIP/网络抖动，退避重试
		}
		if lastErr = c.getJSONOnce(path, out); lastErr == nil {
			return nil
		}
	}
	return lastErr
}

func (c *Client) getJSONOnce(path string, out any) error {
	resp, err := c.HTTP.Get(c.BaseURL + path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unidbg %s: HTTP %d", path, resp.StatusCode)
	}
	var env struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return fmt.Errorf("unidbg %s: %w", path, err)
	}
	if env.Code != 0 {
		return fmt.Errorf("unidbg %s: code=%d %s", path, env.Code, env.Message)
	}
	if out != nil && len(env.Data) > 0 {
		return json.Unmarshal(env.Data, out)
	}
	return nil
}

func (c *Client) postJSON(path string, req any, out any) error {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 2 * time.Second)
		}
		if lastErr = c.postJSONOnce(path, req, out); lastErr == nil {
			return nil
		}
	}
	return lastErr
}

func (c *Client) postJSONOnce(path string, req any, out any) error {
	raw, err := json.Marshal(req)
	if err != nil {
		return err
	}
	resp, err := c.HTTP.Post(c.BaseURL+path, "application/json", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unidbg %s: HTTP %d", path, resp.StatusCode)
	}
	var env struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return fmt.Errorf("unidbg %s: %w", path, err)
	}
	if env.Code != 0 {
		return fmt.Errorf("unidbg %s: code=%d %s", path, env.Code, env.Message)
	}
	if out != nil && len(env.Data) > 0 {
		return json.Unmarshal(env.Data, out)
	}
	return nil
}

// ─── 数据接口 ────────────────────────────────────────────────────────

// Search App 协议搜索（比网页搜索全，且无网页端风控限流）
func (c *Client) Search(query string, count int) ([]Book, error) {
	var out struct {
		Books []searchBook `json:"books"`
	}
	err := c.getJSON(fmt.Sprintf("/api/fqsearch/books?query=%s&count=%d", url.QueryEscape(query), count), &out)
	if err != nil {
		return nil, err
	}
	books := make([]Book, 0, len(out.Books))
	for _, b := range out.Books {
		books = append(books, Book{BookID: b.BookID, BookName: b.BookName, Author: b.Author, Description: b.Description})
	}
	return books, nil
}

// Directory 完整目录（含每章 item_id）
func (c *Client) Directory(bookID string) ([]ChapterMeta, error) {
	var out struct {
		ItemDataList []directoryChapter `json:"item_data_list"`
	}
	if err := c.getJSON("/api/fqsearch/directory/"+bookID, &out); err != nil {
		return nil, err
	}
	metas := make([]ChapterMeta, 0, len(out.ItemDataList))
	for _, ch := range out.ItemDataList {
		metas = append(metas, ChapterMeta{ItemID: ch.ItemID, Index: int(ch.ChapterIndex) - 1, Title: ch.Title})
	}
	return metas, nil
}

// BookInfo 书籍信息（App 协议专端点，稳定返回；目录接口的 book_info 有缓存波动不用）
func (c *Client) BookInfo(bookID string) (*bookInfo, error) {
	var out bookInfo
	if err := c.getJSON("/api/fqnovel/book/"+bookID, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// ChapterContent 单章正文（txtContent 为解密后明文）
func (c *Client) ChapterContent(bookID, chapterID string) (string, error) {
	var out struct {
		TxtContent string `json:"txtContent"`
	}
	if err := c.getJSON("/api/fqnovel/chapter/"+bookID+"/"+chapterID, &out); err != nil {
		return "", err
	}
	return out.TxtContent, nil
}

// ─── 整本下载 ────────────────────────────────────────────────────────

// DownloadBook 批量拉取整本正文并增量写库（复用 scanner 的 TND 回填路径，
// App 阅读接口无需任何改动）。目录以 unidbg 实时返回为准。
func (c *Client) DownloadBook(db *database.DBStore, bookID int64, fid, title string) error {
	metas, err := c.Directory(fid)
	if err != nil {
		return fmt.Errorf("拉取目录: %w", err)
	}
	if len(metas) == 0 {
		return fmt.Errorf("目录为空")
	}

	done := 0
	for start := 0; start < len(metas); start += batchSize {
		end := start + batchSize
		if end > len(metas) {
			end = len(metas)
		}
		batch := metas[start:end]

		// 断点续传：已有正文的章节跳过，任务重试时只拉缺失部分（降低限流压力）
		var need []ChapterMeta
		for _, m := range batch {
			if m.Index < 0 {
				continue
			}
			if ch, err := db.GetChapter(bookID, m.Index); err == nil && strings.TrimSpace(ch.Content) != "" {
				done++
				continue
			}
			need = append(need, m)
		}
		if len(need) == 0 {
			continue
		}
		batch = need

		ids := make([]string, 0, len(batch))
		for _, m := range batch {
			ids = append(ids, m.ItemID)
		}
		var out struct {
			Chapters map[string]struct {
				ChapterName string `json:"chapterName"`
				TxtContent  string `json:"txtContent"`
			} `json:"chapters"`
		}
		if err := c.postJSON("/api/fqnovel/chapters/batch", map[string]any{
			"bookId":     fid,
			"chapterIds": ids,
		}, &out); err != nil {
			return fmt.Errorf("批量拉取 %d-%d: %w", start+1, end, err)
		}
		for _, m := range batch {
			txt := out.Chapters[m.ItemID].TxtContent
			if strings.TrimSpace(txt) == "" {
				continue // 单章失败不中断整本，缺失章由追更机制补
			}
			if err := db.UpsertChapterContent(bookID, m.Index, m.Title, txt); err != nil {
				return fmt.Errorf("写库 #%d: %w", m.Index+1, err)
			}
			done++
		}
		if end < len(metas) {
			time.Sleep(batchInterval)
		}
	}
	if done == 0 {
		return fmt.Errorf("未获取到任何正文")
	}
	return nil
}
