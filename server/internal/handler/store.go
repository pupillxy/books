package handler

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"xiaoshuo/internal/database"
	"xiaoshuo/internal/fanqie"
	"xiaoshuo/internal/middleware"
	"xiaoshuo/internal/model"
	"xiaoshuo/internal/tnd"
	"xiaoshuo/internal/unidbg"
)

// StoreHandler 书城：榜单浏览、在线书入库、TND 下载管理
type StoreHandler struct {
	DB  *database.DBStore
	FQ  *fanqie.Client
	TND *tnd.Client
	UNI *unidbg.Client

	// 番茄抓取结果短缓存：详情页的封面是带 x-signature 的签名 URL，每次抓取都重新
	// 生成（主机/签名都会变）。App 下载期间每 3s 轮询本接口，URL 一变客户端图片
	// 缓存未命中就会重新拉图闪烁。TTL 内返回同一份抓取结果，签名 URL 保持稳定。
	detMu    sync.Mutex
	detCache map[string]storeDetailCacheEntry

	// App 协议榜单批缓存：完整榜单一次拉整批（约30本），App 分页请求在批内切片。
	// key = "<algo>:<genderList>"，TTL 内复用同一批，避免 App 翻页打爆 unidbg。
	rankMu    sync.Mutex
	rankCache map[string]rankBatchEntry
}

const rankBatchTTL = 2 * time.Minute

type rankBatchEntry struct {
	books []unidbg.FeedBook
	at    time.Time
}

const storeDetailCacheTTL = 5 * time.Minute

// 失败负缓存：被番茄限流时若不缓存失败结果，App 每 3s 的详情轮询会放大成
// 每分钟上百次 /page/ 请求（每次抓取最多 6 连击），把 IP 彻底轰进黑名单
const storeDetailFailTTL = 60 * time.Second

type storeDetailCacheEntry struct {
	detail   *fanqie.BookDetail
	chapters []fanqie.ChapterInfo
	at       time.Time
	err      error // 非 nil 表示负缓存
}

// getBookDetail 详情抓取：App 协议优先（unidbg），网页端兜底（/page/ → reader 页）
func (h *StoreHandler) getBookDetail(fid string) (*fanqie.BookDetail, error) {
	if h.UNI.Enabled() {
		if d, uerr := h.uniBookDetail(fid); uerr == nil {
			return d, nil
		}
	}
	detail, err := h.FQ.GetBookDetail(fid)
	if err == nil {
		return detail, nil
	}
	detail, rerr := h.FQ.GetBookDetailViaReader(fid)
	if rerr == nil {
		return detail, nil
	}
	return nil, rerr
}

// uniBookDetail unidbg 兜底详情：目录接口附带 book_info
func (h *StoreHandler) uniBookDetail(fid string) (*fanqie.BookDetail, error) {
	info, err := h.UNI.BookInfo(fid)
	if err != nil || info == nil {
		return nil, fmt.Errorf("unidbg book_info: %w", err)
	}
	return &fanqie.BookDetail{
		Title:    info.BookName,
		Author:   info.Author,
		Cover:    info.CoverURL,
		Synopsis: info.Description,
		Finished: info.CreationStatus == "1",
	}, nil
}

// getChapters 目录：App 协议优先（unidbg），网页端兜底
func (h *StoreHandler) getChapters(fid string) ([]fanqie.ChapterInfo, error) {
	if h.UNI.Enabled() {
		if metas, uerr := h.UNI.Directory(fid); uerr == nil {
			out := make([]fanqie.ChapterInfo, 0, len(metas))
			for i, m := range metas {
				idx := m.Index
				if idx < 0 {
					idx = i
				}
				out = append(out, fanqie.ChapterInfo{ID: m.ItemID, Index: idx + 1, Title: m.Title})
			}
			return out, nil
		}
	}
	chapters, err := h.FQ.GetChapters(fid)
	if err == nil {
		return chapters, nil
	}
	return nil, err
}

