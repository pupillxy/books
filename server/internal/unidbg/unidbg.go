// Package unidbg 对接 zero199901/fqnovel-unidbg 签名服务（NAS/本机 Java 进程）。
// 该服务内置番茄海外版 SO，用 unidbg 模拟执行让 SO 自算 X-Helios/X-Medusa，
// 服务端直接接受——无需手机、无需安卓模拟器。 XS_UNIDBG_URL 留空禁用。
package unidbg

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
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

// Search App 协议搜索（比网页搜索全，且无网页端风控限流）。
// offset 分页与官方 App 一致（search/tab/v，passback=offset，Java 端内部组装）。
func (c *Client) Search(query string, count, offset int) ([]Book, error) {
	var out struct {
		Books []searchBook `json:"books"`
	}
	err := c.getJSON(fmt.Sprintf("/api/fqsearch/books?query=%s&count=%d&offset=%d&tabType=1",
		url.QueryEscape(query), count, offset), &out)
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

// ChapterContentsBatch 在线读正文批量获取（解密后明文，key=chapterID）。
// 纪律：单章接口 /api/fqnovel/chapter 高频必触发设备风控，在线读一律走 batch——
// 10/03 事故实测：逐章单章请求把有资历设备的正文通道再次打标。
func (c *Client) ChapterContentsBatch(bookID string, itemIDs []string) (map[string]string, error) {
	out := map[string]string{}
	if len(itemIDs) == 0 {
		return out, nil
	}
	var resp struct {
		Chapters map[string]struct {
			TxtContent string `json:"txtContent"`
		} `json:"chapters"`
	}
	if err := c.postJSON("/api/fqnovel/chapters/batch", map[string]any{
		"bookId":     bookID,
		"chapterIds": itemIDs,
	}, &resp); err != nil {
		return nil, err
	}
	for _, id := range itemIDs {
		if m, ok := resp.Chapters[id]; ok && strings.TrimSpace(m.TxtContent) != "" {
			out[id] = m.TxtContent
		}
	}
	return out, nil
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
	BookID     string `json:"book_id"`
	BookName   string `json:"book_name"`
	Author     string `json:"author"`
	Abstract   string `json:"abstract"`
	Category   string `json:"category"`
	ThumbURL   string `json:"thumb_url"`
	ReadCount  string `json:"read_count"`  // read_cnt_text，形如 "3292人在读"
	RankScore  string `json:"rank_score"` // 形如 "9243万热度"
	Score      string `json:"score"`
	Tags       string `json:"tags"`
	SerialNum  string `json:"serial_count"`
	WordNumber string `json:"word_number,omitempty"` // 原始字数值（书城卡数据），App 自行格式化
	Finished   bool   `json:"finished"`
}

// FeedSection App 书城 feed 的一个模块（「排行榜」「猜你喜欢」等）
type FeedSection struct {
	Title    string     `json:"title"`
	Subtitle string     `json:"subtitle,omitempty"`
	Books    []FeedBook `json:"books"`
	// 猜你喜欢个性化瀑布流的分页游标（仅 feed cell 携带，10/03 抓包实测）
	CellID     string `json:"cell_id,omitempty"`
	PlanID     string `json:"plan_id,omitempty"`
	AlgoType   int    `json:"algo_type,omitempty"`
	NextOffset int    `json:"next_offset,omitempty"`
}

// feedBookSrc bookmall cell 里的书籍源字段（HomeFeed/FeedPage 共用）
type feedBookSrc struct {
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
}

// tabCell 书城 feed 的一个 cell（模块卡/瀑布流卡片，可任意嵌套）
type tabCell struct {
	CellName  string        `json:"cell_name"`
	CellAlias string        `json:"cell_alias"`
	CellID    string        `json:"cell_id"`
	PlanID    string        `json:"plan_id"`
	AlgoType  int           `json:"algo_type"`
	Algo      int           `json:"algo"`
	BookData  []feedBookSrc `json:"book_data"`
	CellData  []tabCell     `json:"cell_data"`
}

// HomeFeed 拉取 App 书城首页 feed（推荐 tab：排行榜 + 猜你喜欢等模块）。
// 与番茄 App 同源——真实排行榜、个性化推荐流。
func (c *Client) HomeFeed() ([]FeedSection, error) {
	query := randomizeSessionParams(bookmallBusinessQuery)
	data, err := c.fetchApp("/reading/bookapi/bookmall/tab/v", query)
	if err != nil {
		return nil, err
	}
	var parsed struct {
		TabItem []struct {
			Title    string    `json:"title"`
			CellData []tabCell `json:"cell_data"`
		} `json:"tab_item"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil {
		return nil, fmt.Errorf("feed 结构解析: %w", err)
	}

	// 取「推荐」tab（App 首页默认），退而求其次取第一个有 cell 的 tab
	tabIdx := -1
	for i := range parsed.TabItem {
		if parsed.TabItem[i].Title == "推荐" && len(parsed.TabItem[i].CellData) > 0 {
			tabIdx = i
			break
		}
	}
	if tabIdx < 0 {
		for i := range parsed.TabItem {
			if len(parsed.TabItem[i].CellData) > 0 {
				tabIdx = i
				break
			}
		}
	}
	if tabIdx < 0 {
		return nil, fmt.Errorf("feed 中无可用 tab")
	}

	cells := parsed.TabItem[tabIdx].CellData
	sections := make([]FeedSection, 0, len(cells))
	for ci := range cells {
		cell := &cells[ci]
		sec := FeedSection{Title: cell.CellName, Subtitle: cell.CellAlias, Books: []FeedBook{}}
		var walk func(nodes []tabCell)
		walk = func(nodes []tabCell) {
			for _, inner := range nodes {
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
						// 书城卡 creation_status：0=完结 1=连载（与详情接口语义相反，10/04 定案）
						Finished: b.Creation == "0",
					})
				}
				walk(inner.CellData)
			}
		}
		walk(cell.CellData)
		// 猜你喜欢个性化瀑布流：挂分页游标（offset 起点 = 首屏内嵌卡片数，含视频卡）
		if cell.CellID != "" && (cell.AlgoType == 167 || cell.Algo == 167) {
			sec.CellID = cell.CellID
			sec.PlanID = cell.PlanID
			sec.AlgoType = 167
			sec.NextOffset = countLeafCards(cell.CellData)
		}
		if len(sec.Books) > 0 || sec.CellID != "" {
			sections = append(sections, sec)
		}
	}
	return sections, nil
}

// countLeafCards 递归统计 cell 子树的叶子卡片数（书卡/视频卡都算），与上游 offset 计数对齐
func countLeafCards(cells []tabCell) int {
	n := 0
	for _, c := range cells {
		if len(c.CellData) == 0 {
			n++
		} else {
			n += countLeafCards(c.CellData)
		}
	}
	return n
}

// ─── App 协议榜单（2026-10-03 官方 App 抓包对齐，档案 _reference/fqemu/capture_xiaoshuo_1003）───

// fetchApp 通用 App 协议回放：通过 /api/fqapp/fetch 代签代发任意 bookapi 端点。
// query 只带业务参数——设备参数（iid/device_id/cdid 等）由 Java 服务注入，
// 调用方带同名参数会覆盖设备配置导致签名失效。设备风控时与 HomeFeed 同策略自愈。
func (c *Client) fetchApp(path, query string) (json.RawMessage, error) {
	body, err := c.postRaw("/api/fqapp/fetch", map[string]string{"path": path, "query": query})
	if err != nil {
		return nil, err
	}
	var env struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("app fetch %s 响应解析: %w", path, err)
	}
	if env.Code != 0 {
		if isRiskControl(env.Code, env.Message) {
			if os.Getenv("XS_UNIDBG_ROTATE") != "1" {
				return nil, fmt.Errorf("app fetch %s 上游 code=%d %s（设备风控，冷却后自愈）", path, env.Code, env.Message)
			}
			if rerr := c.recoverDevice(); rerr == nil {
				return c.fetchApp(path, query)
			}
		}
		return nil, fmt.Errorf("app fetch %s 上游 code=%d %s", path, env.Code, env.Message)
	}
	return env.Data, nil
}

// AppRank 官方榜单（algo_type 即官方协议榜单 ID；main_algo_type 响应映射 2026-10-03 实测）
type AppRank struct {
	Algo int
	Name string
}

// AppRanks 完整榜单页左栏全量（web_page_key=common-rank-list-v1）
var AppRanks = []AppRank{
	{101, "推荐榜"}, {100, "完本榜"}, {108, "新书榜"}, {207, "书友榜"}, {109, "追更榜"},
	{102, "黑马榜"}, {200, "巅峰榜"}, {208, "书荒榜"}, {188, "礼物榜"}, {111, "阅读榜"}, {205, "作者榜"},
}

// AppRankByAlgo 按 algo_type 查榜单名，未知返回空
func AppRankByAlgo(algo int) string {
	for _, r := range AppRanks {
		if r.Algo == algo {
			return r.Name
		}
	}
	return ""
}

// rankPageQuery 完整榜单整页业务参数模板（cell/change/v1，web_page_key=common-rank-list-v1）。
// 一次返回 top30（offset 无效，has_more 恒 false）；algo_type/gender_list_type 按需替换。
// gender_list_type: 1=男生榜 0=女生榜。cell_id 为榜单卡 cell 实例 ID（服务端内容 ID，跨设备稳定）。
const rankPageQuery = `cell_gender=2&main_algo_type=101%2C100%2C108%2C207%2C109%2C102%2C200%2C208%2C188%2C111%2C205&book_type=0&genre_tab_list=2%2C3%2C4%2C5%2C6%2C7&rank_sub_info_id=2&offset=0&genre_tab=2&gender_list_type=1&change_type=1&web_page_key=common-rank-list-v1&algo_type=100&main_algo_name=%E6%8E%A8%E8%8D%90%E6%A6%9C%2C%E5%AE%8C%E6%9C%AC%E6%A6%9C%2C%E6%96%B0%E4%B9%A6%E6%A6%9C%2C%E4%B9%A6%E5%8F%8B%E6%A6%9C%2C%E8%BF%BD%E6%9B%B4%E6%A6%9C%2C%E9%BB%91%E9%A9%AC%E6%A6%9C%2C%E5%B7%85%E5%B3%B0%E6%A6%9C%2C%E4%B9%A6%E8%8D%92%E6%A6%9C%2C%E7%A4%BC%E7%89%A9%E6%A6%9C%2C%E9%98%85%E8%AF%BB%E6%A6%9C%2C%E4%BD%9C%E8%80%85%E6%A6%9C&list_type=daily&web_page_version_code=1&tab_type=2&list_gender=1&limit=12&rank_list_style_type=1&genre_tab_name_list=%E5%B0%8F%E8%AF%B4%2C%E5%87%BA%E7%89%88%2C%E7%9F%AD%E5%89%A7%2C%E6%BC%AB%E5%89%A7%2C%E5%90%AC%E4%B9%A6%2C%E7%9F%AD%E7%AF%87&support_gender_list=true&cell_id=7098235271900037133&rank_sub_info_type=0&client_req_type=4&normal_session_cnt_in_day=7&gender=2&cold_start_session_cnt_in_day=3&sys_mini_window=1&app_mini_window=0&normal_session_id=366c223e-728b-45bd-b44c-31d570cc59d5%231&har_status=0&cold_start_session_id=9252d33c-edd5-4be4-8cec-9ab7af7c47c4&cold_start_session_cnt_in_life=21&charging=0&normal_session_cnt_in_life=404&is_power_save_mode=0&app_dark_mode=0&screen_brightness=102&battery_pct=100&down_speed=4300&sys_dark_mode=0&font_scale=100&network_type=1&current_volume=33&recommend_extra=eyJyZWNlbnRfZGlzbGlrZV9naWQiOltdLCJzZXNzaW9uX2FwcF9zdGF5X3RpbWUiOjB9%0A`

// RankPageBooks 拉取一份完整榜单（官方 App 协议）。genderList: "1"=男生榜 "0"=女生榜。
// 返回整批（约 30 本），分页由调用方切片。
func (c *Client) RankPageBooks(algo int, genderList string) ([]FeedBook, error) {
	q := replaceParam(rankPageQuery, "algo_type", strconv.Itoa(algo))
	if genderList == "0" {
		q = replaceParam(q, "gender_list_type", "0")
	}
	q = randomizeSessionParams(q)
	data, err := c.fetchApp("/reading/bookapi/bookmall/cell/change/v1/", q)
	if err != nil {
		return nil, err
	}
	return parseCellViewBooks(data)
}

// mallCell bookmall cell/change 响应里的 cell 节点（可嵌套）
type mallCell struct {
	CellName string     `json:"cell_name"`
	BookData []mallBook `json:"book_data"`
	CellData []mallCell `json:"cell_data"`
}

// mallBook 榜单书籍条目（字段与 bookmall/tab 同名族，另有 read_cnt_text 人类可读在读数）
type mallBook struct {
	BookID      string `json:"book_id"`
	BookName    string `json:"book_name"`
	Author      string `json:"author"`
	Abstract    string `json:"abstract"`
	Category    string `json:"category"`
	ThumbURL    string `json:"thumb_url"`
	ReadCount   string `json:"read_count"`
	ReadCntText string `json:"read_cnt_text"`
	RankScore   string `json:"rank_score"`
	Score       string `json:"score"`
	Tags        string `json:"tags"`
	SerialCount string `json:"serial_count"`
	UpdateTag   *string `json:"update_tag"`
	WordNumber  flexInt `json:"word_number"`
	Creation    string `json:"creation_status"`
}

func (m mallBook) toFeedBook() FeedBook {
	rc := m.ReadCntText
	if rc == "" {
		rc = m.ReadCount
	}
	// 书城卡 creation_status 语义与详情接口相反：0=完结 1=连载。
	// 10/04 定案：selected_items=finished 筛选返回 12 本全为 0，完本榜 30 本全 0，
	// 连载中的漫画（周更）为 1。
	return FeedBook{
		BookID: m.BookID, BookName: m.BookName, Author: m.Author,
		Abstract: m.Abstract, Category: m.Category, ThumbURL: m.ThumbURL,
		ReadCount: rc, RankScore: m.RankScore, Score: m.Score, Tags: m.Tags,
		SerialNum: m.SerialCount, WordNumber: wordNumberStr(int(m.WordNumber)),
		Finished: m.Creation == "0",
	}
}

// wordNumberStr 字数值转字符串；0 视为缺失返回空
func wordNumberStr(n int) string {
	if n <= 0 {
		return ""
	}
	return strconv.Itoa(n)
}

// parseCellViewBooks 展开 cell/change 响应 data.cell_view 里的全部书籍。
// 入参为 /api/fqapp/fetch 剥壳后的 data 对象。book_data 可能挂在 cell_view 自己身上
// （漫画频道实测）也可能嵌在 cell_data 子树里（小说频道/榜单实测），从 cell_view
// 节点本身开始递归两种形状通吃。
func parseCellViewBooks(data json.RawMessage) ([]FeedBook, error) {
	var env struct {
		CellView mallCell `json:"cell_view"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("榜单结构解析: %w", err)
	}
	var out []FeedBook
	var walk func(cells mallCell)
	walk = func(c mallCell) {
		for _, b := range c.BookData {
			if b.BookID != "" && b.BookName != "" {
				out = append(out, b.toFeedBook())
			}
		}
		for _, inner := range c.CellData {
			walk(inner)
		}
	}
	walk(env.CellView)
	if len(out) == 0 {
		return nil, fmt.Errorf("榜单无书籍数据")
	}
	return out, nil
}

// DefaultFeedCellID 推荐频道「猜你喜欢」feed cell 的服务端内容 ID（跨设备稳定）
const DefaultFeedCellID = "7011478717935386631"

// FeedPage 猜你喜欢瀑布流翻页（10/03 抓包实测）：cell/change/v，algo_type=167、tab_type=2、
// limit=10；offset 由上游 next_offset 驱动，起点 = tab/v 首屏内嵌卡片数（通常 12）。
// 视频卡（漫剧等）不含 book_data，被过滤后 books 可能少于卡片数，属正常。
func (c *Client) FeedPage(cellID, planID string, offset int) ([]FeedBook, int, bool, error) {
	q := fmt.Sprintf("change_type=0&limit=10&cell_id=%s&offset=%d&client_req_type=2&algo_type=167&tab_type=2&plan_id=%s",
		url.QueryEscape(cellID), offset, url.QueryEscape(planID))
	return cellChangeFeed(c, q, parseCellFeedPage, func(b []FeedBook) bool { return len(b) == 0 })
}

// cellChangeFeed 拉取 cell/change/v 并解析，空页立即重试一次。上游个性化会话
// 冷启动时偶发 code=0 空页（10/04 实测：书城「猜你喜欢」空闲后首拉必空、
// 秒级重试即恢复；空页原样透传会让客户端以 has_more=false 卡死成永久空白，
// 只能手动下拉恢复），重试仍空才按空页返回。
func cellChangeFeed[T any](c *Client, query string, parse func(json.RawMessage) (T, int, bool, error), isEmpty func(T) bool) (T, int, bool, error) {
	books, next, more, err := cellChangeOnce(c, query, parse)
	if err == nil && isEmpty(books) {
		time.Sleep(800 * time.Millisecond)
		if b2, n2, m2, err2 := cellChangeOnce(c, query, parse); err2 == nil && !isEmpty(b2) {
			return b2, n2, m2, nil
		}
	}
	return books, next, more, err
}

func cellChangeOnce[T any](c *Client, query string, parse func(json.RawMessage) (T, int, bool, error)) (T, int, bool, error) {
	data, err := c.fetchApp("/reading/bookapi/bookmall/cell/change/v", query)
	if err != nil {
		var zero T
		return zero, 0, false, err
	}
	return parse(data)
}

// DefaultComicFeedCellID 漫画频道 feed cell 的服务端内容 ID（tab_type=9，10/04 实测跨设备稳定）
const DefaultComicFeedCellID = "7023314149891375141"

// NovelFeedPage 小说频道瀑布流（10/04 实测：cell/change/v，tab_type=25、algo_type=167，
// 与猜你喜欢同 cell 家族）。selected 非空时携带官方筛选（逗号多选，值如
// finished/online_in_past_one_year/word_num_gt_200w/male/female/bian_ji_tui_jian）。
// 返回 (书籍, next_offset, has_more)。
func (c *Client) NovelFeedPage(selected string, offset int) ([]FeedBook, int, bool, error) {
	q := fmt.Sprintf("change_type=0&limit=0&cell_id=%s&offset=%d&client_req_type=2&algo_type=167&tab_type=25&plan_id=0",
		url.QueryEscape(DefaultFeedCellID), offset)
	if selected != "" {
		q += "&selected_items=" + url.QueryEscape(selected) + "&unlimited_selector_change_type=2"
	}
	return cellChangeFeed(c, q, parseCellFeedPage, func(b []FeedBook) bool { return len(b) == 0 })
}

// parseCellFeedPage 解析 cell/change 翻页响应：游标 + 展开全部书卡
func parseCellFeedPage(data json.RawMessage) ([]FeedBook, int, bool, error) {
	var env struct {
		HasMore    bool `json:"has_more"`
		NextOffset int  `json:"next_offset"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, 0, false, fmt.Errorf("cell feed 解析: %w", err)
	}
	books, perr := parseCellViewBooks(data)
	if perr != nil {
		books = nil // 本页全是视频卡等无书籍内容：合法空页
	}
	return books, env.NextOffset, env.HasMore, nil
}

// ComicCard 漫画频道瀑布流卡片
type ComicCard struct {
	BookID      string `json:"book_id"`
	BookName    string `json:"book_name"`
	Author      string `json:"author"`
	Abstract    string `json:"abstract"`
	Category    string `json:"category"`
	ThumbURL    string `json:"thumb_url"`
	ReadCntText string `json:"read_cnt_text"` // 形如 "12.5万人在读"
	UpdateTag   string `json:"update_tag"`    // 形如 "周更"、"日更"
	SerialCount string `json:"serial_count"`  // 总话数
	Score       string `json:"score"`
	Tags        string `json:"tags"`
	Finished    bool   `json:"finished"`
}

// ComicFeedPage 漫画频道瀑布流（10/04 实测：cell/change/v，tab_type=9，不带 algo_type，
// limit=20）。返回 (漫画卡, next_offset, has_more)。
func (c *Client) ComicFeedPage(offset int) ([]ComicCard, int, bool, error) {
	q := fmt.Sprintf("change_type=0&limit=20&cell_id=%s&offset=%d&client_req_type=2&tab_type=9&plan_id=0",
		url.QueryEscape(DefaultComicFeedCellID), offset)
	return cellChangeFeed(c, q, parseComicFeedPage, func(cards []ComicCard) bool { return len(cards) == 0 })
}

// parseComicFeedPage 解析漫画频道翻页响应：游标 + 展开全部漫画卡
func parseComicFeedPage(data json.RawMessage) ([]ComicCard, int, bool, error) {
	var env struct {
		HasMore    bool `json:"has_more"`
		NextOffset int  `json:"next_offset"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, 0, false, fmt.Errorf("comic feed 解析: %w", err)
	}
	return parseComicCards(data), env.NextOffset, env.HasMore, nil
}

// parseComicCards 展开 cell/change 响应里的漫画卡（book_data 可能挂在 cell_view
// 本身或嵌套 cell_data 里，两种形状通吃）
func parseComicCards(data json.RawMessage) []ComicCard {
	var env struct {
		CellView mallCell `json:"cell_view"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return nil
	}
	var out []ComicCard
	var walk func(c mallCell)
	walk = func(c mallCell) {
		for _, b := range c.BookData {
			if b.BookID == "" || b.BookName == "" {
				continue
			}
			out = append(out, ComicCard{
				BookID: b.BookID, BookName: b.BookName, Author: b.Author,
				Abstract: b.Abstract, Category: b.Category, ThumbURL: b.ThumbURL,
				ReadCntText: firstNonEmpty(b.ReadCntText, b.ReadCount),
				UpdateTag:   derefOrEmpty(b.UpdateTag), SerialCount: b.SerialCount,
				Score: b.Score, Tags: b.Tags,
				Finished: b.Creation == "0",
			})
		}
		for _, inner := range c.CellData {
			walk(inner)
		}
	}
	walk(env.CellView)
	return out
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func derefOrEmpty(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
（comic_tab/comic_detail/v 的 comic_data，10/04 实测）
type ComicDetailInfo struct {
	BookID      string
	BookName    string
	Author      string
	Abstract    string
	Category    string
	Tags        string
	ThumbURL    string
	ReadCntText string
	UpdateTag   string
	SerialCount string
	Score       string
	Finished    bool
}

// ComicDetail 拉取漫画详情（点击漫画卡进详情页用）
func (c *Client) ComicDetail(bookID string) (*ComicDetailInfo, error) {
	data, err := c.fetchApp("/reading/bookapi/comic_tab/comic_detail/v", "book_id="+url.QueryEscape(bookID))
	if err != nil {
		return nil, err
	}
	var env struct {
		ComicData struct {
			BookID      string  `json:"book_id"`
			BookName    string  `json:"book_name"`
			Author      string  `json:"author"`
			Abstract    string  `json:"abstract"`
			Category    string  `json:"category"`
			Tags        string  `json:"tags"`
			ThumbURL    string  `json:"thumb_url"`
			ReadCntText string  `json:"read_cnt_text"`
			ReadCount   string  `json:"read_count"`
			UpdateTag   *string `json:"update_tag"`
			SerialCount string  `json:"serial_count"`
			Score       *string `json:"score"`
			Creation    string  `json:"creation_status"`
		} `json:"comic_data"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("漫画详情解析: %w", err)
	}
	cd := env.ComicData
	if cd.BookID == "" || cd.BookName == "" {
		return nil, fmt.Errorf("漫画详情为空")
	}
	info := &ComicDetailInfo{
		BookID: cd.BookID, BookName: cd.BookName, Author: cd.Author,
		Abstract: cd.Abstract, Category: cd.Category, Tags: cd.Tags,
		ThumbURL: cd.ThumbURL, ReadCntText: firstNonEmpty(cd.ReadCntText, cd.ReadCount),
		SerialCount: cd.SerialCount, Finished: cd.Creation == "0",
	}
	if cd.UpdateTag != nil {
		info.UpdateTag = *cd.UpdateTag
	}
	if cd.Score != nil {
		info.Score = *cd.Score
	}
	return info, nil
}

// ComicDirectory 漫画话列表（directory/all_items/v，与小说目录同端点同形状）
func (c *Client) ComicDirectory(bookID string) ([]ChapterMeta, error) {
	data, err := c.fetchApp("/reading/bookapi/directory/all_items/v", "book_id="+url.QueryEscape(bookID))
	if err != nil {
		return nil, err
	}
	var env struct {
		ItemDataList []directoryChapter `json:"item_data_list"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("漫画目录解析: %w", err)
	}
	metas := make([]ChapterMeta, 0, len(env.ItemDataList))
	for _, ch := range env.ItemDataList {
		metas = append(metas, ChapterMeta{ItemID: ch.ItemID, Index: int(ch.ChapterIndex) - 1, Title: ch.Title})
	}
	return metas, nil
}

// ComicImage 单话内的一张漫画图（CDN 无签名直链，客户端直接加载）
type ComicImage struct {
	URL    string `json:"url"`
	Width  int    `json:"width,omitempty"`
	Height int    `json:"height,omitempty"`
}

// ComicChapterImages 拉取漫画单话的整话图片列表（reader/full/v，参数与小说正文同形；
// 10/04 实测整话图片一次下发）。上游 data.content 为密文时走 unidbg decrypt-content
// 解密（key_version 随响应下发）后解析 picInfos。同时返回该话 encrypt_key（hex）：
// 图片 CDN 文件本身也是加密的（nonce(12B)||AES-256-GCM(ct||tag16)，密钥即 encrypt_key，
// Frida hook 官方 App 实测 + picInfos.md5 逐张验证）。
func (c *Client) ComicChapterImages(bookID, itemID string) ([]ComicImage, string, error) {
	data, err := c.fetchApp("/reading/reader/full/v",
		"book_id="+url.QueryEscape(bookID)+"&item_id="+url.QueryEscape(itemID))
	if err != nil {
		return nil, "", err
	}
	imgs := extractComicImages(data)
	if len(imgs) == 0 {
		// 图片字段没找到且存在 content 密文 → 解密后重试（extractTextFromHtml 对无
		// <blk> 标签的内容原样返回，JSON 可存活）
		enc, kv := encryptedContentBlob(data)
		if enc == "" {
			return nil, "", fmt.Errorf("漫画内容无图片数据")
		}
		plain, derr := c.decryptExternalContent(enc, kv)
		if derr != nil {
			return nil, "", fmt.Errorf("漫画内容解密: %w", derr)
		}
		imgs = extractComicImages(json.RawMessage(plain))
		if len(imgs) == 0 {
			return nil, "", fmt.Errorf("漫画内容无图片数据")
		}
		var cj struct {
			EncryptKey string `json:"encrypt_key"`
		}
		_ = json.Unmarshal([]byte(plain), &cj)
		return imgs, cj.EncryptKey, nil
	}
	return imgs, "", nil
}

// decryptExternalContent 调 unidbg /api/fqnovel/decrypt-content（密钥由服务端按需 registerkey）
func (c *Client) decryptExternalContent(content string, keyVersion *int64) (string, error) {
	var out struct {
		Code       int    `json:"code"`
		TxtContent string `json:"txtContent"`
	}
	// decrypt-content 返回扁平 {code,txtContent}，不是 {code,message,data} 信封，
	// 不能走 postJSON（它只从 data 解包，会把成功响应当成空结果）
	body, err := c.postRaw("/api/fqnovel/decrypt-content", map[string]any{"content": content, "keyVersion": keyVersion})
	if err != nil {
		return "", err
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("解密响应解析: %w", err)
	}
	if out.Code != 0 || out.TxtContent == "" {
		return "", fmt.Errorf("解密返回空")
	}
	return out.TxtContent, nil
}

// encryptedContentBlob 找 reader 响应里的密文字段（data.content，长 base64 无 http 字样），
// 连同 key_version 一起返回
func encryptedContentBlob(data json.RawMessage) (string, *int64) {
	var env struct {
		Content    string `json:"content"`
		KeyVersion *int64 `json:"key_version"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return "", nil
	}
	if len(env.Content) > 100 && !strings.Contains(env.Content, "http") {
		return env.Content, env.KeyVersion
	}
	return "", nil
}

// extractComicImages 在响应里宽容地找整话图片列表：取文档序中「元素为含 uri/url
// 字段的对象」的最长列表（话内图片数远大于其他候选），顺序保持上游下发序。
func extractComicImages(data json.RawMessage) []ComicImage {
	var root any
	if err := json.Unmarshal(data, &root); err != nil {
		return nil
	}
	var best []ComicImage
	var walk func(node any)
	walk = func(node any) {
		switch v := node.(type) {
		case []any:
			if imgs := imageList(v); len(imgs) > len(best) {
				best = imgs
			}
			for _, e := range v {
				walk(e)
			}
		case map[string]any:
			for _, e := range v {
				walk(e)
			}
		}
	}
	walk(root)
	return best
}

// imageList 列表元素含 http 开头的 uri/url 字段才算图片列表
func imageList(list []any) []ComicImage {
	if len(list) == 0 {
		return nil
	}
	imgs := make([]ComicImage, 0, len(list))
	for _, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			return nil // 混合类型列表不算
		}
		u := ""
		// picUrl：reader/full 解密后的漫画图列表字段（picInfos[].picUrl）
		for _, k := range []string{"uri", "url", "picUrl"} {
			if s, ok := m[k].(string); ok && strings.HasPrefix(s, "http") {
				u = s
				break
			}
		}
		if u == "" {
			return nil
		}
		w, _ := m["width"].(float64)
		h, _ := m["height"].(float64)
		imgs = append(imgs, ComicImage{URL: u, Width: int(w), Height: int(h)})
	}
	return imgs
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

