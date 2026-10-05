package handler

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
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
	// Secret 漫画图片代理 URL 的 HMAC 签名密钥（复用 JWTSecret；公开端点签名即鉴权）
	Secret string

	// 番茄抓取结果短缓存：详情页的封面是带 x-signature 的签名 URL，每次抓取都重新
	// 生成（主机/签名都会变）。App 下载期间每 3s 轮询本接口，URL 一变客户端图片
	// 缓存未命中就会重新拉图闪烁。TTL 内返回同一份抓取结果，签名 URL 保持稳定。
	detMu    sync.Mutex
	detCache map[string]storeDetailCacheEntry

	// App 协议榜单批缓存：完整榜单一次拉整批（约30本），App 分页请求在批内切片。
	// key = "<algo>:<genderList>"，TTL 内复用同一批，避免 App 翻页打爆 unidbg。
	rankMu    sync.Mutex
	rankCache map[string]rankBatchEntry

	// App feed 缓存：tab/v 是风控敏感端点，每次进书城都拉会触发 code=110。
	// 成功缓存 10 分钟、失败负缓存 60 秒（负缓存期内的重试直接返回失败，不打上游）。
	feedMu   sync.Mutex
	feedCache *storeFeedCacheEntry

	// 小说/漫画频道瀑布流缓存：key 含筛选与 offset，App 滚动/切筛选高频请求
	// 在 TTL 内复用同一回放（cellFeedCached 内自带锁竞争面小，map 读写都在
	// handler goroutine，与 feedCache 不同——这里也加锁保持一致）。
	cellFeedMu   sync.Mutex
	cellFeedCache map[string]cellFeedCacheEntry

	// 漫画详情+话列表缓存
	comicDetMu    sync.Mutex
	comicDetCache map[string]comicDetCacheEntry

	// 分类页标签树缓存（key=gender）：标签树变更极少，正缓存 6h，上游失败回退陈旧值
	catFrontMu    sync.Mutex
	catFrontCache map[int]catFrontEntry

	// 分类书单页缓存（key 含分类/筛选/offset）：同 cellFeed 缓存策略
	catFeedMu    sync.Mutex
	catFeedCache map[string]catFeedEntry

	// 图片代理（storeimg.go）：磁盘缓存目录 + 上游闸门 + 独立 HTTP 客户端，惰性初始化
	imgOnce sync.Once
	imgDir  string
	imgGate *coverGate
	imgHTTP *http.Client
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
				out = append(out, fanqie.ChapterInfo{ID: m.ItemID, Index: idx + 1, Title: m.Title, IsFree: true})
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
	h.rewriteLibraryCovers(c, books)
	c.JSON(http.StatusOK, gin.H{"items": books, "has_more": len(books) >= size})
}

// ─── App 源（模拟器签名 oracle）───────────────────────────────────────

// markBooks 标记哪些书已在书库（搜索结果用），并顺带把封面出参改写为代理地址
func (h *StoreHandler) markBooks(c *gin.Context, books []fanqie.LibraryBook) {
	for i := range books {
		if bk, err := h.DB.GetBookByFanqieID(books[i].ID); err == nil {
			books[i].InLibrary = true
			books[i].LocalBookID = bk.ID
		}
	}
	h.rewriteLibraryCovers(c, books)
}