// cachedFanqieDetail 取详情+目录：成功缓存 5min，失败缓存 60s，TTL 内直接复用
func (h *StoreHandler) cachedFanqieDetail(fid string) (*fanqie.BookDetail, []fanqie.ChapterInfo, error) {
	h.detMu.Lock()
	ent, ok := h.detCache[fid]
	h.detMu.Unlock()
	if ok {
		if ent.err == nil && time.Since(ent.at) <= storeDetailCacheTTL {
			return ent.detail, ent.chapters, nil
		}
		if ent.err != nil && time.Since(ent.at) <= storeDetailFailTTL {
			return nil, nil, ent.err
		}
	}
	detail, err := h.getBookDetail(fid)
	if err == nil {
		var chapters []fanqie.ChapterInfo
		chapters, err = h.getChapters(fid)
		if err == nil {
			h.detMu.Lock()
			if h.detCache == nil {
				h.detCache = map[string]storeDetailCacheEntry{}
			}
			h.detCache[fid] = storeDetailCacheEntry{detail: detail, chapters: chapters, at: time.Now()}
			h.detMu.Unlock()
			return detail, chapters, nil
		}
	}
	h.detMu.Lock()
	if h.detCache == nil {
		h.detCache = map[string]storeDetailCacheEntry{}
	}
	h.detCache[fid] = storeDetailCacheEntry{at: time.Now(), err: err}
	h.detMu.Unlock()
	return nil, nil, err
}

