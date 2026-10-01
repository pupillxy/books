package hongguo

// 目录 / 详情 / 搜索 —— 移植自 _reference/guoapp
// provider_hongguo_catalog.go / provider_hongguo_detail.go / provider_hongguo_search.go / provider_hongguo.go

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ─── 目录 ─────────────────────────────────────────────────────────────

type CatalogPage struct {
	Items   []Drama     `json:"items"`
	HasMore bool        `json:"has_more"`
	Offset  int         `json:"next_offset"`
	Filters []FilterDim `json:"filters,omitempty"` // 二级筛选面板（首屏返回）
}

// FilterDim 二级筛选维度：title 为组名（主题/角色/年代…），items 为该组可选项
type FilterDim struct {
	Key   string       `json:"key"`
	Title string       `json:"title"`
	Items []FilterItem `json:"items"`
}

type FilterItem struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

const panelTTL = 10 * time.Minute

// Catalog 分类目录（App 接口直连；失败退回网页分类页）。
// gender 为频道筛选："1"=男频 "0"=女频 ""=不限（实测三个 genre 都支持，上游按剧打标签）；
// tag 为二级筛选，格式 "dim|id"（dim ∈ select_items 的键，如 category_dim_theme）；
// 首屏（offset=0）顺带 need_selector_panel 拉取筛选面板，解析失败不影响列表。
func (c *Client) Catalog(ctx context.Context, genre, gender, tag string, offset int) (*CatalogPage, error) {
	if offset == 0 {
		if p := c.panel(genre); p != nil {
			return c.catalog(ctx, genre, gender, tag, offset, false, p)
		}
		page, err := c.catalog(ctx, genre, gender, tag, offset, true, nil)
		if err != nil {
			return nil, err
		}
		if len(page.Filters) == 0 {
			page.Filters = c.parsePanel(c.lastPanelRaw(genre))
		} else {
			c.rememberPanel(genre, page.Filters)
		}
		return page, nil
	}
	return c.catalog(ctx, genre, gender, tag, offset, false, c.panel(genre))
}

func (c *Client) catalog(ctx context.Context, genre, gender, tag string, offset int, wantPanel bool, panel []FilterDim) (*CatalogPage, error) {
	var scene, name string
	valid := genre == ""
	for _, g := range appGenres {
		if g.key == genre {
			scene, name, valid = g.scene, g.name, true
			break
		}
	}
	if !valid {
		return nil, errors.New("红果分类无效")
	}

	selectItems := map[string]any{
		"genre": []string{}, "sort": []string{"online_time"}, "gender": []string{},
		"category_dim_theme": []string{}, "category_dim_role": []string{}, "category_dim_epoch": []string{},
		"online_time": []string{}, "creation_status": []string{},
	}
	payload := map[string]any{
		"req_scene": "default", "offset": offset, "limit": 18,
		"req_type": "only_content", "need_selector_panel": wantPanel, "client_req_type": 3,
		"session_id": "", "filter_ids": "", "select_items": selectItems,
	}
	if genre != "" {
		selectItems["genre"] = []string{genre}
		payload["req_scene"] = scene
	}
	if gender == "0" || gender == "1" { // 频道：0=女频 1=男频，其余值一律不传（不限）
		selectItems["gender"] = []string{gender}
	}
	if dim, id, ok := strings.Cut(tag, "|"); ok && id != "" {
		if _, exists := selectItems[dim]; exists {
			selectItems[dim] = []string{id}
		}
	}
	if offset > 0 {
		payload["client_req_type"] = 2
		c.mu.Lock()
		payload["session_id"] = c.sessions[sessionKey(genre, gender, tag)]
		c.mu.Unlock()
	}

	result, appErr := c.appRequest(ctx, "/reading/distribution/category/landpage/v/", payload)
	if appErr == nil {
		if page := parseCatalogPage(result, name); page != nil {
			page.Filters = panel
			if wantPanel {
				c.rememberRawPanel(genre, result)
			}
			c.mu.Lock()
			if sid := mapString(nestedMap(result, "data"), "session_id"); sid != "" {
				c.sessions[sessionKey(genre, gender, tag)] = sid
			}
			c.mu.Unlock()
			return page, nil
		}
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	// 网页兜底：真人剧走 real-drama，其余按 key 近似映射。
	// 网页数据没有性别标签，gender 筛选会失效（打日志便于排查"频道串台"反馈）
	page, webErr := c.webCategory(ctx, webGenreRoute(genre))
	if webErr != nil {
		return nil, fmt.Errorf("App 目录失败：%v；网页目录失败：%w", appErr, webErr)
	}
	log.Printf("[hongguo] 目录走网页兜底 genre=%s gender=%q tag=%q（gender 筛选不生效）: %v",
		genre, gender, tag, appErr)
	page.Filters = panel
	return page, nil
}

// ─── 二级筛选面板 ─────────────────────────────────────────────────────

// sessionKey 翻页 session 的缓存键：同分类下不同 gender/tag 组合各持一个会话
func sessionKey(genre, gender, tag string) string {
	return genre + "|" + gender + "|" + tag
}

func (c *Client) panel(genre string) []FilterDim {
	c.mu.Lock()
	defer c.mu.Unlock()
	if p, ok := c.panels[genre]; ok && time.Now().Before(p.expiresAt) {
		return p.dims
	}
	return nil
}

func (c *Client) rememberPanel(genre string, dims []FilterDim) {
	if len(dims) == 0 {
		return
	}
	c.mu.Lock()
	c.panels[genre] = panelCache{dims: dims, expiresAt: time.Now().Add(panelTTL)}
	c.mu.Unlock()
}

func (c *Client) rememberRawPanel(genre string, result map[string]any) {
	c.mu.Lock()
	c.rawPanels[genre] = result
	c.mu.Unlock()
}

func (c *Client) lastPanelRaw(genre string) map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.rawPanels[genre]
}