// Search 书城搜索（10/05 起 TND 首选）：TND 直连番茄官方基础设施、无设备风控
// 压力，但上游无翻页参数（一次约 20 条），仅服务首页 offset=0；翻页或 TND
// 失败/空结果退 App 协议（unidbg，NAS 偶发服务层 NPE），再退网页端。
func (h *StoreHandler) Search(c *gin.Context) {
	query := strings.TrimSpace(c.Query("query"))
	offset := clampQuery(c.Query("offset"), 0, 0, 100000)
	count := clampQuery(c.Query("count"), 10, 1, 50)
	if query == "" {
		c.JSON(http.StatusOK, gin.H{"items": []fanqie.LibraryBook{}})
		return
	}

	// ① TND 搜索（仅首页）
	if offset == 0 && h.TND.Enabled() {
		if items, err := h.TND.Search(query); err == nil && len(items) > 0 {
			books := make([]fanqie.LibraryBook, 0, len(items))
			for _, it := range items {
				if it.BookID == "" || it.Title == "" {
					continue
				}
				books = append(books, fanqie.LibraryBook{
					ID: it.BookID, Title: it.Title, Author: it.Author,
					Synopsis:  it.Abstract,
					Cover:     it.ThumbURL,
					Finished:  it.CreationStatus == "1",
					WordCount: tndWordCount(it.WordNumber),
					ReadCount: tndReadCount(it.ReadCntText, it.ReadCount),
				})
			}
			books = books[:minInt(count, len(books))]
			h.markBooks(c, books)
			c.JSON(http.StatusOK, gin.H{"items": books})
			return
		} else if err != nil {
			log.Printf("[store] TND 搜索失败 %q: %v，退 App 协议/网页", query, err)
		} else {
			log.Printf("[store] TND 搜索 %q 无结果，退 App 协议/网页", query)
		}
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
	h.markBooks(c, books)
	c.JSON(http.StatusOK, gin.H{"items": books})
}

// tndWordCount 原始字数值 → "135.6万字"（App 搜索卡直接展示该文案）
func tndWordCount(n int64) string {
	if n <= 0 {
		return ""
	}
	if n < 10000 {
		return strconv.Itoa(int(n)) + "字"
	}
	s := strconv.FormatFloat(float64(n)/10000, 'f', 1, 64)
	return strings.TrimSuffix(s, ".0") + "万字"
}

// tndReadCount 在读文案归一："1.4万人在读" → "1.4万"；非计数文案退原始数值
func tndReadCount(text string, n int64) string {
	if strings.HasSuffix(text, "人在读") {
		return strings.TrimSuffix(text, "人在读")
	}
	if n <= 0 {
		return ""
	}
	if n < 10000 {
		return strconv.Itoa(int(n))
	}
	s := strconv.FormatFloat(float64(n)/10000, 'f', 1, 64)
	return strings.TrimSuffix(s, ".0") + "万"
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
			h.markBooks(c, books)
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
	h.rewriteLibraryCovers(c, books)
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
	h.rewriteRankCovers(c, books)
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
		"cover":         h.imgOut(c, detail.Cover),
		"synopsis":      detail.Synopsis,
		"chapter_count": len(chapters),
		"free_count":    free,
		"finished":      detail.Finished,
		// 全量目录：在线读已覆盖全部章节，无需截断（10/03）
		"chapters": chapters,
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

// storeFeedBook App feed 书籍条目输出（AppFeed/AppFeedPage 共用）
type storeFeedBook struct {
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
	WordCount string `json:"word_count,omitempty"`
}

// storeFeedSection App feed 分区输出（猜你喜欢分区带分页游标）
type storeFeedSection struct {
	Title      string          `json:"title"`
	Subtitle   string          `json:"subtitle,omitempty"`
	Books      []storeFeedBook `json:"books"`
	CellID     string          `json:"cell_id,omitempty"`
	PlanID     string          `json:"plan_id,omitempty"`
	AlgoType   int             `json:"algo_type,omitempty"`
	NextOffset int             `json:"next_offset,omitempty"`
}

func (h *StoreHandler) feedBooksOut(c *gin.Context, books []unidbg.FeedBook) []storeFeedBook {
	booksOut := make([]storeFeedBook, 0, len(books))
	for _, b := range books {
		booksOut = append(booksOut, h.feedBookOut(c, b))
	}
	return booksOut
}

// storeFeedCacheEntry App feed 缓存条目（err 非空 = 负缓存）
type storeFeedCacheEntry struct {
	out  []storeFeedSection
	err  string
	at   time.Time
}

const (
	feedCacheTTL    = 10 * time.Minute // tab/v 风控敏感：成功结果缓存 10 分钟
	feedNegCacheTTL = 60 * time.Second // 失败负缓存 60 秒，防止重试打爆上游
)

// AppFeed App 书城首页 feed（与番茄 App 同源：实时热度排行榜等模块）
func (h *StoreHandler) AppFeed(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	h.feedMu.Lock()
	cached := h.feedCache
	h.feedMu.Unlock()
	if cached != nil {
		ttl := feedCacheTTL
		if cached.err != "" {
			ttl = feedNegCacheTTL
		}
		if time.Since(cached.at) < ttl {
			if cached.err != "" {
				c.JSON(http.StatusBadGateway, gin.H{"error": cached.err})
			} else {
				c.JSON(http.StatusOK, gin.H{"sections": cached.out})
			}
			return
		}
	}
	secs, err := h.UNI.HomeFeed()
	if err != nil {
		errMsg := "获取 App feed 失败: " + err.Error()
		h.feedMu.Lock()
		h.feedCache = &storeFeedCacheEntry{err: errMsg, at: time.Now()}
		h.feedMu.Unlock()
		c.JSON(http.StatusBadGateway, gin.H{"error": errMsg})
		return
	}
	out := make([]storeFeedSection, 0, len(secs))
	for _, s := range secs {
		out = append(out, storeFeedSection{
			Title: s.Title, Subtitle: s.Subtitle, Books: h.feedBooksOut(c, s.Books),
			CellID: s.CellID, PlanID: s.PlanID, AlgoType: s.AlgoType, NextOffset: s.NextOffset,
		})
	}
	h.feedMu.Lock()
	h.feedCache = &storeFeedCacheEntry{out: out, at: time.Now()}
	h.feedMu.Unlock()
	c.JSON(http.StatusOK, gin.H{"sections": out})
}
// AppFeedPage 猜你喜欢瀑布流翻页：App 传 appfeed 下发的 cell_id/plan_id/offset。
// 上游 cell/change 是个性化会话端点，冷启动/突发连打会返回软空页（10/04 档案），
// 因此三层取数（10/05 定案）：
//  ① 内存缓存（3min 正 / 60s 负）；
//  ② DB 持久缓存 last-known-good：非强刷请求 6h 内直接回放、不碰上游——首屏
//     秒出且完全绕开冷会话；封面签名 URL 有效期 1~2 天，6h 内必然有效；
//  ③ 上游聚合拉取：逐页打到 ≥10 本（上游一页书卡 1~10 本波动，视频卡被过滤）
//     或 3 页上限；下游拉失败回退 DB 陈旧值（任何年龄）——App 端不再出报错横幅。
//  App 下拉刷新带 refresh=1：绕过①②强制走③并回写两级缓存（用户要求：更新只
//  跟随下拉刷新）。与小说/漫画频道同策略走 cellFeed 家族助手。
func (h *StoreHandler) AppFeedPage(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	// 猜你喜欢 feed cell 是服务端内容 ID，跨设备稳定（10/03 实测）；
	// App 未携带时用默认值，整条瀑布流不依赖 tab/v 即可工作
	cellID := c.Query("cell_id")
	if cellID == "" {
		cellID = unidbg.DefaultFeedCellID
	}
	planID := c.DefaultQuery("plan_id", "0")
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if offset < 0 {
		offset = 0
	}
	forceRefresh := c.Query("refresh") == "1"
	key := "guess|" + cellID + "|" + planID + "|" + strconv.Itoa(offset)

	respondDB := func(ent *database.FeedCacheEntry) {
		c.JSON(http.StatusOK, gin.H{
			"books":       json.RawMessage(ent.Items),
			"next_offset": ent.NextOffset,
			"has_more":    ent.HasMore,
		})
	}

	// ① 内存缓存；② DB 持久缓存（强刷均绕过）。负缓存命中说明上游正在冷却，
	// 此时无论 DB 多旧都回退陈旧值，不再打上游
	if !forceRefresh {
		items, next, more, errStr, hit := h.cellFeedLookup(key)
		if hit && errStr == "" {
			c.JSON(http.StatusOK, gin.H{"books": items, "next_offset": next, "has_more": more})
			return
		}
		if ent := h.DB.GetFeedCache(key); ent != nil {
			if errStr != "" || time.Since(ent.UpdatedAt) <= guessFeedStaleTTL {
				respondDB(ent)
				return
			}
		}
	}

	// ③ 上游聚合拉取并回写两级缓存
	items, next, more, err := h.guessFeedFetch(c, cellID, planID, offset)()
	if err == nil {
		h.cellFeedPut(key, items, next, more, "")
		if raw, merr := json.Marshal(items); merr == nil {
			h.DB.PutFeedCache(key, string(raw), next, more)
		}
		c.JSON(http.StatusOK, gin.H{"books": items, "next_offset": next, "has_more": more})
		return
	}
	// 上游失败：回退 DB 陈旧值（保可用性优先）；连陈旧值都没有才报错（App 端
	// 现有的横幅+90s 自动重试兜底）
	if ent := h.DB.GetFeedCache(key); ent != nil {
		log.Printf("[store] 猜你喜欢上游失败回退陈旧缓存 key=%s: %v", key, err)
		respondDB(ent)
		return
	}
	h.cellFeedPut(key, nil, 0, false, err.Error())
	c.JSON(http.StatusBadGateway, gin.H{"error": "获取瀑布流翻页失败: " + err.Error()})
}

// 猜你喜欢聚合参数：单次请求聚合到 ≥10 本（首次拿 10 本）、最多 3 页上游请求；
// DB 兜底缓存 6h 内视为可直回放（封面签名 URL 有效期 1~2 天）
const (
	guessFeedMinBooks = 10
	guessFeedMaxPages = 3
	guessFeedStaleTTL = 6 * time.Hour
)

// guessFeedFetch 猜你喜欢聚合拉取：逐页打到 ≥10 本或 3 页上限；中途页失败/空页
// 保留已聚合部分（游标/has_more 取最后一个成功页），首页为空才算失败。
// unidbg.FeedPage 内部已带空页 800ms 重试。
func (h *StoreHandler) guessFeedFetch(c *gin.Context, cellID, planID string, offset int) func() ([]any, int, bool, error) {
	return func() ([]any, int, bool, error) {
		seen := map[string]bool{}
		var agg []any
		cur := offset
		next, more := offset, false
		var lastErr error
		for page := 0; page < guessFeedMaxPages; page++ {
			books, n2, m2, err := h.UNI.FeedPage(cellID, planID, cur)
			if err != nil {
				lastErr = err
				break
			}
			if len(books) == 0 {
				break // 空页当流结束（内部已重试过）
			}
			next, more = n2, m2
			for _, b := range h.feedBooksOut(c, books) {
				if seen[b.ID] {
					continue
				}
				seen[b.ID] = true
				agg = append(agg, b)
			}
			if !m2 || len(agg) >= guessFeedMinBooks {
				break
			}
			cur = n2
			time.Sleep(300 * time.Millisecond) // 翻页限速
		}
		if len(agg) == 0 {
			if lastErr != nil {
				return nil, 0, false, lastErr
			}
			return nil, 0, false, errors.New("猜你喜欢上游返回空页")
		}
		return agg, next, more, nil
	}
}

// ─── 小说/漫画频道（bookmall cell/change，10/04 协议定案）────────────

// cellFeedCacheEntry 小说/漫画瀑布流缓存条目（err 非空 = 负缓存）。
// App 连续滚动/切筛选会高频打上游，TTL 内同一 (筛选, offset) 只回放一次。
type cellFeedCacheEntry struct {
	items      any
	nextOffset int
	hasMore    bool
	err        string
	at         time.Time
}

const (
	cellFeedCacheTTL    = 3 * time.Minute
	cellFeedNegCacheTTL = 60 * time.Second
)

// novelFilterCharset 筛选 token 白名单字符集（官方值为小写拼音/下划线风格）；
// 未知 token 直接丢弃，避免垃圾参数打到上游
var novelFilterRe = regexp.MustCompile(`^[a-z0-9_]{2,40}$`)

// cellFeedCached 通用取缓存/回放（自带锁）。fetch 返回 (条目, next_offset, has_more, error)。
func (h *StoreHandler) cellFeedCached(key string, fetch func() ([]any, int, bool, error)) (items []any, nextOffset int, hasMore bool, err error) {
	if items, next, more, errStr, hit := h.cellFeedLookup(key); hit {
		if errStr != "" {
			return nil, 0, false, errors.New(errStr)
		}
		return items, next, more, nil
	}
	raws, next, more, ferr := fetch()
	errStr := ""
	if ferr != nil {
		errStr = ferr.Error()
	}
	h.cellFeedPut(key, raws, next, more, errStr)
	if ferr != nil {
		return nil, 0, false, ferr
	}
	return raws, next, more, nil
}

// cellFeedLookup 查内存瀑布流缓存（3min 正 / 60s 负）。hit=true 时 err 非空表示负缓存命中。
func (h *StoreHandler) cellFeedLookup(key string) (items []any, nextOffset int, hasMore bool, errStr string, hit bool) {
	h.cellFeedMu.Lock()
	defer h.cellFeedMu.Unlock()
	if h.cellFeedCache == nil {
		return nil, 0, false, "", false
	}
	ent, ok := h.cellFeedCache[key]
	if !ok {
		return nil, 0, false, "", false
	}
	ttl := cellFeedCacheTTL
	if ent.err != "" {
		ttl = cellFeedNegCacheTTL
	}
	if time.Since(ent.at) >= ttl {
		return nil, 0, false, "", false
	}
	if ent.err != "" {
		return nil, 0, false, ent.err, true
	}
	list, _ := ent.items.([]any)
	return list, ent.nextOffset, ent.hasMore, "", true
}

// cellFeedPut 写入内存瀑布流缓存条目（err 非空 = 负缓存）
func (h *StoreHandler) cellFeedPut(key string, items []any, nextOffset int, hasMore bool, errStr string) {
	h.cellFeedMu.Lock()
	defer h.cellFeedMu.Unlock()
	if h.cellFeedCache == nil {
		h.cellFeedCache = map[string]cellFeedCacheEntry{}
	}
	h.cellFeedCache[key] = cellFeedCacheEntry{
		items: items, nextOffset: nextOffset, hasMore: hasMore, err: errStr, at: time.Now(),
	}
}

// NovelFeed 小说频道筛选瀑布流：GET /api/store/novelfeed?filters=finished,male&offset=0
// 官方协议：cell/change/v tab_type=25 + selected_items（10/04 定案，值见
// _reference/fqemu/capture_xiaoshuo_1004/FINDINGS.md）
func (h *StoreHandler) NovelFeed(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	// 筛选 token 清洗：仅放行官方值字符集，去重，最多 6 个
	var selected []string
	seen := map[string]bool{}
	for _, tok := range strings.Split(c.Query("filters"), ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" || !novelFilterRe.MatchString(tok) || seen[tok] {
			continue
		}
		seen[tok] = true
		selected = append(selected, tok)
		if len(selected) >= 6 {
			break
		}
	}
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if offset < 0 {
		offset = 0
	}
	sel := strings.Join(selected, ",")
	key := "novel:" + sel + "|" + strconv.Itoa(offset)
	items, nextOffset, hasMore, err := h.cellFeedCached(key, func() ([]any, int, bool, error) {
		books, next, more, ferr := h.UNI.NovelFeedPage(sel, offset)
		if ferr != nil {
			return nil, 0, false, ferr
		}
		out := make([]any, 0, len(books))
		for _, b := range books {
			out = append(out, h.feedBookOut(c, b))
		}
		return out, next, more, nil
	})
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取小说频道失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "next_offset": nextOffset, "has_more": hasMore})
}