// Ranks 榜单分组。unidbg 可用时返回官方 App 协议榜单（完整榜单页左栏全量，
// ID 即 algo_type，RankBooks 据此走 App 协议）；否则退网页榜单分组。
func (h *StoreHandler) Ranks(c *gin.Context) {
	if h.UNI.Enabled() {
		items := make([]fanqie.RankItem, 0, len(unidbg.AppRanks))
		for _, r := range unidbg.AppRanks {
			items = append(items, fanqie.RankItem{ID: strconv.Itoa(r.Algo), Name: r.Name})
		}
		c.JSON(http.StatusOK, gin.H{"items": []fanqie.RankGroup{
			{Title: "官方榜单", Items: items},
		}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": h.FQ.GetRankGroups()})
}

// ─── 书库（官网筛选浏览）─────────────────────────────────────────────

// LibraryCategories 书库分类树（含 主分类/主题/角色/情节 分组）
func (h *StoreHandler) LibraryCategories(c *gin.Context) {
	gender := c.DefaultQuery("gender", "1")
	if gender != "0" && gender != "1" {
		gender = "1"
	}
	cats, err := h.FQ.GetLibraryCategories(gender)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取书库分类失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": cats})
}

// LibraryBooks 书库书籍（筛选 + 分页）
func (h *StoreHandler) LibraryBooks(c *gin.Context) {
	gender := c.DefaultQuery("gender", "1")
	if gender != "0" && gender != "1" {
		gender = "1"
	}
	cat := clampQuery(c.Query("category"), -1, -1, 9999999)
	status := clampQuery(c.Query("status"), -1, -1, 1)
	words := clampQuery(c.Query("words"), 0, 0, 5)
	sort := clampQuery(c.Query("sort"), 0, 0, 2)
	page := clampQuery(c.Query("page"), 0, 0, 999)
	size := clampQuery(c.Query("size"), 18, 1, 30)
	books, err := h.FQ.GetLibraryBooks(gender, cat, status, words, sort, page, size)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取书库列表失败: " + err.Error()})
		return
	}
	// 标记哪些已在书库
	for i := range books {
		if bk, err := h.DB.GetBookByFanqieID(books[i].ID); err == nil {
			books[i].InLibrary = true
			books[i].LocalBookID = bk.ID
			books[i].LocalStatus = bk.Status
		}
	}
	c.JSON(http.StatusOK, gin.H{"items": books, "has_more": len(books) >= size})
}

// ─── App 源（模拟器签名 oracle）───────────────────────────────────────

// markBooks 标记哪些书已在书库（搜索结果用）
func (h *StoreHandler) markBooks(books []fanqie.LibraryBook) {
	for i := range books {
		if bk, err := h.DB.GetBookByFanqieID(books[i].ID); err == nil {
			books[i].InLibrary = true
			books[i].LocalBookID = bk.ID
		}
	}
}

// Search 书城搜索：App 协议优先（unidbg），失败退网页端
func (h *StoreHandler) Search(c *gin.Context) {
	query := strings.TrimSpace(c.Query("query"))
	offset := clampQuery(c.Query("offset"), 0, 0, 100000)
	count := clampQuery(c.Query("count"), 10, 1, 50)
	if query == "" {
		c.JSON(http.StatusOK, gin.H{"items": []fanqie.LibraryBook{}})
		return
	}

	var books []fanqie.LibraryBook
	var appErr error
	if h.UNI.Enabled() {
		if results, err := h.UNI.Search(query, count, offset); err == nil {
			books = make([]fanqie.LibraryBook, 0, len(results))
			for _, b := range results {
				books = append(books, fanqie.LibraryBook{
					ID: b.BookID, Title: b.BookName, Author: b.Author,
					Synopsis: b.Description,
				})
			}
		} else {
			appErr = err
			log.Printf("[store] App 搜索失败 %q: %v", query, err)
		}
	}
	if books == nil {
		var err error
		books, err = h.FQ.SearchWeb(query, offset, count)
		if err != nil {
			if appErr != nil {
				c.JSON(http.StatusBadGateway, gin.H{"error": "搜索失败（App+网页均不可用）"})
			} else {
				c.JSON(http.StatusBadGateway, gin.H{"error": "搜索失败: " + err.Error()})
			}
			return
		}
		books = books[:minInt(count, len(books))]
	}
	h.markBooks(books)
	c.JSON(http.StatusOK, gin.H{"items": books})
}

// ─── 预设榜单（App 推荐榜卡的网页端近似）───────────────────────────────
// 网页榜单 API 必须带具体分类、无全分类形态（见 docs/番茄小说接口开发文档.md §3.7），
// 用书库筛选组合近似 App 首页的推荐/完本/新书/巅峰榜。

type featuredBoard struct {
	Key    string
	Name   string
	Status int // creation_status：-1 全部，0 已完结（网页兜底用）
	Words  int // 字数档位：0 全部，5 = 200万字以上（网页兜底用）
	Sort   int // 0 热门，1 最新（网页兜底用）
	Algo   int // 官方 App 协议榜单 algo_type（2026-10-03 抓包实测）
}

var featuredBoards = []featuredBoard{
	{"recommend", "推荐榜", -1, 0, 0, 101},
	{"finished", "完本榜", 0, 0, 0, 100},
	{"new", "新书榜", -1, 0, 1, 108},
	{"peak", "巅峰榜", -1, 5, 0, 200},
}

// FeaturedBoards 预设榜单清单
func (h *StoreHandler) FeaturedBoards(c *gin.Context) {
	items := make([]gin.H, 0, len(featuredBoards))
	for _, b := range featuredBoards {
		items = append(items, gin.H{"key": b.Key, "name": b.Name})
	}
	c.JSON(http.StatusOK, gin.H{"items": items})
}

// appRankBatch 拉取一份官方榜单批（带 TTL 缓存）。genderList "1"=男生榜 "0"=女生榜。
func (h *StoreHandler) appRankBatch(algo int, genderList string) ([]unidbg.FeedBook, error) {
	key := strconv.Itoa(algo) + ":" + genderList
	h.rankMu.Lock()
	if ent, ok := h.rankCache[key]; ok && time.Since(ent.at) <= rankBatchTTL {
		h.rankMu.Unlock()
		return ent.books, nil
	}
	h.rankMu.Unlock()
	books, err := h.UNI.RankPageBooks(algo, genderList)
	if err != nil {
		return nil, err
	}
	h.rankMu.Lock()
	if h.rankCache == nil {
		h.rankCache = map[string]rankBatchEntry{}
	}
	h.rankCache[key] = rankBatchEntry{books: books, at: time.Now()}
	h.rankMu.Unlock()
	return books, nil
}

// feedToLibrary unidbg.FeedBook → fanqie.LibraryBook（榜单卡片字段，word_count 协议无此值留空）
func feedToLibrary(b unidbg.FeedBook) fanqie.LibraryBook {
	return fanqie.LibraryBook{
		ID:        b.BookID,
		Title:     b.BookName,
		Author:    b.Author,
		Synopsis:  b.Abstract,
		Cover:     b.ThumbURL,
		Finished:  b.Finished,
		ReadCount: b.ReadCount,
	}
}

// sliceBatch 批内切片：越界返回空切片（App 端以 items 数量判断 has_more）
func sliceBatch[T any](batch []T, offset, limit int) []T {
	if offset < 0 {
		offset = 0
	}
	if offset >= len(batch) {
		return nil
	}
	end := offset + limit
	if end > len(batch) {
		end = len(batch)
	}
	return batch[offset:end]
}

// FeaturedBooks 预设榜单书籍：/store/featured/:board?gender=1&offset=0&limit=10
// App 协议优先（官方 cell/change/v1，gender 1=男生榜 0=女生榜），网页书库兜底
func (h *StoreHandler) FeaturedBooks(c *gin.Context) {
	key := c.Param("board")
	var preset *featuredBoard
	for i := range featuredBoards {
		if featuredBoards[i].Key == key {
			preset = &featuredBoards[i]
			break
		}
	}
	if preset == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "未知榜单: " + key})
		return
	}
	gender := c.DefaultQuery("gender", "1")
	if gender != "0" && gender != "1" {
		gender = "1"
	}
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	size := clampQuery(c.Query("limit"), 10, 1, 30)
	if offset < 0 {
		offset = 0
	}
	if h.UNI.Enabled() {
		if batch, err := h.appRankBatch(preset.Algo, gender); err == nil {
			books := make([]fanqie.LibraryBook, 0, len(batch))
			for _, b := range sliceBatch(batch, offset, size) {
				books = append(books, feedToLibrary(b))
			}
			h.markBooks(books)
			c.JSON(http.StatusOK, gin.H{"items": books, "offset": offset, "has_more": len(books) >= size})
			return
		} else {
			log.Printf("[store] App 榜单 %s 失败: %v，落网页兜底", preset.Name, err)
		}
	}
	page := offset / size
	books, err := h.FQ.GetLibraryBooks(gender, -1, preset.Status, preset.Words, preset.Sort, page, size)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取榜单失败: " + err.Error()})
		return
	}
	// 标记哪些已在书库
	for i := range books {
		if bk, err := h.DB.GetBookByFanqieID(books[i].ID); err == nil {
			books[i].InLibrary = true
			books[i].LocalBookID = bk.ID
			books[i].LocalStatus = bk.Status
		}
	}
	c.JSON(http.StatusOK, gin.H{"items": books, "offset": offset, "has_more": len(books) >= size})
}