// recoverDevice 设备被风控时的自动轮换：
// 注册新设备 → 直接改写挂载的 application.yml（Java 服务的 update-config 不可靠）→
// 通过 docker.sock 重启 fq-unidbg 容器 → 等待就绪。
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

	// 改写挂载的 application.yml（server 容器挂载了 ./fq-unidbg/config）
	if yml := os.Getenv("XS_UNIDBG_CONFIG"); yml != "" {
		if err := patchUnidbgYml(yml, reg.DeviceInfo); err != nil {
			log.Printf("[unidbg] yml 写入警告: %v", err)
		} else {
			log.Printf("[unidbg] yml 已更新 deviceId=%s", newID)
		}
	}

	// 重启容器（docker.sock 挂载时可用）；失败则尝试服务自带 restart 端点
	if cerr := restartUnidbgContainer(); cerr != nil {
		log.Printf("[unidbg] docker.sock 重启不可用（%v），退回服务内 restart 端点", cerr)
		_, _ = c.postRaw("/api/device/restart", map[string]any{})
	}

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

// restartUnidbgContainer 通过挂载的 docker.sock 重启 fq-unidbg 容器
func restartUnidbgContainer() error {
	sock := os.Getenv("DOCKER_SOCKET")
	if sock == "" {
		sock = "/var/run/docker.sock"
	}
	if _, err := os.Stat(sock); err != nil {
		return fmt.Errorf("docker.sock 不存在: %w", err)
	}
	name := os.Getenv("XS_UNIDBG_CONTAINER")
	if name == "" {
		name = "fq-unidbg"
	}
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return net.Dial("unix", sock)
			},
		},
		Timeout: 90 * time.Second,
	}
	resp, err := client.Post("http://localhost/v1.41/containers/"+name+"/restart?t=10", "", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("docker restart HTTP %d", resp.StatusCode)
	}
	return nil
}