// feedBookOut unidbg.FeedBook → storeFeedBook（含字数；封面改写为代理地址）
func (h *StoreHandler) feedBookOut(c *gin.Context, b unidbg.FeedBook) storeFeedBook {
	return storeFeedBook{
		ID: b.BookID, Title: b.BookName, Author: b.Author,
		Synopsis: b.Abstract, Cover: h.imgOut(c, b.ThumbURL), Finished: b.Finished,
		ReadCount: b.ReadCount, Score: b.Score, RankScore: b.RankScore,
		Category: b.Category, Tags: b.Tags, WordCount: b.WordNumber,
	}
}

// ─── 分类页（官方 new_category 协议，10/05 抓包定案，档案 capture_xiaoshuo_1005）───

type catFrontEntry struct {
	data *unidbg.CategoryFrontData
	at   time.Time
}

const catFrontTTL = 6 * time.Hour

type catFeedEntry struct {
	page *unidbg.CategoryLandingPage
	at   time.Time
	err  string // 非空 = 负缓存
}

var categoryIDRe = regexp.MustCompile(`^[0-9]{1,10}$`)

// Categories 分类页标签树：GET /api/store/categories?gender=1
// gender 1=男生(new_category_tab=1) 0=女生(=0)。官方全集还有听书/出版/短剧/漫画
// 频道，本服务只透出小说两频道（其余内容形态 App 未接）。
// 标签树变更极少：正缓存 6h，上游失败回退任意年龄陈旧值（入口页可用性优先）。
func (h *StoreHandler) Categories(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	gender, _ := strconv.Atoi(c.DefaultQuery("gender", "1"))
	if gender != 0 {
		gender = 1
	}
	h.catFrontMu.Lock()
	ent, ok := h.catFrontCache[gender]
	h.catFrontMu.Unlock()
	if ok && time.Since(ent.at) < catFrontTTL {
		c.JSON(http.StatusOK, gin.H{"tab": ent.data.Tab, "name": ent.data.Name,
			"tabs": ent.data.Tabs, "groups": ent.data.Groups})
		return
	}
	data, err := h.UNI.CategoryFront(gender)
	if err != nil {
		if ok { // 陈旧值兜底：分类页是书城入口，标签树宁旧勿挂
			c.JSON(http.StatusOK, gin.H{"tab": ent.data.Tab, "name": ent.data.Name,
				"tabs": ent.data.Tabs, "groups": ent.data.Groups})
			return
		}
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取分类标签树失败: " + err.Error()})
		return
	}
	h.catFrontMu.Lock()
	if h.catFrontCache == nil {
		h.catFrontCache = map[int]catFrontEntry{}
	}
	h.catFrontCache[gender] = catFrontEntry{data: data, at: time.Now()}
	h.catFrontMu.Unlock()
	c.JSON(http.StatusOK, gin.H{"tab": data.Tab, "name": data.Name,
		"tabs": data.Tabs, "groups": data.Groups})
}