// clampQuery 解析查询参数并夹到 [lo, hi]，解析失败用 def
func clampQuery(s string, def, lo, hi int) int {
	v, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// RankBooks 榜单书籍（分页）。rankID 为官方协议 algo_type（如 100 完本榜）时走
// App 协议（cell/change/v1，gender 1=男生榜 0=女生榜，top30 批内切片）；
// 失败时对四主榜退书库近似，其余退网页榜单（rankID 为网页形态时走原路）。
func (h *StoreHandler) RankBooks(c *gin.Context) {
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	if limit < 1 || limit > 30 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	rankID := c.Param("rankID")
	gender := c.DefaultQuery("gender", "1")
	if gender != "0" && gender != "1" {
		gender = "1"
	}
	if algo, aerr := strconv.Atoi(rankID); aerr == nil && h.UNI.Enabled() {
		if batch, err := h.appRankBatch(algo, gender); err == nil {
			books := make([]fanqie.RankBook, 0, limit)
			for i, b := range sliceBatch(batch, offset, limit) {
				books = append(books, fanqie.RankBook{
					ID: b.BookID, Rank: offset + i + 1, Title: b.BookName,
					Author: b.Author, Synopsis: b.Abstract, Cover: b.ThumbURL,
				})
			}
			for i := range books {
				if bk, err := h.DB.GetBookByFanqieID(books[i].ID); err == nil {
					books[i].InLibrary = true
					books[i].LocalBookID = bk.ID
					books[i].LocalStatus = bk.Status
				}
			}
			c.JSON(http.StatusOK, gin.H{"items": books})
			return
		}
		log.Printf("[store] App 完整榜单 %s 失败: %v", rankID, unidbg.AppRankByAlgo(algo))
		// 退而求其次：四主榜有书库近似（网页端），其余无对应形态
		for _, fb := range featuredBoards {
			if fb.Algo == algo {
				libs, werr := h.FQ.GetLibraryBooks(gender, -1, fb.Status, fb.Words, fb.Sort, offset/limit, limit)
				if werr != nil {
					c.JSON(http.StatusBadGateway, gin.H{"error": "获取榜单失败: " + werr.Error()})
					return
				}
				books := make([]fanqie.RankBook, 0, len(libs))
				for i, lb := range libs {
					books = append(books, fanqie.RankBook{
						ID: lb.ID, Rank: offset + i + 1, Title: lb.Title,
						Author: lb.Author, Synopsis: lb.Synopsis, Cover: lb.Cover,
					})
				}
				for i := range books {
					if bk, err := h.DB.GetBookByFanqieID(books[i].ID); err == nil {
						books[i].InLibrary = true
						books[i].LocalBookID = bk.ID
						books[i].LocalStatus = bk.Status
					}
				}
				c.JSON(http.StatusOK, gin.H{"items": books})
				return
			}
		}
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取榜单失败（App 协议不可用）"})
		return
	}
	books, err := h.FQ.GetRankingBooks(rankID, offset, limit)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取榜单失败: " + err.Error()})
		return
	}
	// 标记哪些已在书库
	for i := range books {
		if bk, err := h.DB.GetBookByFanqieID(books[i].ID); err == nil {
			books[i].InLibrary = true
			books[i].LocalBookID = bk.ID
			books[i].LocalStatus = bk.Status
		}
	}
	c.JSON(http.StatusOK, gin.H{"items": books})
}

