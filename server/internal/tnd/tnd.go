package tnd

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"sync"
	"time"
)

var errNeedLogin = errors.New("TND 需要登录")

// Client Tomato-Novel-Downloader 适配器（NAS Docker 部署，HTTP 对接）
//
// TND Web UI 可开启锁定模式（TOMATO_WEB_PASSWORD）：先 POST /api/login
// 拿会话 Cookie，再 POST /api/jobs 创建下载任务（任务异步执行）。
// TND 把整本下载为 TXT 放进共享下载目录，后端 scanner 周期扫描入库。
//
// 环境变量：
//   XS_TND_URL      —— TND 服务地址，如 http://tomato-novel-downloader:18423，留空禁用
//   XS_TND_PASSWORD —— TND Web UI 锁定密码（未启用锁定可留空）
type Client struct {
	BaseURL  string
	Password string
	HTTP     *http.Client

	mu sync.Mutex
}

func New(baseURL, password string) *Client {
	jar, _ := cookiejar.New(nil)
	return &Client{
		BaseURL:  baseURL,
		Password: password,
		HTTP:     &http.Client{Timeout: 15 * time.Second, Jar: jar},
	}
}

func (c *Client) Enabled() bool { return c.BaseURL != "" }

// login 锁定模式下获取会话 Cookie（CookieJar 自动保存，重复登录无害）
func (c *Client) login() error {
	if c.Password == "" {
		return fmt.Errorf("TND 已锁定但未配置密码（XS_TND_PASSWORD）")
	}
	body, _ := json.Marshal(map[string]string{"password": c.Password})
	resp, err := c.HTTP.Post(c.BaseURL+"/api/login", "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("TND 登录失败: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("TND 登录响应 %d", resp.StatusCode)
	}
	return nil
}