// catFeedLookup 查分类书单缓存（同 cellFeedLookup 的正/负缓存语义）
func (h *StoreHandler) catFeedLookup(key string) (*unidbg.CategoryLandingPage, bool) {
	h.catFeedMu.Lock()
	defer h.catFeedMu.Unlock()
	ent, ok := h.catFeedCache[key]
	if !ok {
		return nil, false
	}
	ttl := cellFeedCacheTTL
	if ent.err != "" {
		ttl = cellFeedNegCacheTTL
	}
	if time.Since(ent.at) >= ttl {
		return nil, false
	}
	return ent.page, true
}

func (h *StoreHandler) catFeedPut(key string, page *unidbg.CategoryLandingPage, errStr string) {
	h.catFeedMu.Lock()
	defer h.catFeedMu.Unlock()
	if h.catFeedCache == nil {
		h.catFeedCache = map[string]catFeedEntry{}
	}
	h.catFeedCache[key] = catFeedEntry{page: page, at: time.Now(), err: errStr}
}

// CategoryFeed 分类书单页：GET /api/store/categoryfeed?category_id=7&gender=1&filters=&offset=0
// filters=官方筛选 selector_item_id 逗号串（如 word_num_gte200,creation_status_end,sort_score），
// 白名单清洗同 NovelFeed；响应附 banner（官方标签语）与 related（相关分类，可整页跳转）。
func (h *StoreHandler) CategoryFeed(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	catID := strings.TrimSpace(c.Query("category_id"))
	if !categoryIDRe.MatchString(catID) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "category_id 无效"})
		return
	}
	gender, _ := strconv.Atoi(c.DefaultQuery("gender", "1"))
	if gender != 0 {
		gender = 1
	}
	var selected []string
	seen := map[string]bool{}
	for _, tok := range strings.Split(c.Query("filters"), ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" || !novelFilterRe.MatchString(tok) || seen[tok] {
			continue
		}
		seen[tok] = true
		selected = append(selected, tok)
		if len(selected) >= 6 {
			break
		}
	}
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if offset < 0 {
		offset = 0
	}
	sel := strings.Join(selected, ",")
	key := "cat:" + catID + "|" + strconv.Itoa(gender) + "|" + sel + "|" + strconv.Itoa(offset)
	if page, hit := h.catFeedLookup(key); hit {
		if page == nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": "获取分类书单失败（缓存）"})
			return
		}
		c.JSON(http.StatusOK, h.catFeedOut(c, page))
		return
	}
	page, err := h.UNI.CategoryLanding(catID, strconv.Itoa(gender), sel, offset)
	if err != nil {
		h.catFeedPut(key, nil, err.Error())
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取分类书单失败: " + err.Error()})
		return
	}
	h.catFeedPut(key, page, "")
	c.JSON(http.StatusOK, h.catFeedOut(c, page))
}