// BookDetail 在线书详情（简介 + 目录 + 本地状态）
func (h *StoreHandler) BookDetail(c *gin.Context) {
	fid := c.Param("fanqieID")
	if !fanqie.ValidateBookID(fid) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "书籍 ID 无效"})
		return
	}
	detail, chapters, err := h.cachedFanqieDetail(fid)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取详情失败: " + err.Error()})
		return
	}
	free := 0
	for _, ch := range chapters {
		if ch.IsFree {
			free++
		}
	}

	resp := gin.H{
		"fanqie_id":     fid,
		"title":         detail.Title,
		"author":        detail.Author,
		"cover":         detail.Cover,
		"synopsis":      detail.Synopsis,
		"chapter_count": len(chapters),
		"free_count":    free,
		"finished":      detail.Finished,
		// 详情页预览前 30 章，完整目录以入库后的 /books/:id 为准
		"chapters": chapters[:minInt(30, len(chapters))],
	}
	if bk, err := h.DB.GetBookByFanqieID(fid); err == nil {
		resp["in_library"] = true
		resp["book_id"] = bk.ID
		resp["status"] = bk.Status
		// 书架是按用户的：进页自动入库不加书架，App 靠这个字段展示 加入书架/已在书架
		if on, err := h.DB.IsOnShelf(middleware.UserID(c), bk.ID); err == nil {
			resp["on_shelf"] = on
		}
	} else {
		resp["in_library"] = false
	}
	if task, err := h.DB.GetDownloadTask(fid); err == nil {
		resp["download_status"] = task.Status
	}
	c.JSON(http.StatusOK, resp)
}

// AddBook 在线书入库：目录 meta 预入库 + 加入书架，可选触发 TND 下载
func (h *StoreHandler) AddBook(c *gin.Context) {
	fid := c.Param("fanqieID")
	if !fanqie.ValidateBookID(fid) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "书籍 ID 无效"})
		return
	}
	var req struct {
		Download bool `json:"download"` // 是否同时触发 TND 下载整本
	}
	_ = c.ShouldBindJSON(&req) // body 可省略

	// 已入库则直接返回（补一次书架，防其他用户/设备遗漏）
	if bk, err := h.DB.GetBookByFanqieID(fid); err == nil {
		_ = h.DB.AddShelf(middleware.UserID(c), bk.ID)
		c.JSON(http.StatusOK, gin.H{"ok": true, "book_id": bk.ID, "status": bk.Status, "already": true})
		return
	}

	bookID, title, err := h.importOnline(fid, middleware.UserID(c), true)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "入库失败: " + err.Error()})
		return
	}

	var downloadStatus string
	if req.Download {
		downloadStatus = h.triggerDownload(fid, title, bookID)
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "book_id": bookID, "status": "online", "download_status": downloadStatus})
}