// parsePanel 防御式解析筛选面板：上游结构未公开，按常见形态逐层试探，
// 解析不出任何维度就返回 nil（App 端二级行直接隐藏，不影响列表）。
func (c *Client) parsePanel(result map[string]any) []FilterDim {
	if len(result) == 0 {
		return nil
	}
	data := nestedMap(result, "data")
	for _, holder := range []map[string]any{
		nestedMap(data, "selector_panel"), nestedMap(data, "filter_panel"),
		nestedMap(data, "select_panel"), nestedMap(data, "selector"), data,
	} {
		var out []FilterDim
		for _, key := range []string{"filter_dims", "dim_list", "panels", "selector_list", "filter_list", "list"} {
			rows, ok := holder[key].([]any)
			if !ok || len(rows) == 0 {
				continue
			}
			for _, row := range rows {
				m, ok := row.(map[string]any)
				if !ok {
					continue
				}
				title := mapString(m, "title", "name", "dim_name")
				if title == "" {
					continue
				}
				dimKey := mapString(m, "dim", "key", "dim_key", "filter_key")
				if dimKey == "" {
					dimKey = title
				}
				items := []FilterItem{}
				for _, opts := range []any{m["items"], m["options"], m["list"], m["values"]} {
					list, ok := opts.([]any)
					if !ok {
						continue
					}
					for _, opt := range list {
						om, ok := opt.(map[string]any)
						if !ok {
							continue
						}
						name := mapString(om, "name", "title", "text")
						id := mapString(om, "id", "filter_id", "value", "key")
						if name != "" && id != "" {
							items = append(items, FilterItem{ID: id, Name: name})
						}
					}
					if len(items) > 0 {
						break
					}
				}
				if len(items) > 1 {
					out = append(out, FilterDim{Key: dimKey, Title: title, Items: items})
				}
			}
			if len(out) > 0 {
				return out
			}
		}
	}
	return nil
}

func webGenreRoute(genre string) string {
	switch genre {
	case "comic_series":
		return "comic-drama"
	case "ai_series":
		return "ai-drama"
	case "":
		return "real-drama"
	default:
		return "real-drama"
	}
}