func (h *StoreHandler) catFeedOut(c *gin.Context, page *unidbg.CategoryLandingPage) gin.H {
	items := make([]storeFeedBook, 0, len(page.Books))
	for _, b := range page.Books {
		items = append(items, h.feedBookOut(c, b))
	}
	related := page.Related
	if related == nil {
		related = []unidbg.CategoryTag{}
	}
	return gin.H{"items": items, "next_offset": page.Next, "has_more": page.More,
		"banner": page.Banner, "related": related}
}

// storeComicBook 漫画频道卡输出
type storeComicBook struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Author     string `json:"author"`
	Synopsis   string `json:"synopsis,omitempty"`
	Cover      string `json:"cover"`
	Category   string `json:"category,omitempty"`
	ReadCount  string `json:"read_count,omitempty"` // 形如 "12.5万人在读"
	UpdateTag  string `json:"update_tag,omitempty"` // 形如 "周更"
	WordCount  string `json:"word_count,omitempty"` // 复用字段装总话数（"322话"）
	Score      string `json:"score,omitempty"`
	Tags       string `json:"tags,omitempty"`
	Finished   bool   `json:"finished"`
}

// ComicFeed 漫画频道瀑布流：GET /api/store/comicfeed?offset=0
func (h *StoreHandler) ComicFeed(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if offset < 0 {
		offset = 0
	}
	key := "comic|" + strconv.Itoa(offset)
	items, nextOffset, hasMore, err := h.cellFeedCached(key, func() ([]any, int, bool, error) {
		cards, next, more, ferr := h.UNI.ComicFeedPage(offset)
		if ferr != nil {
			return nil, 0, false, ferr
		}
		out := make([]any, 0, len(cards))
		for _, b := range cards {
			out = append(out, storeComicBook{
				ID: b.BookID, Title: b.BookName, Author: b.Author,
				Synopsis: b.Abstract, Cover: h.imgOut(c, b.ThumbURL), Category: b.Category,
				ReadCount: b.ReadCntText, UpdateTag: b.UpdateTag,
				WordCount: func() string {
					if b.SerialCount == "" {
						return ""
					}
					return b.SerialCount + "话"
				}(), Score: b.Score, Tags: b.Tags, Finished: b.Finished,
			})
		}
		return out, next, more, nil
	})
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取漫画频道失败: " + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "next_offset": nextOffset, "has_more": hasMore})
}

