package tnd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"sync"
	"time"
)

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