func parseCatalogPage(result map[string]any, category string) *CatalogPage {
	data := nestedMap(result, "data")
	rows, ok := data["video_data"].([]any)
	if !ok {
		return nil
	}
	page := &CatalogPage{Items: []Drama{}}
	seen := map[string]bool{}
	for _, row := range rows {
		drama := dramaFromAny(row, category)
		if drama.ID != "" && !seen[drama.ID] {
			seen[drama.ID] = true
			page.Items = append(page.Items, drama)
		}
	}
	if len(rows) > 0 && len(page.Items) == 0 {
		return nil
	}
	next, parseErr := strconv.Atoi(mapString(data, "next_offset"))
	hasMore, ok := data["has_more"].(bool)
	if !ok {
		return nil
	}
	if parseErr != nil {
		next = 0
	}
	page.HasMore = hasMore && len(page.Items) > 0
	page.Offset = next
	return page
}

// webCategory 网页分类页（/category/{route}?page=N）
func (c *Client) webCategory(ctx context.Context, route string) (*CatalogPage, error) {
	// 网页分页固定 1 页/请求：这里只取第一页（个人自用，翻页主要走 App 接口）
	body, err := c.fetchText(ctx, webBaseURL+"/category/"+route, webBaseURL+"/")
	if err != nil {
		return nil, err
	}
	page := routerLoaderMap(parseRouterData(body), "category_page", "category_$")
	if len(page) == 0 || page["isSuccess"] == false {
		return nil, errors.New("红果分类数据不可用")
	}
	items := anyList(page["recommendList"])
	out := &CatalogPage{Items: []Drama{}}
	seen := map[string]bool{}
	for _, item := range items {
		drama := dramaFromAny(item, genreName(""))
		if drama.ID != "" && !seen[drama.ID] {
			seen[drama.ID] = true
			out.Items = append(out.Items, drama)
		}
	}
	if total, err := strconv.Atoi(mapString(nestedMap(page, "pagination"), "totalPages")); err == nil {
		out.HasMore = total > 1
		out.Offset = 1
	}
	return out, nil
}

// dramaFromAny 目录/搜索/详情通用条目解析（移植 hongguoDramaFromAny）
func dramaFromAny(v any, category string) Drama {
	m, ok := v.(map[string]any)
	if !ok {
		return Drama{}
	}
	vd := nestedMap(m, "video_data")
	if len(vd) == 0 {
		vd = m
	}
	id := firstNonEmpty(mapString(vd, "series_id_str", "series_id"), mapString(m, "series_id_str", "series_id"), mapString(vd, "keyword"), mapString(m, "keyword"))
	if !numericID.MatchString(id) {
		return Drama{}
	}
	title := firstNonEmpty(mapString(vd, "series_title", "series_name", "title"), mapString(m, "series_name", "name"), id)
	cover := firstNonEmpty(mapString(vd, "series_cover", "cover"), mapString(m, "series_cover"))
	intro := firstNonEmpty(mapString(vd, "series_intro", "video_desc"), mapString(m, "series_intro"))
	count := firstNonEmpty(mapString(vd, "episode_cnt"), mapString(m, "episode_cnt"))
	remark := firstNonEmpty(mapString(vd, "episode_right_text"), mapString(m, "episode_right_text"))
	finished := false
	if mapString(vd, "series_status") == "1" {
		finished = true
	}
	if remark == "" && count != "" {
		remark = "共" + count + "集"
	}
	tags := mapStringSlice(vd, "tags")
	for _, value := range anyList(vd["category_list"]) {
		if name := mapString(value.(map[string]any), "name"); name != "" && !contains(tags, name) {
			tags = append(tags, name)
		}
	}
	var categories []struct {
		Name string `json:"name"`
	}
	if json.Unmarshal([]byte(mapString(vd, "category_schema")), &categories) == nil {
		for _, item := range categories {
			if item.Name != "" && !contains(tags, item.Name) {
				tags = append(tags, item.Name)
			}
		}
	}
	genre := mapString(vd, "category_name", "categoryName", "category")
	if genre == "" && len(tags) > 0 {
		genre = tags[0]
	}
	return Drama{
		ID: id, Title: title, Cover: cover, Intro: intro,
		Category: firstNonEmpty(genre, category), Remark: remark,
		EpisodeCnt: count, Finished: finished, Tags: tags,
		Score: mapString(vd, "score"), PlayCount: mapString(vd, "series_play_cnt", "play_cnt"),
	}
}

