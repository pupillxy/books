package fanqie

// 番茄网页端直连客户端 —— 移植自 _reference/fanqie-rank-mcp/api.py
// 仅用于个人自用的书城浏览与免费章节试读，控制请求频率

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	UARank = "Dalvik/2.1.0 (Linux; U; Android 10; SM-G975F Build/QP1A.190711.020) com.ss.android.article.news/831"
	UAWeb  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

// Client 番茄网页端客户端（并发安全）
type Client struct {
	HTTP   *http.Client
	Cookie string // 可选登录 Cookie（无也能读免费章节）
}

func NewClient(cookie string) *Client {
	// 强制 IPv4 拨号：部分宽带环境下 IPv6 出口会被番茄 CDN 挖空网页数据
	// （__INITIAL_STATE__ 有 page 骨架但 bookName/abstract 等字段为空）
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", addr)
		},
	}
	return &Client{
		HTTP:   &http.Client{Timeout: 15 * time.Second, Transport: transport},
		Cookie: cookie,
	}
}

func (c *Client) get(url, ua string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", ua)
	// 补全浏览器特征头：只有 UA 的裸请求在部分出口（如 NAS 容器）会被返回风控壳页，
	// 表现为 __INITIAL_STATE__ 缺 page 节点导致详情元数据为空
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	req.Header.Set("Referer", "https://fanqienovel.com/")
	if c.Cookie != "" {
		req.Header.Set("Cookie", strings.NewReplacer("\r", "", "\n", "").Replace(c.Cookie))
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

func (c *Client) getWithRetry(url, ua string, maxRetries int) (string, error) {
	backoff := 600 * time.Millisecond
	var lastErr error
	for attempt := 1; attempt <= maxRetries; attempt++ {
		body, err := c.get(url, ua)
		if err == nil {
			return body, nil
		}
		lastErr = err
		if attempt >= maxRetries {
			break
		}
		time.Sleep(backoff + time.Duration(rand.Int63n(int64(300*time.Millisecond))))
		if backoff*2 < 3*time.Second {
			backoff *= 2
		}
	}
	return "", fmt.Errorf("重试%d次后失败: %w", maxRetries, lastErr)
}

// ─── HTML 工具 ────────────────────────────────────────────────────────

var (
	reTrailingComma = regexp.MustCompile(`,\s*([}\]])`)
	reHTMLTags      = regexp.MustCompile(`<[^>]+>`)
	reChapterBlock  = regexp.MustCompile(`(?s)<div[^>]*class="[^"]*chapter[^"]*"[^>]*>.*?<a[^>]*href="/reader/(\d+)"[^>]*>(.*?)</a>.*?</div>`)
)

// parseInitialState 提取 window.__INITIAL_STATE__ = {...} JSON（手写括号配平）
func parseInitialState(html string) map[string]interface{} {
	marker := "window.__INITIAL_STATE__"
	pos := strings.Index(html, marker)
	if pos == -1 {
		return nil
	}
	rest := html[pos+len(marker):]
	eq := strings.Index(rest, "=")
	if eq == -1 {
		return nil
	}
	trimmed := strings.TrimSpace(rest[eq+1:])
	if !strings.HasPrefix(trimmed, "{") {
		return nil
	}
	depth, inStr, esc, end := 0, false, false, 0
	for i := 0; i < len(trimmed); i++ {
		ch := trimmed[i]
		if esc {
			esc = false
			continue
		}
		switch {
		case ch == '\\' && inStr:
			esc = true
		case ch == '"':
			inStr = !inStr
		case !inStr && ch == '{':
			depth++
		case !inStr && ch == '}':
			depth--
			if depth == 0 {
				end = i + 1
			}
		}
		if end > 0 {
			break
		}
	}
	if depth != 0 || end == 0 {
		return nil
	}
	raw := strings.ReplaceAll(trimmed[:end], "undefined", "null")
	raw = reTrailingComma.ReplaceAllString(raw, "$1")
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return nil
	}
	return m
}

func stripHTMLTags(s string) string { return reHTMLTags.ReplaceAllString(s, "") }

// normalizeParaTags 段落/换行标签 → 换行（须在去标签前做，保留段落结构）
func normalizeParaTags(raw string) string {
	r := strings.NewReplacer(
		"<p>", "\n", "</p>", "",
		"<br>", "\n", "<br/>", "\n", "<br />", "\n",
	)
	return r.Replace(raw)
}

// unescapeEntities 实体反转义（须在去标签后做：正文里的字面 < 若先反转义，
// 会被去标签正则 <[^>]+> 误吞到下一个 > 之间的整段文字）
func unescapeEntities(s string) string {
	r := strings.NewReplacer(
		"&nbsp;", " ", "&lt;", "<", "&gt;", ">", "&amp;", "&", "&quot;", `"`,
	)
	return strings.TrimSpace(r.Replace(s))
}

func normalizeCoverURL(u string) string {
	if u == "" {
		return ""
	}
	if strings.HasPrefix(u, "//") {
		return "https:" + u
	}
	if strings.HasPrefix(u, "http") {
		return u
	}
	return "https://p3-novel.byteimg.com/" + strings.TrimPrefix(u, "/")
}

// jsonStr 从 map 取嵌套字符串字段
func jsonStr(m map[string]interface{}, keys ...string) string {
	cur := m
	for i, k := range keys {
		v, ok := cur[k]
		if !ok || v == nil {
			return ""
		}
		if i == len(keys)-1 {
			if s, ok := v.(string); ok {
				return s
			}
			return ""
		}
		next, ok := v.(map[string]interface{})
		if !ok {
			return ""
		}
		cur = next
	}
	return ""
}

// ─── 榜单 ─────────────────────────────────────────────────────────────

type RankGroup struct {
	Title string     `json:"title"`
	Items []RankItem `json:"items"`
}

type RankItem struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

var reMenuInner = regexp.MustCompile(`(?s)class="arco-menu-inner"(.*?)</div>\s*</div>\s*</div>\s*</div>`)
var reMenuHeader = regexp.MustCompile(`class="arco-menu-inline-header"`)
var reGroupTitle = regexp.MustCompile(`<span><span>([^<]+)</span></span>`)
var reRankLink = regexp.MustCompile(`<a[^>]*href="/rank/([^"]+)"[^>]*>([^<]+)</a>`)

func fallbackLeaderboards() []RankGroup {
	return []RankGroup{
		{Title: "男频阅读榜", Items: []RankItem{
			{ID: "1_2_1141", Name: "西方奇幻"},
			{ID: "1_2_1142", Name: "玄幻仙侠"},
			{ID: "1_2_1143", Name: "都市生活"},
			{ID: "1_2_1144", Name: "历史架空"},
		}},
		{Title: "女频阅读榜", Items: []RankItem{
			{ID: "0_2_1139", Name: "古风世情"},
			{ID: "0_2_1140", Name: "现代言情"},
		}},
	}
}

// GetRankGroups 获取榜单分组（失败时返回兜底数据）
func (c *Client) GetRankGroups() []RankGroup {
	html, err := c.get("https://fanqienovel.com/rank", UAWeb)
	if err != nil {
		return fallbackLeaderboards()
	}
	m := reMenuInner.FindStringSubmatch(html)
	if m == nil {
		return fallbackLeaderboards()
	}
	menuHTML := m[1]
	blocks := reMenuHeader.Split(menuHTML, -1)
	var groups []RankGroup
	for i, block := range blocks {
		if i == 0 { // 第一个块是 header 前的内容（无分组标题）
			continue
		}
		title := ""
		if tm := reGroupTitle.FindStringSubmatch(block); tm != nil {
			title = tm[1]
		}
		var items []RankItem
		for _, lm := range reRankLink.FindAllStringSubmatch(block, -1) {
			items = append(items, RankItem{ID: lm[1], Name: lm[2]})
		}
		if len(items) > 0 {
			if title == "" {
				title = fmt.Sprintf("分组 %d", i)
			}
			groups = append(groups, RankGroup{Title: title, Items: items})
		}
	}
	if len(groups) == 0 {
		return fallbackLeaderboards()
	}
	return groups
}

// ─── 榜单书籍 ─────────────────────────────────────────────────────────

type RankBook struct {
	ID       string `json:"id"`
	Rank     int    `json:"rank"`
	Title    string `json:"title"`
	Author   string `json:"author"`
	Synopsis string `json:"synopsis"`
	Cover    string `json:"cover"`

	// 由 handler 层填充：该书是否已在本地书库
	InLibrary   bool  `json:"in_library"`
	LocalBookID int64 `json:"book_id,omitempty"`
	LocalStatus string `json:"status,omitempty"`
}

// GetRankingBooks 获取榜单书籍列表（rankID 形如 "1_2_1141"）
func (c *Client) GetRankingBooks(rankID string, offset, limit int) ([]RankBook, error) {
	query := fmt.Sprintf(
		"app_id=2503&rank_list_type=3&offset=%d&limit=%d&category_id=%s&rank_version=&gender=%s&rankMold=%s",
		offset, limit, rankCategory(rankID), rankGender(rankID), rankMold(rankID),
	)
	sign := GenerateABogus(query, UARank)
	apiURL := fmt.Sprintf("https://fanqienovel.com/api/rank/category/list?%s&a_bogus=%s", query, sign)

	body, err := c.get(apiURL, UARank)
	if err != nil {
		return nil, err
	}
	var data struct {
		Data struct {
			BookList []map[string]interface{} `json:"book_list"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &data); err != nil {
		return nil, fmt.Errorf("榜单响应解析失败: %w", err)
	}
	books := make([]RankBook, 0, len(data.Data.BookList))
	for idx, item := range data.Data.BookList {
		title := DecryptPUA(firstStr(item, "bookName", "book_name"))
		author := DecryptPUA(firstStr(item, "author", "author_name"))
		synopsis := DecryptPUA(firstStr(item, "abstract", "description"))
		cover := normalizeCoverURL(firstStr(item, "thumbUri", "thumb_url", "thumbUrl", "cover", "cover_url", "img_url"))
		if title == "" {
			continue
		}
		books = append(books, RankBook{
			ID:       firstStr(item, "book_id", "bookId"),
			Rank:     offset + idx + 1, // 全局名次：翻页后继续递增，而非本页内序号
			Title:    title,
			Author:   author,
			Synopsis: synopsis,
			Cover:    cover,
		})
	}
	return books, nil
}

// rankID 格式 {gender}_{rankMold}_{categoryId}
func rankGender(rankID string) string {
	parts := strings.Split(rankID, "_")
	if len(parts) == 3 && parts[0] != "" {
		return parts[0]
	}
	return "1"
}

func rankMold(rankID string) string {
	parts := strings.Split(rankID, "_")
	if len(parts) == 3 && parts[1] != "" {
		return parts[1]
	}
	return "2"
}

// rankCategory 取第三段纯数字作为 category_id（API 只接受数字，整串会返回空列表）
func rankCategory(rankID string) string {
	parts := strings.Split(rankID, "_")
	if len(parts) == 3 && parts[2] != "" {
		return parts[2]
	}
	return rankID
}

func firstStr(m map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
				return s
			}
		}
	}
	return ""
}

// ─── 书库（官网筛选浏览）──────────────────────────────────────────────

// LibCategory 书库分类项（label: 主分类/主题/角色/情节）
type LibCategory struct {
	Label string `json:"label"`
	Name  string `json:"name"`
	ID    int64  `json:"id"`
}

// GetLibraryCategories 书库分类树（gender: 1=男生 0=女生）
func (c *Client) GetLibraryCategories(gender string) ([]LibCategory, error) {
	apiURL := fmt.Sprintf("https://fanqienovel.com/api/author/book/category_list/v0/?gender=%s", gender)
	body, err := c.getStable(apiURL, UAWeb)
	if err != nil {
		return nil, err
	}
	var data struct {
		Code int    `json:"code"`
		Msg  string `json:"message"`
		Data []struct {
			Label      string `json:"label"`
			Name       string `json:"name"`
			CategoryID int64  `json:"category_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &data); err != nil {
		return nil, fmt.Errorf("书库分类解析失败: %w", err)
	}
	if data.Code != 0 {
		return nil, fmt.Errorf("书库分类接口错误: %s", data.Msg)
	}
	cats := make([]LibCategory, 0, len(data.Data))
	for _, it := range data.Data {
		cats = append(cats, LibCategory{Label: it.Label, Name: it.Name, ID: it.CategoryID})
	}
	return cats, nil
}

// LibraryBook 书库书籍条目
type LibraryBook struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Author    string `json:"author"`
	Synopsis  string `json:"synopsis"`
	Cover     string `json:"cover"`
	Finished  bool   `json:"finished"`
	WordCount string `json:"word_count"` // 解密后形如 "135.6万字"
	ReadCount string `json:"read_count"` // 解密后形如 "8888万"，榜单卡片展示用

	// 由 handler 层填充：该书是否已在本地书库
	InLibrary   bool   `json:"in_library"`
	LocalBookID int64  `json:"book_id,omitempty"`
	LocalStatus string `json:"status,omitempty"`
}

// GetLibraryBooks 书库筛选列表
// gender "1"=男生 "0"=女生；categoryID -1=全部；status -1=全部 0=已完结 1=连载中；
// words 0=全部 1=30万以下 2=30-50万 3=50-100万 4=100-200万 5=200万以上；
// sort 0=热门 1=最新 2=字数；page 从 0 起（page_index）
func (c *Client) GetLibraryBooks(gender string, categoryID, status, words, sort, page, pageSize int) ([]LibraryBook, error) {
	query := fmt.Sprintf(
		"gender=%s&category_id=%d&creation_status=%d&word_count=%d&book_type=-1&sort=%d&page_count=%d&page_index=%d",
		gender, categoryID, status, words, sort, pageSize, page)
	sign := GenerateABogus(query, UARank)
	apiURL := fmt.Sprintf("https://fanqienovel.com/api/author/library/book_list/v0/?%s&a_bogus=%s", query, sign)
	body, err := c.getStable(apiURL, UARank)
	if err != nil {
		return nil, err
	}
	var data struct {
		Code int    `json:"code"`
		Msg  string `json:"message"`
		Data struct {
			BookList []map[string]interface{} `json:"book_list"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &data); err != nil {
		return nil, fmt.Errorf("书库响应解析失败: %w", err)
	}
	if data.Code != 0 {
		return nil, fmt.Errorf("书库接口错误: %s", data.Msg)
	}
	books := make([]LibraryBook, 0, len(data.Data.BookList))
	for _, item := range data.Data.BookList {
		title := DecryptLibPUA(firstStr(item, "bookName", "book_name"))
		if title == "" {
			continue
		}
		fin := false
		if v, ok := item["creation_status"].(float64); ok {
			// 实证（2026-09-28 对照 last_chapter_time）：0=已完结 1=连载中，与详情页 creationStatus 语义一致
			fin = int(v) == 0
		}
		books = append(books, LibraryBook{
			ID:        firstStr(item, "book_id", "bookId"),
			Title:     title,
			Author:    DecryptLibPUA(firstStr(item, "author", "author_name")),
			Synopsis:  DecryptLibPUA(firstStr(item, "abstract", "description")),
			Cover:     normalizeCoverURL(firstStr(item, "thumbUri", "thumb_url", "thumbUrl", "cover", "cover_url", "img_url")),
			Finished:  fin,
			WordCount: DecryptLibPUA(firstStr(item, "word_count", "wordCount", "word_number")),
			ReadCount: DecryptLibPUA(firstStr(item, "read_count", "readCount")),
		})
	}
	return books, nil
}

// getStable 带一次重试的抓取：番茄偶发限流会返回空壳（HTTP 200 空 body / 非 JSON），稍候重试一次
func (c *Client) getStable(url, ua string) (string, error) {
	body, err := c.get(url, ua)
	if err == nil && strings.HasPrefix(strings.TrimSpace(body), "{") {
		return body, nil
	}
	if err != nil {
		return "", err
	}
	time.Sleep(1200 * time.Millisecond)
	return c.get(url, ua)
}

// ─── 书籍详情（页面解析）──────────────────────────────────────────────

type ChapterInfo struct {
	ID     string `json:"id"`
	Index  int    `json:"index"`
	Title  string `json:"title"`
	IsFree bool   `json:"is_free"`
}

type BookDetail struct {
	Title    string        `json:"title"`
	Author   string        `json:"author"`
	Cover    string        `json:"cover"`
	Synopsis string        `json:"synopsis"`
	Finished bool          `json:"finished"` // creationStatus: 0=已完结 1=连载中（页面文案实测验证）
	Chapters []ChapterInfo `json:"chapters"`
}

// GetBookDetail 从书籍页面提取元信息与章节（页面列出的章节均为免费试读章节）
func (c *Client) GetBookDetail(bookID string) (*BookDetail, error) {
	url := fmt.Sprintf("https://fanqienovel.com/page/%s", bookID)
	var html string
	var err error
	// 外层重试：风控壳页特征是 HTTP 200 但 __INITIAL_STATE__ 缺 page 节点，
	// 此时视为失败换轮重试（壳页出现与出口环境相关，重试有概率命中正常页）
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(500+rand.Intn(400)) * time.Millisecond)
		}
		html, err = c.getWithRetry(url, UAWeb, 2)
		if err != nil {
			continue
		}
		if state := parseInitialState(html); state != nil {
			if _, ok := state["page"].(map[string]interface{}); ok {
				err = nil
				break
			}
		}
		err = fmt.Errorf("页面缺少 INITIAL_STATE 数据（疑似风控壳页）")
		html = ""
	}
	if err != nil {
		return nil, err
	}
	detail := &BookDetail{}
	if state := parseInitialState(html); state != nil {
		// 实测页面结构：顶层 "page" 节点，abstract=简介，description=作者格言
		if page, ok := state["page"].(map[string]interface{}); ok {
			detail.Title = DecryptPUA(strOr(page, "bookName"))
			detail.Author = DecryptPUA(strOr(page, "authorName"))
			detail.Cover = normalizeCoverURL(strOr(page, "thumbUri", "thumbUrl"))
			// creationStatus: 0=已完结，1=连载中（《惹金枝》《人在诡异》两书页面文案对照验证）
			if v, ok := page["creationStatus"].(float64); ok && v == 0 {
				detail.Finished = true
			}
			for _, key := range []string{"abstract", "description"} {
				if s := strOr(page, key); s != "" {
					detail.Synopsis = DecryptPUA(s)
					break
				}
			}
		}
	}
	for _, m := range reChapterBlock.FindAllStringSubmatch(html, -1) {
		detail.Chapters = append(detail.Chapters, ChapterInfo{
			ID:     m[1],
			Index:  len(detail.Chapters) + 1,
			Title:  DecryptPUA(stripHTMLTags(m[2])),
			IsFree: true,
		})
	}
	return detail, nil
}

// ─── 章节目录（API）───────────────────────────────────────────────────

// GetChapters 获取完整章节目录
func (c *Client) GetChapters(bookID string) ([]ChapterInfo, error) {
	body, err := c.getWithRetry(
		fmt.Sprintf("https://fanqienovel.com/api/reader/directory/detail?bookId=%s", bookID),
		UAWeb, 3,
	)
	if err != nil {
		return nil, err
	}
	var data struct {
		Data map[string]interface{} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &data); err != nil {
		return nil, fmt.Errorf("目录响应解析失败: %w", err)
	}
	items := data.Data["chapterListWithVolume"]
	if items == nil {
		items = data.Data["list"]
	}
	if items == nil {
		items = data.Data["item_list"]
	}
	rawList, ok := items.([]interface{})
	if !ok {
		return nil, errors.New("目录数据结构异常")
	}
	// 可能嵌套卷，展开一层
	var flat []map[string]interface{}
	for _, it := range rawList {
		if sub, ok := it.([]interface{}); ok {
			for _, s := range sub {
				if m, ok := s.(map[string]interface{}); ok {
					flat = append(flat, m)
				}
			}
		} else if m, ok := it.(map[string]interface{}); ok {
			flat = append(flat, m)
		}
	}

	chapters := make([]ChapterInfo, 0, len(flat))
	for i, ch := range flat {
		title := DecryptPUA(strOr(ch, "title", "chapterName"))
		chapters = append(chapters, ChapterInfo{
			ID:    strOr(ch, "itemId", "item_id"),
			Index: i + 1,
			Title: title,
			// 网页端锁章判据已废（10/03 实测）：网页只给试读 ≠ 付费章，
			// App 协议匿名设备可读全文，目录层一律标记可读，正文按需回源
			IsFree: true,
		})
	}
	return chapters, nil
}

func strOr(m map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok {
			return v
		}
	}
	return ""
}

// ─── 章节正文 ─────────────────────────────────────────────────────────

type ChapterContent struct {
	Title   string `json:"title"`
	Content string `json:"content"`
}

// ErrChapterLocked 付费章节：网页端只下发截断预览，拿不到完整正文
var ErrChapterLocked = errors.New("付费章节，网页端仅提供预览")

// isLockedTeaser 识别锁章截断预览：完整章节恒以 </p> 收尾且 2000+ 字；
// 预览在固定长度处硬切，常停在标签中间（实测末尾游离 '<'），仅 ~150-200 字
func isLockedTeaser(raw string) bool {
	t := strings.TrimRight(raw, " \t\r\n")
	if t == "" {
		return false
	}
	i := strings.LastIndexByte(t, '<')
	if i >= 0 && !strings.Contains(t[i:], ">") {
		return true // 存在未闭合的 '<'：标签被拦腰切断
	}
	return !strings.HasSuffix(t, "</p>") && utf8.RuneCountInString(t) < 500
}

// GetChapterContent 获取章节正文（仅免费章节有效，锁章返回 ErrChapterLocked）
func (c *Client) GetChapterContent(chapterID string) (*ChapterContent, error) {
	html, err := c.get(fmt.Sprintf("https://fanqienovel.com/reader/%s", chapterID), UAWeb)
	if err != nil {
		return nil, err
	}
	state := parseInitialState(html)
	if state == nil {
		return &ChapterContent{}, nil
	}
	reader, _ := state["reader"].(map[string]interface{})
	if reader == nil {
		return &ChapterContent{}, nil
	}
	chData, _ := reader["chapterData"].(map[string]interface{})
	if chData == nil {
		return &ChapterContent{}, nil
	}
	title := strings.TrimSpace(strOr(chData, "title"))
	rawContent, _ := chData["content"].(string)
	if isLockedTeaser(rawContent) {
		return nil, ErrChapterLocked
	}
	content := DecryptPUA(unescapeEntities(stripHTMLTags(normalizeParaTags(rawContent))))
	return &ChapterContent{Title: title, Content: content}, nil
}

// GetBookDetailViaReader /page/ 被风控限流（200 空 body）时的兜底：
// 目录 API 未受限 → 取首章 ID → reader 页 __INITIAL_STATE__ 自带
// bookName/authorName/thumbUri，可拼出完整元数据
func (c *Client) GetBookDetailViaReader(bookID string) (*BookDetail, error) {
	body, err := c.getWithRetry(
		fmt.Sprintf("https://fanqienovel.com/api/reader/directory/detail?bookId=%s", bookID), UAWeb, 2)
	if err != nil {
		return nil, err
	}
	var data struct {
		Data struct {
			AllItemIds []string `json:"allItemIds"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &data); err != nil || len(data.Data.AllItemIds) == 0 {
		return nil, errors.New("目录数据异常")
	}
	html, err := c.getWithRetry(
		fmt.Sprintf("https://fanqienovel.com/reader/%s", data.Data.AllItemIds[0]), UAWeb, 2)
	if err != nil {
		return nil, err
	}
	detail := &BookDetail{}
	if m := regexp.MustCompile(`"bookName":"([^"]{1,200})"`).FindStringSubmatch(html); m != nil {
		detail.Title = DecryptPUA(m[1])
	}
	for _, m := range regexp.MustCompile(`"author":"([^"]{1,60})"`).FindAllStringSubmatch(html, -1) {
		if m[1] != "" { // __INITIAL_STATE__ 前部可能先出现空 author 字段
			detail.Author = DecryptPUA(m[1])
			break
		}
	}
	for _, key := range []string{"thumbUri", "thumbUrl"} {
		if m := regexp.MustCompile(`"` + key + `":"([^"]{1,200})"`).FindStringSubmatch(html); m != nil && m[1] != "" {
			detail.Cover = normalizeCoverURL(m[1])
			break
		}
	}
	c.enrichFromAuthorPage(html, bookID, detail)
	if detail.Title == "" {
		return nil, errors.New("reader 页缺 bookName 数据")
	}
	return detail, nil
}

// enrichFromAuthorPage 作者页补全封面/简介：reader 页 ld+json 内嵌 author-page 链接，
// 作者页为 SSR 书卡列表（封面 img → /page/{bid} 链接 → desc1 简介），按书 ID 定位
func (c *Client) enrichFromAuthorPage(html, bookID string, d *BookDetail) {
	if d.Cover != "" && d.Synopsis != "" {
		return
	}
	m := regexp.MustCompile(`author-page/(\d+)`).FindStringSubmatch(html)
	if m == nil {
		return
	}
	ap, err := c.getWithRetry("https://fanqienovel.com/author-page/"+m[1], UAWeb, 2)
	if err != nil {
		return
	}
	idx := strings.Index(ap, "/page/"+bookID)
	if idx < 0 {
		return
	}
	lo, hi := idx-2000, idx+2000
	if lo < 0 {
		lo = 0
	}
	if hi > len(ap) {
		hi = len(ap)
	}
	// 书卡结构：封面 img 在链接之前，简介 desc1 在链接之后 → 分片取就近匹配
	before := strings.ReplaceAll(ap[lo:idx], "&amp;", "&")
	after := strings.ReplaceAll(ap[idx:hi], "&amp;", "&")
	if d.Cover == "" {
		if ms := regexp.MustCompile(`<img src="([^"]+)`).FindAllStringSubmatch(before, -1); len(ms) > 0 {
			d.Cover = normalizeCoverURL(ms[len(ms)-1][1])
		}
	}
	if d.Synopsis == "" {
		if m := regexp.MustCompile(`desc1[^>]*>([^<]{10,600})<`).FindStringSubmatch(after); m != nil {
			d.Synopsis = DecryptPUA(m[1])
		}
	}
}

// ValidateBookID 简单校验番茄书籍 ID（纯数字）
func ValidateBookID(id string) bool {
	if id == "" || len(id) > 20 {
		return false
	}
	_, err := strconv.ParseUint(id, 10, 64)
	return err == nil
}