// AutoDownload 详情页进入即调用（幂等）：入库 + 目录预拉 + 可选加书架。
// 在线阅读时代：正文按需回源（读到哪章拉哪章并缓存），不再自动整本下载；
// 需要离线缓存时走显式下载（POST /store/books/:fanqieID/download 或 ?download=1）。
// download_status 恒返 "disabled" 让 App 详情页停止下载轮询（在线可读）。
func (h *StoreHandler) AutoDownload(c *gin.Context) {
	fid := c.Param("fanqieID")
	if !fanqie.ValidateBookID(fid) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "书籍 ID 无效"})
		return
	}
	addShelf := c.DefaultQuery("shelf", "1") != "0"
	download := c.DefaultQuery("download", "0") == "1"
	userID := middleware.UserID(c)
	if bk, err := h.DB.GetBookByFanqieID(fid); err == nil {
		if addShelf {
			_ = h.DB.AddShelf(userID, bk.ID)
		}
		ds := "disabled"
		if download && bk.Status != "ready" && bk.Status != "downloading" {
			ds = h.triggerDownload(fid, bk.Title, bk.ID)
		}
		if task, err := h.DB.GetDownloadTask(fid); err == nil &&
			(task.Status == "pending" || task.Status == "running") {
			ds = task.Status
		}
		c.JSON(http.StatusOK, gin.H{"ok": true, "book_id": bk.ID, "status": bk.Status, "download_status": ds, "already": true})
		return
	}
	bookID, title, err := h.importOnline(fid, userID, addShelf)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "自动入库失败: " + err.Error()})
		return
	}
	status := "online"
	ds := "disabled"
	if download {
		ds = h.triggerDownload(fid, title, bookID)
		if ds == "pending" || ds == "running" {
			status = "downloading"
		}
	}
	c.JSON(http.StatusOK, gin.H{"ok": true, "book_id": bookID, "status": status, "download_status": ds})
}

// importOnline 拉取详情+目录并预入库（幂等），按需加入书架；返回 bookID 与标题
func (h *StoreHandler) importOnline(fid string, userID int64, addShelf bool) (int64, string, error) {
	detail, err := h.getBookDetail(fid)
	if err != nil {
		return 0, "", err
	}
	chapters, err := h.getChapters(fid)
	if err != nil {
		return 0, "", err
	}
	book := &model.Book{
		Title:         detail.Title,
		Author:        detail.Author,
		Intro:         detail.Synopsis,
		Cover:         detail.Cover,
		FanqieID:      fid,
		Status:        "online",
		Finished:      detail.Finished,
		TotalChapters: len(chapters),
	}
	bookID, err := h.DB.UpsertOnlineBook(book)
	if err != nil {
		return 0, "", err
	}
	metas := make([]database.OnlineChapterMeta, 0, len(chapters))
	for _, ch := range chapters {
		metas = append(metas, database.OnlineChapterMeta{Idx: ch.Index - 1, Title: ch.Title, SrcID: ch.ID})
	}
	if err := h.DB.ReplaceChapterMeta(bookID, metas); err != nil {
		return 0, "", err
	}
	if addShelf {
		_ = h.DB.AddShelf(userID, bookID)
	}
	return bookID, detail.Title, nil
}

// TriggerDownload 触发/重试 TND 下载
func (h *StoreHandler) TriggerDownload(c *gin.Context) {
	fid := c.Param("fanqieID")
	book, err := h.DB.GetBookByFanqieID(fid)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "书籍未入库，请先加入书库"})
		return
	}
	status := h.triggerDownload(fid, book.Title, book.ID)
	c.JSON(http.StatusOK, gin.H{"ok": status != "", "download_status": status})
}

