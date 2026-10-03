package handler

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"xiaoshuo/internal/database"
	"xiaoshuo/internal/fanqie"
	"xiaoshuo/internal/middleware"
	"xiaoshuo/internal/scanner"
	"xiaoshuo/internal/unidbg"
)

type BookHandler struct {
	DB      *database.DBStore
	Scanner *scanner.Scanner
	FQ      *fanqie.Client
	UNI     *unidbg.Client
	// RequestDownload 在正文两源都失败时被调用（自动触发整本获取，由 main 注入 storeH.triggerDownload）
	RequestDownload func(fid, title string, bookID int64) string
}

func (h *BookHandler) List(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	size, _ := strconv.Atoi(c.DefaultQuery("size", "20"))
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 100 {
		size = 20
	}
	books, total, err := h.DB.ListBooks(c.Query("keyword"), (page-1)*size, size)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"total": total, "page": page, "size": size, "items": books})
}

func (h *BookHandler) Detail(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	book, err := h.DB.GetBookByID(id)
	if err == database.ErrNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "书籍不存在"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	chapters, err := h.DB.ListChapterMeta(id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询章节失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"book": book, "chapters": chapters})
}

// Chapter 混合读取：本地命中 → 在线拉取回填 → 双源失败提示稍后重试
func (h *BookHandler) Chapter(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	idx, err := strconv.Atoi(c.Param("idx"))
	if err != nil || idx < 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	ch, err := h.DB.GetChapter(id, idx)
	if err == database.ErrNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "章节不存在"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if ch.Content != "" {
		c.JSON(http.StatusOK, ch)
		return
	}

	// content 为空 → 在线书按需拉取正文并缓存
	book, berr := h.DB.GetBookByID(id)
	if berr != nil || book.FanqieID == "" || h.FQ == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "章节内容为空"})
		return
	}
	srcID, err := h.DB.GetChapterSrcID(id, idx)
	if err != nil || srcID == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "章节内容为空"})
		return
	}

	content, ctitle, ferr := h.fetchOnlineContent(book.FanqieID, srcID, ch.Title)
	if len([]rune(content)) < 50 {
		// 双源都拿不到正文（多为设备内容风控，冷却后自愈）：提示重试，后台顺带准备整本
		if h.RequestDownload != nil {
			go func() { _ = h.RequestDownload(book.FanqieID, book.Title, book.ID) }()
		}
		log.Printf("[store] 在线正文失败 book=%d idx=%d locked=%v: %v", id, idx, errors.Is(ferr, fanqie.ErrChapterLocked), ferr)
		c.JSON(http.StatusPaymentRequired, gin.H{"error": "该章节正文暂时获取失败，请稍后重试", "title": ctitle})
		return
	}
	_ = h.DB.FillChapterContent(id, idx, content)
	ch.Content = content

	// 预取下一章：阅读翻页无感（幂等，已有内容自动跳过）
	go h.backfillChapter(id, book.FanqieID, idx+1)

	c.JSON(http.StatusOK, ch)
}

// fetchOnlineContent 在线正文：网页端优先，被风控/锁定时退 unidbg（App 协议同源数据）。
// 返回值 ferr 为网页端错误（ErrChapterLocked 判定用）。
func (h *BookHandler) fetchOnlineContent(fid, srcID, title string) (content, ctitle string, ferr error) {
	cc, err := h.FQ.GetChapterContent(srcID)
	ferr = err
	if err == nil && len([]rune(cc.Content)) >= 50 {
		return cc.Content, cc.Title, nil
	}
	if h.UNI != nil && h.UNI.Enabled() {
		txt, uerr := h.UNI.ChapterContent(fid, srcID)
		if uerr == nil {
			txt = strings.TrimPrefix(txt, title+"\n") // unidbg txtContent 首行是章节名
			if len([]rune(txt)) >= 50 {
				return txt, title, nil
			}
		}
	}
	return "", "", ferr
}

// backfillChapter 单章按需回填（幂等）：已有正文直接跳过
func (h *BookHandler) backfillChapter(bookID int64, fid string, idx int) {
	if fid == "" {
		return
	}
	ch, err := h.DB.GetChapter(bookID, idx)
	if err != nil || ch.Content != "" {
		return
	}
	srcID, err := h.DB.GetChapterSrcID(bookID, idx)
	if err != nil || srcID == "" {
		return
	}
	content, _, _ := h.fetchOnlineContent(fid, srcID, ch.Title)
	if len([]rune(content)) >= 50 {
		_ = h.DB.FillChapterContent(bookID, idx, content)
	}
}

func (h *BookHandler) TriggerScan(c *gin.Context) {
	go h.Scanner.RunOnce()
	c.JSON(http.StatusOK, gin.H{"ok": true, "msg": "扫描已触发"})
}

func (h *BookHandler) ScanStatus(c *gin.Context) {
	last, importing, imported := h.Scanner.Status()
	_, total, _ := h.DB.ListBooks("", 0, 1)
	c.JSON(http.StatusOK, gin.H{
		"last_scan":      last,
		"scanning":       importing,
		"last_imported":  imported,
		"total_books":    total,
	})
}

type ShelfHandler struct {
	DB *database.DBStore
}

func (h *ShelfHandler) List(c *gin.Context) {
	items, err := h.DB.ListShelf(middleware.UserID(c))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if items == nil {
		items = []*database.ShelfItem{}
	}
	c.JSON(http.StatusOK, items)
}

func (h *ShelfHandler) Add(c *gin.Context) {
	var req struct {
		BookID int64 `json:"book_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if _, err := h.DB.GetBookByID(req.BookID); err == database.ErrNotFound {
		c.JSON(http.StatusNotFound, gin.H{"error": "书籍不存在"})
		return
	}
	if err := h.DB.AddShelf(middleware.UserID(c), req.BookID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "加入书架失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (h *ShelfHandler) Remove(c *gin.Context) {
	bookID, err := strconv.ParseInt(c.Param("bookId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if err := h.DB.RemoveShelf(middleware.UserID(c), bookID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "移出书架失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

type ProgressHandler struct {
	DB *database.DBStore
}

func (h *ProgressHandler) Save(c *gin.Context) {
	var req struct {
		BookID     int64 `json:"book_id" binding:"required"`
		ChapterIdx int   `json:"chapter_idx"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if err := h.DB.UpsertProgress(middleware.UserID(c), req.BookID, req.ChapterIdx); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存进度失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

func (h *ProgressHandler) Get(c *gin.Context) {
	bookID, err := strconv.ParseInt(c.Param("bookId"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	idx, err := h.DB.GetProgress(middleware.UserID(c), bookID)
	if err != nil && err != database.ErrNotFound {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"book_id": bookID, "chapter_idx": idx})
}