// comicDetCacheEntry 漫画详情+话列表缓存（同 cachedFanqieDetail 的 TTL 策略）
type comicDetCacheEntry struct {
	info     *unidbg.ComicDetailInfo
	chapters []fanqie.ChapterInfo
	at       time.Time
	err      error
}

// fetchComic 漫画详情+全量话列表，短缓存命中直接返回（详情与加入书架共用）
func (h *StoreHandler) fetchComic(bookID string) (*unidbg.ComicDetailInfo, []fanqie.ChapterInfo, error) {
	h.comicDetMu.Lock()
	if h.comicDetCache == nil {
		h.comicDetCache = map[string]comicDetCacheEntry{}
	}
	ent, ok := h.comicDetCache[bookID]
	h.comicDetMu.Unlock()
	if ok {
		if ent.err != nil && time.Since(ent.at) <= storeDetailFailTTL {
			return nil, nil, ent.err
		}
		if ent.err == nil && time.Since(ent.at) <= storeDetailCacheTTL {
			return ent.info, ent.chapters, nil
		}
	}
	info, err := h.UNI.ComicDetail(bookID)
	if err != nil {
		h.comicDetMu.Lock()
		h.comicDetCache[bookID] = comicDetCacheEntry{at: time.Now(), err: err}
		h.comicDetMu.Unlock()
		return nil, nil, err
	}
	metas, err := h.UNI.ComicDirectory(bookID)
	if err != nil {
		h.comicDetMu.Lock()
		h.comicDetCache[bookID] = comicDetCacheEntry{at: time.Now(), err: err}
		h.comicDetMu.Unlock()
		return nil, nil, err
	}
	chapters := make([]fanqie.ChapterInfo, 0, len(metas))
	for i, m := range metas {
		idx := m.Index
		if idx < 0 {
			idx = i
		}
		chapters = append(chapters, fanqie.ChapterInfo{ID: m.ItemID, Index: idx + 1, Title: m.Title, IsFree: true})
	}
	h.comicDetMu.Lock()
	h.comicDetCache[bookID] = comicDetCacheEntry{info: info, chapters: chapters, at: time.Now()}
	h.comicDetMu.Unlock()
	return info, chapters, nil
}