func contains(list []string, s string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// ─── 详情 ─────────────────────────────────────────────────────────────

type Detail struct {
	Drama    *Drama    `json:"drama"`
	Episodes []Episode `json:"episodes"`
}

// Detail 剧详情+分集（App 接口 5min 缓存；失败退网页 /detail）
func (c *Client) Detail(ctx context.Context, seriesID string) (*Detail, error) {
	if !numericID.MatchString(seriesID) {
		return nil, errors.New("红果剧集 ID 无效")
	}
	c.mu.Lock()
	if cached, ok := c.details[seriesID]; ok && time.Now().Before(cached.expiresAt) {
		c.mu.Unlock()
		return &Detail{Drama: cached.drama, Episodes: cached.episodes}, nil
	}
	c.mu.Unlock()

	detail, err := c.appDetail(ctx, seriesID)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		detail, err = c.webDetail(ctx, seriesID)
		if err != nil {
			return nil, fmt.Errorf("App 详情失败：%v；网页详情失败：%w", err, firstErr(err))
		}
	}
	c.mu.Lock()
	c.details[seriesID] = detailCache{drama: detail.Drama, episodes: detail.Episodes, expiresAt: time.Now().Add(detailTTL)}
	c.mu.Unlock()
	return detail, nil
}

func firstErr(err error) error { return err }

func (c *Client) appDetail(ctx context.Context, seriesID string) (*Detail, error) {
	result, err := c.appRequest(ctx, "/novel/player/video_detail/v1/", map[string]any{"series_id": seriesID})
	if err != nil {
		return nil, err
	}
	vd := nestedMap(result, "data", "video_data")
	if mapString(vd, "series_id_str", "series_id") != seriesID {
		return nil, errors.New("红果 App 未返回所请求的剧集")
	}
	drama := dramaFromAny(vd, "短剧")
	episodes := []Episode{}
	for _, row := range anyList(vd["video_list"]) {
		video, _ := row.(map[string]any)
		vid := mapString(video, "vid")
		index, err := strconv.Atoi(mapString(video, "vid_index"))
		if err != nil || index < 1 || !numericID.MatchString(vid) {
			continue
		}
		episodes = append(episodes, Episode{Vid: vid, Index: index})
	}
	if len(episodes) == 0 {
		return nil, errors.New("红果 App 未返回分集")
	}
	// 按 index 排序
	for i := 1; i < len(episodes); i++ {
		for j := i; j > 0 && episodes[j].Index < episodes[j-1].Index; j-- {
			episodes[j], episodes[j-1] = episodes[j-1], episodes[j]
		}
	}
	return &Detail{Drama: &drama, Episodes: episodes}, nil
}

func (c *Client) webDetail(ctx context.Context, seriesID string) (*Detail, error) {
	body, err := c.fetchText(ctx, webBaseURL+"/detail?series_id="+url.QueryEscape(seriesID), webBaseURL+"/")
	if err != nil {
		return nil, err
	}
	page := routerLoaderMap(parseRouterData(body), "detail_page", "detail_")
	detail, _ := page["seriesDetail"].(map[string]any)
	if len(detail) == 0 {
		return nil, errors.New("红果详情为空")
	}
	drama := dramaFromAny(detail, "短剧")
	episodes := []Episode{}
	for i, v := range anyList(detail["vid_list"]) {
		vid := strings.TrimSpace(fmt.Sprint(v))
		if vid == "" || vid == "<nil>" || !numericID.MatchString(vid) {
			continue
		}
		episodes = append(episodes, Episode{Vid: vid, Index: i + 1})
	}
	if len(episodes) == 0 {
		return nil, errors.New("红果详情没有剧集 ID")
	}
	return &Detail{Drama: &drama, Episodes: episodes}, nil
}

// ─── 搜索 ─────────────────────────────────────────────────────────────