// patchUnidbgYml 把新设备信息写进 fq-unidbg 的 application.yml（行级替换）
func patchUnidbgYml(path string, dev map[string]any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	get := func(k string) string {
		v, _ := dev[k].(string)
		return v
	}
	deviceKeys := map[string]string{
		"cdid":         get("cdid"),
		"device-brand": get("deviceBrand"),
		"device-id":    get("deviceId"),
		"device-type":  get("deviceType"),
		"dpi":          get("dpi"),
		"install-id":   get("installId"),
		"resolution":   get("resolution"),
		"rom-version":  get("romVersion"),
		"host-abi":     get("hostAbi"),
		"os-version":   get("osVersion"),
	}
	lines := strings.Split(string(raw), "\n")
	inDevice := false
	for i, ln := range lines {
		if strings.HasPrefix(strings.TrimLeft(ln, " "), "device:") &&
			strings.Count(ln[:len(ln)-len(strings.TrimLeft(ln, " "))], " ") == 4 {
			inDevice = true
			continue
		}
		if inDevice {
			trimmed := strings.TrimLeft(ln, " ")
			if trimmed != "" && !strings.HasPrefix(ln, "      ") {
				inDevice = false
				continue
			}
			key := strings.SplitN(trimmed, ":", 2)[0]
			if v := deviceKeys[key]; v != "" {
				indent := ln[:len(ln)-len(strings.TrimLeft(ln, " "))]
				lines[i] = indent + key + ": '" + v + "'"
			}
		}
	}
	out := strings.Join(lines, "\n")
	// user-agent / cookie（fq.api 层）
	if ua := get("userAgent"); ua != "" {
		out = regexp.MustCompile(`(?m)^(    user-agent: ).*$`).ReplaceAllString(out, "${1}"+ua)
	}
	if ck := get("cookie"); ck != "" {
		out = regexp.MustCompile(`(?m)^(    cookie: ).*$`).ReplaceAllString(out, "${1}"+ck)
	}
	return os.WriteFile(path, []byte(out), 0o644)
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