// RequestDownload 请求 TND 下载整本书：POST /api/jobs {"book_id": ...}（异步任务）
func (c *Client) RequestDownload(fanqieID, title string) error {
	if !c.Enabled() {
		return fmt.Errorf("TND 未配置（XS_TND_URL）")
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	post := func() (int, error) {
		body, _ := json.Marshal(map[string]string{"book_id": fanqieID})
		resp, err := c.HTTP.Post(c.BaseURL+"/api/jobs", "application/json", bytes.NewReader(body))
		if err != nil {
			return 0, err
		}
		defer resp.Body.Close()
		return resp.StatusCode, nil
	}

	code, err := post()
	if err != nil {
		return fmt.Errorf("TND 不可达: %w", err)
	}
	// 未登录/会话过期：登录后重试一次
	if code == http.StatusUnauthorized || code == http.StatusForbidden {
		if lerr := c.login(); lerr != nil {
			return lerr
		}
		if code, err = post(); err != nil {
			return fmt.Errorf("TND 不可达: %w", err)
		}
	}
	if code >= 400 {
		return fmt.Errorf("TND 响应 %d", code)
	}
	return nil
}

// CreateRangeJob 创建按章节范围下载的任务（from/to 为 1 基目录序），返回任务 ID。
// TND 任务完成后产物落在 books 挂载目录：<bookID>/status.json 与/或《书名》.epub；
// 范围任务不触发 auto_clear_dump，产物会保留。
func (c *Client) CreateRangeJob(fanqieID string, from, to int) (int64, error) {
	if !c.Enabled() {
		return 0, fmt.Errorf("TND 未配置（XS_TND_URL）")
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	type createOut struct {
		ID int64 `json:"id"`
	}
	post := func() (int64, error) {
		body, _ := json.Marshal(map[string]any{"book_id": fanqieID, "range_start": from, "range_end": to})
		resp, err := c.HTTP.Post(c.BaseURL+"/api/jobs", "application/json", bytes.NewReader(body))
		if err != nil {
			return 0, fmt.Errorf("TND 不可达: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			return 0, errNeedLogin
		}
		if resp.StatusCode >= 400 {
			return 0, fmt.Errorf("TND 响应 %d", resp.StatusCode)
		}
		var out createOut
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return 0, err
		}
		if out.ID == 0 {
			return 0, fmt.Errorf("TND 任务创建失败（无 id）")
		}
		return out.ID, nil
	}
	id, err := post()
	if err == errNeedLogin {
		if lerr := c.login(); lerr != nil {
			return 0, lerr
		}
		id, err = post()
	}
	return id, err
}

// WaitJob 轮询任务直到结束，返回最终 state（done/failed/cancelled/...）
func (c *Client) WaitJob(id int64, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for {
		var out struct {
			Items []struct {
				ID    int64  `json:"id"`
				State string `json:"state"`
			} `json:"items"`
		}
		err := c.getJSON("/api/jobs?id="+strconv.FormatInt(id, 10), &out)
		if err == errNeedLogin {
			if lerr := c.login(); lerr != nil {
				return "", lerr
			}
			err = c.getJSON("/api/jobs?id="+strconv.FormatInt(id, 10), &out)
		}
		if err == nil {
			for _, it := range out.Items {
				if it.ID == id {
					switch it.State {
					case "done", "failed", "error", "cancelled":
						return it.State, nil
					}
				}
			}
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("TND 任务 %d 等待超时", id)
		}
		time.Sleep(time.Second)
	}
}

// getJSON 带 401 标记的 GET（errNeedLogin 由调用方处理重登录）
func (c *Client) getJSON(path string, out any) error {
	resp, err := c.HTTP.Get(c.BaseURL + path)
	if err != nil {
		return fmt.Errorf("TND 不可达: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return errNeedLogin
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return fmt.Errorf("TND 限流（429）")
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("TND 响应 %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// SearchBook TND 搜索结果条目（Raw 已拍平常用字段；上游搜索接口直连番茄官方
// 基础设施，实测一次约返回 20 条）
type SearchBook struct {
	BookID         string
	Title          string
	Author         string
	Abstract       string
	ThumbURL       string
	WordNumber     int64  // 原始字数值，0 = 缺失
	CreationStatus string // 搜索接口语义：1=完结 0=连载（同详情接口，与书城卡相反，10/05 对照详情实测）
	ReadCntText    string // 形如 "1.4万人在读"，也可能是 "潜力好书" 等运营文案
	ReadCount      int64  // 在读人数原始值，0 = 缺失
}

// Search TND 搜索：GET /api/search?q=（上游无翻页/条数参数，只够服务首页）。
// 锁定模式下 401/会话过期自动重登录重试一次。
func (c *Client) Search(query string) ([]SearchBook, error) {
	if !c.Enabled() {
		return nil, fmt.Errorf("TND 未配置（XS_TND_URL）")
	}
	var out struct {
		Items []struct {
			BookID string `json:"book_id"`
			Title  string `json:"title"`
			Author string `json:"author"`
			Raw    struct {
				Abstract       string      `json:"abstract"`
				ThumbURL       string      `json:"thumb_url"`
				WordNumber     json.Number `json:"word_number"`
				CreationStatus json.Number `json:"creation_status"`
				ReadCntText    string      `json:"read_cnt_text"`
				ReadCount      json.Number `json:"read_count"`
			} `json:"raw"`
		} `json:"items"`
		Error string `json:"error"`
	}
	q := "/api/search?q=" + url.QueryEscape(query)
	err := c.getJSON(q, &out)
	if err == errNeedLogin {
		if lerr := c.login(); lerr != nil {
			return nil, lerr
		}
		err = c.getJSON(q, &out)
	}
	if err != nil {
		return nil, err
	}
	if out.Error != "" {
		return nil, fmt.Errorf("TND 搜索: %s", out.Error)
	}
	books := make([]SearchBook, 0, len(out.Items))
	for _, it := range out.Items {
		b := SearchBook{
			BookID: it.BookID, Title: it.Title, Author: it.Author,
			Abstract: it.Raw.Abstract, ThumbURL: it.Raw.ThumbURL,
			CreationStatus: it.Raw.CreationStatus.String(),
			ReadCntText:    it.Raw.ReadCntText,
		}
		b.WordNumber, _ = it.Raw.WordNumber.Int64()
		b.ReadCount, _ = it.Raw.ReadCount.Int64()
		books = append(books, b)
	}
	return books, nil
}