// Search 关键词搜索：联想 API（名称匹配）+ 网页搜索页合并
func (c *Client) Search(ctx context.Context, keyword string) ([]Drama, error) {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" || len([]rune(keyword)) > 80 {
		return nil, errors.New("请输入 1 至 80 个字符的搜索词")
	}
	c.mu.Lock()
	if cached, ok := c.searches[keyword]; ok && time.Now().Before(cached.expiresAt) {
		c.mu.Unlock()
		return cached.dramas, nil
	}
	c.mu.Unlock()

	merged := []Drama{}
	seen := map[string]bool{}
	add := func(batch []Drama) {
		for _, d := range batch {
			if d.ID != "" && !seen[d.ID] {
				seen[d.ID] = true
				merged = append(merged, d)
			}
		}
	}

	names, nameErr := c.searchSuggest(ctx, keyword)
	if nameErr == nil {
		add(names)
	}
	page, pageErr := c.webSearch(ctx, keyword)
	if pageErr == nil {
		add(page)
	}
	if len(merged) == 0 && nameErr != nil && pageErr != nil {
		return nil, fmt.Errorf("联想搜索失败：%v；网页搜索失败：%w", nameErr, pageErr)
	}
	c.mu.Lock()
	c.searches[keyword] = searchCache{dramas: merged, expiresAt: time.Now().Add(searchTTL)}
	c.mu.Unlock()
	return merged, nil
}

// searchSuggest 联想接口：word_type=short_play_name 的记录即剧集
func (c *Client) searchSuggest(ctx context.Context, keyword string) ([]Drama, error) {
	params := url.Values{"app_id": {"8662"}, "query": {keyword}, "count": {"50"}}
	rawurl := webBaseURL + "/incent_resource/suggestion?" + params.Encode()
	req, err := newGetRequest(ctx, rawurl, webBaseURL+"/")
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := readLimited(resp, 256<<10)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != httpStatusOK {
		return nil, fmt.Errorf("联想接口 HTTP %d", resp.StatusCode)
	}
	var result struct {
		Items []struct {
			Name      string         `json:"name"`
			WordType  string         `json:"word_type"`
			Keyword   any            `json:"keyword"`
			VideoData map[string]any `json:"video_data"`
		} `json:"suggest_list"`
		Data struct {
			Items []struct {
				Name      string         `json:"name"`
				WordType  string         `json:"word_type"`
				Keyword   any            `json:"keyword"`
				VideoData map[string]any `json:"video_data"`
			} `json:"suggest_list"`
		} `json:"data"`
	}
	// UseNumber：series_id 是 19 位 JSON 数字，float64 会丢精度导致详情 404
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&result); err != nil {
		return nil, errors.New("红果搜索联想未返回有效数据")
	}
	out := []Drama{}
	seen := map[string]bool{}
	for _, group := range [][]struct {
		Name      string         `json:"name"`
		WordType  string         `json:"word_type"`
		Keyword   any            `json:"keyword"`
		VideoData map[string]any `json:"video_data"`
	}{result.Items, result.Data.Items} {
		for _, record := range group {
			if record.WordType != "short_play_name" {
				continue
			}
			drama := dramaFromAny(map[string]any{"video_data": record.VideoData, "name": record.Name, "keyword": record.Keyword}, "短剧")
			if drama.ID != "" && !seen[drama.ID] {
				seen[drama.ID] = true
				out = append(out, drama)
			}
		}
	}
	return out, nil
}

// webSearch 网页搜索页兜底
func (c *Client) webSearch(ctx context.Context, keyword string) ([]Drama, error) {
	rawurl := webBaseURL + "/search/" + url.PathEscape(keyword)
	body, err := c.fetchText(ctx, rawurl, webBaseURL+"/")
	if err != nil {
		return nil, err
	}
	page := routerLoaderMap(parseRouterData(body), "search_(keyword)/page", "search_")
	rows, ok := page["searchList"].([]any)
	if page["isSuccess"] != true || !ok {
		return nil, errors.New("红果搜索未返回有效结果")
	}
	out := []Drama{}
	seen := map[string]bool{}
	for _, row := range rows {
		if len(nestedMap(row, "video_data")) == 0 {
			continue
		}
		drama := dramaFromAny(row, "短剧")
		if drama.ID != "" && !seen[drama.ID] {
			seen[drama.ID] = true
			out = append(out, drama)
		}
	}
	return out, nil
}