// ComicDetail 漫画详情 + 全量话列表：GET /api/store/comics/:bookID
func (h *StoreHandler) ComicDetail(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	bookID := c.Param("bookID")
	if !fanqie.ValidateBookID(bookID) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "漫画 ID 无效"})
		return
	}
	info, chapters, err := h.fetchComic(bookID)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取漫画详情失败: " + err.Error()})
		return
	}
	emitComicDetail(c, bookID, h.imgOut(c, info.ThumbURL), info, chapters, h.comicOnShelf(c, bookID))
}

func emitComicDetail(c *gin.Context, bookID string, cover string, info *unidbg.ComicDetailInfo, chapters []fanqie.ChapterInfo, onShelf bool) {
	c.JSON(http.StatusOK, gin.H{
		"id":        bookID,
		"title":     info.BookName,
		"author":    info.Author,
		"cover":     cover,
		"synopsis":  info.Abstract,
		"category":  info.Category,
		"tags":      info.Tags,
		"score":     info.Score,
		"read_count": info.ReadCntText,
		"update_tag": info.UpdateTag,
		"finished":  info.Finished,
		"on_shelf":  onShelf,
		"chapters":  chapters,
	})
}

// comicOnShelf 该用户书架是否已收录此漫画（未入库恒为 false）
func (h *StoreHandler) comicOnShelf(c *gin.Context, bookID string) bool {
	row, err := h.DB.GetComicByFanqieID(bookID)
	if err != nil {
		return false
	}
	on, err := h.DB.IsOnShelf(middleware.UserID(c), row.ID)
	return err == nil && on
}

// ComicShelfAdd 漫画加入书架：POST /api/store/comics/:bookID/shelf
// 漫画不下载正文，轻量入库 books（source=comic）后复用通用书架链路
func (h *StoreHandler) ComicShelfAdd(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	bookID := c.Param("bookID")
	if !fanqie.ValidateBookID(bookID) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "漫画 ID 无效"})
		return
	}
	row, err := h.DB.GetComicByFanqieID(bookID)
	if err == database.ErrNotFound {
		info, chapters, err := h.fetchComic(bookID)
		if err != nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": "获取漫画详情失败: " + err.Error()})
			return
		}
		rowID, err := h.DB.UpsertComicBook(&model.Book{
			FanqieID:      bookID,
			Title:         info.BookName,
			Author:        info.Author,
			Intro:         info.Abstract,
			Cover:         info.ThumbURL,
			TotalChapters: len(chapters),
			Finished:      info.Finished,
		})
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "入库失败"})
			return
		}
		row = &model.Book{ID: rowID}
	} else if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if err := h.DB.AddShelf(middleware.UserID(c), row.ID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "加入书架失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// ComicShelfRemove 漫画移出书架：DELETE /api/store/comics/:bookID/shelf（未入库视为已移除，幂等）
func (h *StoreHandler) ComicShelfRemove(c *gin.Context) {
	bookID := c.Param("bookID")
	if !fanqie.ValidateBookID(bookID) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "漫画 ID 无效"})
		return
	}
	row, err := h.DB.GetComicByFanqieID(bookID)
	if err == database.ErrNotFound {
		c.JSON(http.StatusOK, gin.H{"ok": true})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if err := h.DB.RemoveShelf(middleware.UserID(c), row.ID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "移出书架失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// ComicChapter 漫画单话图片列表：GET /api/store/comics/:bookID/chapters/:itemID
// 上游图片 URL 是加密文件直链，这里签发成 /api/store/comicimg 代理地址
// （server 实时下载 + AES-GCM 解密透传，App 零改动直接 Image.network 渲染）。
func (h *StoreHandler) ComicChapter(c *gin.Context) {
	if !h.UNI.Enabled() {
		c.JSON(http.StatusBadGateway, gin.H{"error": "unidbg 服务未配置（XS_UNIDBG_URL）"})
		return
	}
	bookID := c.Param("bookID")
	itemID := c.Param("itemID")
	if !fanqie.ValidateBookID(bookID) || !fanqie.ValidateBookID(itemID) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "ID 无效"})
		return
	}
	imgs, encKey, err := h.UNI.ComicChapterImages(bookID, itemID)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "获取漫画内容失败: " + err.Error()})
		return
	}
	out := make([]gin.H, 0, len(imgs))
	for _, im := range imgs {
		proxy := h.signComicImg(im.URL, encKey)
		out = append(out, gin.H{
			// url 同样发代理绝对地址：已装机的老 APK 只读 url（App 零改动即可用）；
			// CDN 加密直链对客户端没有意义，不给
			"url":    absoluteReqURL(c, proxy),
			"width":  im.Width,
			"height": im.Height,
			"proxy":  proxy, // 相对路径，新客户端自行拼 baseUrl（api.dart 已支持）
		})
	}
	c.JSON(http.StatusOK, gin.H{"images": out})
}

