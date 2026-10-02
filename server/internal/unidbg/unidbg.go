// Package unidbg 对接 zero199901/fqnovel-unidbg 签名服务（NAS/本机 Java 进程）。
// 该服务内置番茄海外版 SO，用 unidbg 模拟执行让 SO 自算 X-Helios/X-Medusa，
// 服务端直接接受——无需手机、无需安卓模拟器。 XS_UNIDBG_URL 留空禁用。
package unidbg

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
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

// postRaw POST JSON 并返回原始响应体（上游业务码由调用方自行解析）
func (c *Client) postRaw(path string, req any) ([]byte, error) {
	raw, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	var lastBody []byte
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 2 * time.Second)
		}
		resp, err := c.HTTP.Post(c.BaseURL+path, "application/json", bytes.NewReader(raw))
		if err != nil {
			lastErr = err
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("unidbg %s: HTTP %d", path, resp.StatusCode)
			continue
		}
		return body, nil
	}
	return lastBody, lastErr
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
	err := c.getJSON(fmt.Sprintf("/api/fqsearch/books?query=%s&count=%d&tabType=1", url.QueryEscape(query), count), &out)
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

// ─── App 书城 feed（bookmall/tab，与番茄 App 首页同源）────────────────

// bookmallBusinessQuery bookmall/tab 的业务参数（公共设备参数由 unidbg 服务拼装）。
// 取自 2026-09-29 真机抓包模板（_reference/fqemu/real_bookmall_url.txt），已按 App 格式编码。
const bookmallBusinessQuery = `unlimited_short_series_change_type=0&last_search_query_from_rec=false&auth_aweme=false&migration_top_tab_enable=false&is_horizontal_screen=false&ecom_refresh_type=0&last_tab_index=0&page_entry_time=0&ecom_impression_start_time=0&video_tab_cold_start=0&stream_count=%5B%7B%22scene%22%3A%221%22%2C%22StreamCount%22%3A1%2C%22StreamType%22%3A%221%22%7D%5D&refresh_action_info=%7B%22has_active_refresh%22%3Afalse%2C%22refresh_type%22%3A3%7D&offset=0&tab_type=-1&pad_column_detail=0&is_video_feed_tab_first_request_cold_start=false&first_use_category_select=false&cold_start_is_double_gd=false&session_uuid=9452f513-4c3b-42c2-9ad1-8b8c1f6a97dd&classic_tab_style=v3&device_level=3&image_shrink_datas_str=W3siaW1hZ2VfdHlwZSI6MSwiaW1hZ2Vfd2lkdGgiOjUzOSwic2hyaW5rX3R5cGUiOjF9LHsiaW1h%0AZ2VfdHlwZSI6MiwiaW1hZ2Vfd2lkdGgiOjM1OSwic2hyaW5rX3R5cGUiOjJ9LHsiaW1hZ2VfdHlw%0AZSI6MywiaW1hZ2Vfd2lkdGgiOjEwNzksInNocmlua190eXBlIjozfSx7ImltYWdlX3R5cGUiOjQs%0AImltYWdlX3dpZHRoIjo5NCwic2hyaW5rX3R5cGUiOjR9XQ%3D%3D%0A&last_tab_type=2&enable_search_box_collapse=false&lore_tab_style=v5&book_id=0&extra=5&cold_start_session=0&auth_backward=true&bottom_tab_type_list=0%2C7%2C2%2C3%2C4&last_session_video_tab_type=0&unlimited_short_series_next_offset=0&client_fetch_unlimited_mode=1&bottom_tab_type=0&screen_width_px=1079&has_video_cache=false&landing_bottom_tab_type=0&disable_digg_stat=false&req_rank_category_id=0&pad_column_cover=0&tab_index=0&req_rank_algo=0&biz_config_ctx_infos=eyJtIjp7IjAiOiIzIiwiMSI6IjU5MWQ4MGQ4MjI4ZmM1OWYiLCIyIjoiNmM3ZTc1OGUwZWM4YzM3ZCIsIjMiOiI0M2JkY2NkYTM5ODkxNzA1IiwiNCI6IjM2NjNlNDEyODgwNGU4NDEiLCI1IjoiYzAwN2I3OGJmMTBjZWM4YyIsIjYiOiJlNzkzYTlhZDQ3ODZiYzljIiwiNyI6IjciLCI4IjoiMjEiLCI5IjoiMTgiLCJBIjoiMTQiLCJCIjoiOCIsIkMiOiIxMyIsIkQiOiIzNiIsIkUiOiIxMyIsIkYiOiIyMyIsImEiOiIxMiIsImIiOiIyMSIsImMiOiIyNyIsImQiOiI4OCIsImUiOiIzMiIsImYiOiIxMTkiLCJnIjoiNDgiLCJoIjoiOSIsImkiOiIxMiIsImoiOiIzNSIsImsiOiIyOCIsImwiOiIxOSIsIm0iOiIxNCIsIm4iOiIxMyIsIm8iOiIxMCIsInAiOiIyMSIsInEiOiI3OCIsInIiOiIxMTYiLCJzIjoiMTgiLCJ0IjoiMTE2IiwidSI6IjQwIiwidiI6IjczIiwidyI6IjExIiwieCI6IjM0IiwieSI6IjEwOCIsInoiOiIyNyJ9fQ%3D%3D&client_req_type=3&after_genre_preference_popup=0&ug_task_params=%7B%22operation_type%22%3A3%2C%22is_new_day%22%3Afalse%2C%22redpack_continue_show_days%22%3A0%2C%22open_card_continue_not_click_days%22%3A0%2C%22is_first_launch%22%3Afalse%2C%22redpack_launch_show_count%22%3A0%2C%22open_card_daily_show_count%22%3A0%2C%22last_cold_start_diff_days%22%3A0%7D&normal_session_cnt_in_day=12&cold_start_session_cnt_in_day=7&sys_mini_window=0&app_mini_window=0&normal_session_id=7378f888-5905-4d2b-ab75-389fd4d18d4a%230&har_status=0&cold_start_session_id=5d0d31b1-9609-4b27-b008-cb44a184b021&cold_start_session_cnt_in_life=7&charging=0&normal_session_cnt_in_life=12&is_power_save_mode=0&app_dark_mode=0&screen_brightness=1&battery_pct=0&down_speed=4300&sys_dark_mode=0&font_scale=100&network_type=1&current_volume=1&recommend_extra=eyJyZWNlbnRfZGlzbGlrZV9naWQiOltdLCJzZXNzaW9uX2FwcF9zdGF5X3RpbWUiOjB9%0A`