func (h *StoreHandler) triggerDownload(fid, title string, bookID int64) string {
	// 已有进行中的任务则幂等返回，避免重复触发
	if task, err := h.DB.GetDownloadTask(fid); err == nil &&
		(task.Status == "pending" || task.Status == "running") {
		return task.Status
	}
	if !h.UNI.Enabled() && !h.TND.Enabled() {
		return "disabled"
	}
	if err := h.DB.UpsertDownloadTask(fid, title, "pending"); err != nil {
		return "failed"
	}
	_ = h.DB.SetBookStatus(bookID, "downloading")
	if h.UNI.Enabled() {
		// 自建 unidbg 下载器：SO 在 unidbg 内自算签名，批量拉正文增量回填 DB；
		// 失败时（正文接口对新设备风控等）自动落到 TND 兜底
		go func() {
			_ = h.DB.SetDownloadTaskStatus(fid, "running")
			if err := h.UNI.DownloadBook(h.DB, bookID, fid, title); err != nil {
				log.Printf("[unidbg] 整本下载失败 %s: %v，尝试 TND 兜底", title, err)
				if !h.TND.Enabled() {
					_ = h.DB.SetDownloadTaskStatus(fid, "failed")
					_ = h.DB.SetBookStatus(bookID, "online")
					return
				}
				if err2 := h.TND.RequestDownload(fid, title); err2 != nil {
					log.Printf("[tnd] 兜底下载也失败 %s: %v", title, err2)
					_ = h.DB.SetDownloadTaskStatus(fid, "failed")
					_ = h.DB.SetBookStatus(bookID, "online")
					return
				}
				log.Printf("[tnd] 兜底下载已接管 %s", title)
				return // TND 完成后由 scanner 导入并置 ready
			}
			_ = h.DB.SetDownloadTaskStatus(fid, "ready")
			_ = h.DB.SetBookStatus(bookID, "ready")
		}()
		return "pending"
	}
	go func() {
		if err := h.TND.RequestDownload(fid, title); err != nil {
			_ = h.DB.SetDownloadTaskStatus(fid, "failed")
			_ = h.DB.SetBookStatus(bookID, "online")
			return
		}
		_ = h.DB.SetDownloadTaskStatus(fid, "running")
	}()
	return "pending"
}

// AppFeed App 书城首页 feed（与番茄 App 同源：实时热度排行榜等模块）
func (h *StoreHandler) AppFeed(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	secs, err := h.UNI.HomeFeed()
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取 App feed 失败: " + err.Error()})
		return
	}
	type bookOut struct {
		ID        string `json:"id"`
		Title     string `json:"title"`
		Author    string `json:"author"`
		Synopsis  string `json:"synopsis"`
		Cover     string `json:"cover"`
		Finished  bool   `json:"finished"`
		ReadCount string `json:"read_count"`
		Score     string `json:"score,omitempty"`
		RankScore string `json:"rank_score,omitempty"`
		Category  string `json:"category,omitempty"`
		Tags      string `json:"tags,omitempty"`
	}
	type secOut struct {
		Title    string    `json:"title"`
		Subtitle string    `json:"subtitle,omitempty"`
		Books    []bookOut `json:"books"`
	}
	out := make([]secOut, 0, len(secs))
	for _, s := range secs {
		books := make([]bookOut, 0, len(s.Books))
		for _, b := range s.Books {
			books = append(books, bookOut{
				ID: b.BookID, Title: b.BookName, Author: b.Author,
				Synopsis: b.Abstract, Cover: b.ThumbURL, Finished: b.Finished,
				ReadCount: b.ReadCount, Score: b.Score, RankScore: b.RankScore,
				Category: b.Category, Tags: b.Tags,
			})
		}
		out = append(out, secOut{Title: s.Title, Subtitle: s.Subtitle, Books: books})
	}
	c.JSON(http.StatusOK, gin.H{"sections": out})
}

// Downloads 下载任务列表
func (h *StoreHandler) Downloads(c *gin.Context) {
	tasks, err := h.DB.ListDownloadTasks()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if tasks == nil {
		tasks = []*model.DownloadTask{}
	}
	c.JSON(http.StatusOK, gin.H{"items": tasks})
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