// absoluteReqURL 把相对路径补成客户端可达的绝对地址（反代场景优先 X-Forwarded-Proto）
func absoluteReqURL(c *gin.Context, rel string) string {
	scheme := "http"
	if c.Request.TLS != nil {
		scheme = "https"
	}
	if fwd := c.GetHeader("X-Forwarded-Proto"); fwd != "" {
		scheme = fwd
	}
	return scheme + "://" + c.Request.Host + rel
}

// comicImgProxyTTL 代理 URL 有效期（阅读一话足够长，过期重进详情页自动换新）
const comicImgProxyTTL = 12 * time.Hour

// signComicImg 生成漫画图片代理 URL（HMAC 签名即鉴权，载荷含 URL+密钥+时效）
func (h *StoreHandler) signComicImg(rawurl, keyHex string) string {
	expires := time.Now().Add(comicImgProxyTTL).Unix()
	payload := rawurl + "|" + keyHex + "|" + strconv.FormatInt(expires, 10)
	encoded := base64.RawURLEncoding.EncodeToString([]byte(payload))
	mac := hmac.New(sha256.New, []byte(h.Secret))
	mac.Write([]byte(encoded))
	return "/api/store/comicimg?p=" + encoded + "&s=" + hex.EncodeToString(mac.Sum(nil))[:32]
}

// comicImgHTTP 漫画图 CDN 下载客户端（大图超时放宽）
var comicImgHTTP = &http.Client{Timeout: 60 * time.Second}

// ComicImg 漫画图片代理（公开端点，HMAC 签名即鉴权）：
// 下载番茄 CDN 加密图 → AES-256-GCM 解密（文件 = nonce(12B)‖密文‖tag(16B)，
// 密钥为该话 encrypt_key）→ 明文 JPEG 透传。10/04 Frida 实测 + md5 验证。
func (h *StoreHandler) ComicImg(c *gin.Context) {
	encoded := c.Query("p")
	signature := c.Query("s")
	if encoded == "" || signature == "" {
		c.JSON(http.StatusForbidden, gin.H{"error": "参数无效"})
		return
	}
	payload, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": "参数无效"})
		return
	}
	mac := hmac.New(sha256.New, []byte(h.Secret))
	mac.Write([]byte(encoded))
	if hex.EncodeToString(mac.Sum(nil))[:32] != signature {
		c.JSON(http.StatusForbidden, gin.H{"error": "签名无效"})
		return
	}
	parts := strings.Split(string(payload), "|")
	if len(parts) != 3 {
		c.JSON(http.StatusForbidden, gin.H{"error": "参数无效"})
		return
	}
	rawurl, keyHex, expiresStr := parts[0], parts[1], parts[2]
	expires, err := strconv.ParseInt(expiresStr, 10, 64)
	if err != nil || time.Now().Unix() > expires {
		c.JSON(http.StatusForbidden, gin.H{"error": "代理地址已过期，请重新进入本话"})
		return
	}
	if !strings.HasPrefix(rawurl, "https://") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "地址无效"})
		return
	}

	req, err := http.NewRequestWithContext(c.Request.Context(), http.MethodGet, rawurl, nil)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "地址无效"})
		return
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := comicImgHTTP.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		c.JSON(http.StatusBadGateway, gin.H{"error": "拉取漫画图片失败"})
		return
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "读取漫画图片失败"})
		return
	}

	// 无密钥 = 未加密图（上游未启用加密时的兜底），原样透传
	if keyHex == "" {
		c.Data(http.StatusOK, "image/jpeg", data)
		return
	}
	key, err := hex.DecodeString(keyHex)
	if err != nil || len(key) != 32 || len(data) < 12+16 {
		c.JSON(http.StatusBadGateway, gin.H{"error": "漫画图片密钥无效"})
		return
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "漫画图片解密失败"})
		return
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "漫画图片解密失败"})
		return
	}
	// 文件 = nonce(12B) ‖ 密文 ‖ tag(16B)；Go 约定 tag 附在密文尾部，AAD 为空
	plain, err := gcm.Open(nil, data[:12], data[12:], nil)
	if err != nil {
		log.Printf("[store] 漫画图片解密失败（密钥/nonce 不匹配）: %v", err)
		c.JSON(http.StatusBadGateway, gin.H{"error": "漫画图片解密失败"})
		return
	}
	c.Header("Cache-Control", "private, max-age=86400")
	c.Data(http.StatusOK, "image/jpeg", plain)
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