// FeedBook App 推荐流中的一本书
type FeedBook struct {
	BookID    string `json:"book_id"`
	BookName  string `json:"book_name"`
	Author    string `json:"author"`
	Abstract  string `json:"abstract"`
	Category  string `json:"category"`
	ThumbURL  string `json:"thumb_url"`
	ReadCount string `json:"read_count"` // read_cnt_text，形如 "3292人在读"
	RankScore string `json:"rank_score"` // 形如 "9243万热度"
	Score     string `json:"score"`
	Tags      string `json:"tags"`
	SerialNum string `json:"serial_count"`
	Finished  bool   `json:"finished"`
}

// FeedSection App 书城 feed 的一个模块（「排行榜」「猜你喜欢」等）
type FeedSection struct {
	Title    string     `json:"title"`
	Subtitle string     `json:"subtitle,omitempty"`
	Books    []FeedBook `json:"books"`
}

// HomeFeed 拉取 App 书城首页 feed（推荐 tab：排行榜 + 猜你喜欢等模块）。
// 与番茄 App 同源——真实排行榜、个性化推荐流。
func (c *Client) HomeFeed() ([]FeedSection, error) {
	query := randomizeSessionParams(bookmallBusinessQuery)
	body, err := c.postRaw("/api/fqapp/fetch", map[string]string{
		"path":  "/reading/bookapi/bookmall/tab/v",
		"query": query,
	})
	if err != nil {
		return nil, err
	}
	var env struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("feed 响应解析: %w", err)
	}
	if env.Code != 0 {
		// 设备风控（ILLEGAL_ACCESS）→ 自动轮换设备后重试一次
		if isRiskControl(env.Code, env.Message) {
			rerr := c.recoverDevice()
			if rerr == nil {
				return c.HomeFeed()
			}
			return nil, fmt.Errorf("feed 上游 code=%d %s（设备已自动轮换但仍失败: %v）",
				env.Code, env.Message, rerr)
		}
		return nil, fmt.Errorf("feed 上游 code=%d %s", env.Code, env.Message)
	}
	var data struct {
		TabItem []struct {
			Title    string `json:"title"`
			CellData []struct {
				CellName  string `json:"cell_name"`
				CellAlias string `json:"cell_alias"`
				CellData  []struct {
					BookData []struct {
						BookID      string `json:"book_id"`
						BookName    string `json:"book_name"`
						Author      string `json:"author"`
						Abstract    string `json:"abstract"`
						Category    string `json:"category"`
						ThumbURL    string `json:"thumb_url"`
						ReadCount   string `json:"read_count"`
						RankScore   string `json:"rank_score"`
						Score       string `json:"score"`
						Tags        string `json:"tags"`
						SerialCount string `json:"serial_count"`
						Creation    string `json:"creation_status"`
					} `json:"book_data"`
				} `json:"cell_data"`
			} `json:"cell_data"`
		} `json:"tab_item"`
	}
	if err := json.Unmarshal(env.Data, &data); err != nil {
		return nil, fmt.Errorf("feed 结构解析: %w", err)
	}

	// 取「推荐」tab（App 首页默认），退而求其次取第一个有 cell 的 tab
	var tab *struct {
		Title    string `json:"title"`
		CellData []struct {
			CellName  string `json:"cell_name"`
			CellAlias string `json:"cell_alias"`
			CellData  []struct {
				BookData []struct {
					BookID      string `json:"book_id"`
					BookName    string `json:"book_name"`
					Author      string `json:"author"`
					Abstract    string `json:"abstract"`
					Category    string `json:"category"`
					ThumbURL    string `json:"thumb_url"`
					ReadCount   string `json:"read_count"`
					RankScore   string `json:"rank_score"`
					Score       string `json:"score"`
					Tags        string `json:"tags"`
					SerialCount string `json:"serial_count"`
					Creation    string `json:"creation_status"`
				} `json:"book_data"`
			} `json:"cell_data"`
		} `json:"cell_data"`
	}
	for i := range data.TabItem {
		if data.TabItem[i].Title == "推荐" && len(data.TabItem[i].CellData) > 0 {
			tab = &data.TabItem[i]
			break
		}
	}
	if tab == nil {
		for i := range data.TabItem {
			if len(data.TabItem[i].CellData) > 0 {
				tab = &data.TabItem[i]
				break
			}
		}
	}
	if tab == nil {
		return nil, fmt.Errorf("feed 中无可用 tab")
	}

	sections := make([]FeedSection, 0, len(tab.CellData))
	for _, cell := range tab.CellData {
		sec := FeedSection{Title: cell.CellName, Subtitle: cell.CellAlias, Books: []FeedBook{}}
		for _, inner := range cell.CellData {
			for _, b := range inner.BookData {
				if b.BookID == "" || b.BookName == "" {
					continue
				}
				sec.Books = append(sec.Books, FeedBook{
					BookID:    b.BookID,
					BookName:  b.BookName,
					Author:    b.Author,
					Abstract:  b.Abstract,
					Category:  b.Category,
					ThumbURL:  b.ThumbURL,
					ReadCount: b.ReadCount,
					RankScore: b.RankScore,
					Score:     b.Score,
					Tags:      b.Tags,
					SerialNum: b.SerialCount,
					Finished:  b.Creation == "1",
				})
			}
		}
		if len(sec.Books) > 0 {
			sections = append(sections, sec)
		}
	}
	return sections, nil
}

// ─── 设备风控自动恢复 ────────────────────────────────────────────────

var (
	recoverMu    sync.Mutex
	lastRecovery time.Time
)

func isRiskControl(code int, message string) bool {
	if code == 110 {
		return true
	}
	m := strings.ToUpper(message)
	return strings.Contains(m, "ILLEGAL_ACCESS") || strings.Contains(m, "设备信息风控") ||
		strings.Contains(m, "请手动更新设备信息")
}

// recoverDevice 设备被风控时的自动轮换：注册新设备 → 落盘配置 → 重启服务 → 等待就绪。
// 10 分钟内最多触发一次；重启依赖容器 restart: unless-stopped 策略拉起。
func (c *Client) recoverDevice() error {
	recoverMu.Lock()
	defer recoverMu.Unlock()
	if time.Since(lastRecovery) < 10*time.Minute {
		return fmt.Errorf("设备轮换冷却中（10 分钟内已尝试过）")
	}
	lastRecovery = time.Now()

	log.Printf("[unidbg] 检测到设备风控，开始自动轮换设备…")
	regRaw, err := c.postRaw("/api/device/register", map[string]any{})
	if err != nil {
		return fmt.Errorf("register: %w", err)
	}
	var reg struct {
		Success    bool           `json:"success"`
		DeviceInfo map[string]any `json:"deviceInfo"`
	}
	if err := json.Unmarshal(regRaw, &reg); err != nil {
		return fmt.Errorf("register 解析: %w", err)
	}
	if !reg.Success || reg.DeviceInfo == nil {
		return fmt.Errorf("register 失败: %.120s", string(regRaw))
	}
	newID, _ := reg.DeviceInfo["deviceId"].(string)
	log.Printf("[unidbg] 新设备已注册 deviceId=%s", newID)

	// 落盘 yml（容器内 ./config/application.yml，挂载卷持久化）
	if _, err := c.postRaw("/api/device/update-config", reg.DeviceInfo); err != nil {
		log.Printf("[unidbg] update-config 警告: %v", err)
	}

	// 重启 JVM（docker restart: unless-stopped 自动拉起）；连接中断属预期
	_, _ = c.postRaw("/api/device/restart", map[string]any{})

	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(4 * time.Second)
		resp, err := c.HTTP.Get(c.BaseURL + "/api/fq-signature/health")
		if err == nil {
			resp.Body.Close()
			log.Printf("[unidbg] 服务已就绪（新设备）")
			return nil
		}
	}
	return fmt.Errorf("重启后健康检查超时")
}

// randomizeSessionParams 每次请求随机化会话参数，模拟真实 App 的会话行为，
// 降低静态参数重放触发设备风控的概率。
func randomizeSessionParams(q string) string {
	uid := newUUID()
	ts := fmt.Sprintf("%d", time.Now().UnixMilli())
	q = replaceParam(q, "session_uuid", uid)
	q = replaceParam(q, "cold_start_session_id", uid)
	q = replaceParam(q, "normal_session_id", uid+"%230")
	q = replaceParam(q, "page_entry_time", ts)
	q = replaceParam(q, "ecom_impression_start_time", ts)
	return q
}

var paramRe = regexp.MustCompile(`([a-z_]+)=[^&]*`)

func replaceParam(q, key, val string) string {
	return paramRe.ReplaceAllStringFunc(q, func(m string) string {
		if strings.HasPrefix(m, key+"=") {
			return key + "=" + val
		}
		return m
	})
}

func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // RFC 4122 variant
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}
