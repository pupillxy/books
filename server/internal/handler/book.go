package handler

import (
	"bytes"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

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
	// BridgeURL 真机签名桥地址（XS_APP_BRIDGE_URL，空=禁用）：unidbg 被内容风控时的
	// 最终兜底——桥让真番茄 App 自己签名代发正文，风控无法区分
	BridgeURL string
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

	// 当前章 + 下一章合并为一次批量请求（batch 才是免风控端点，单章高频必被打标）
	ids := []string{srcID}
	titles := map[string]string{srcID: ch.Title}
	nextSrc := ""
	if nxCh, err2 := h.DB.GetChapter(id, idx+1); err2 == nil {
		if nxSrc, err3 := h.DB.GetChapterSrcID(id, idx+1); err3 == nil && nxSrc != "" {
			ids = append(ids, nxSrc)
			titles[nxSrc] = nxCh.Title
			nextSrc = nxSrc
		}
	}
	res, ferr := h.fetchOnlineContents(book.FanqieID, ids, titles)
	content, ctitle := res[srcID], ch.Title
	if len([]rune(content)) < 50 {
		log.Printf("[store] 在线正文失败 book=%d idx=%d locked=%v: %v", id, idx, errors.Is(ferr, fanqie.ErrChapterLocked), ferr)
		c.JSON(http.StatusPaymentRequired, gin.H{"error": "该章节正文暂时获取失败，请稍后重试", "title": ctitle})
		return
	}
	_ = h.DB.FillChapterContent(id, idx, content)
	ch.Content = content

	// 下一章已在同一批量里取回，直接落库（阅读翻页无感）
	if nextSrc != "" {
		if nxTxt := res[nextSrc]; len([]rune(nxTxt)) >= 50 {
			_ = h.DB.FillChapterContent(id, idx+1, nxTxt)
		}
	}

	c.JSON(http.StatusOK, ch)
}

// fetchOnlineContents 在线正文：网页端优先，未命中走 unidbg 批量（解密明文）。
// 单章端点高频必触发设备风控，已弃用（10/03 事故）。titles 用于剥掉
// unidbg txtContent 首行的章节名；ferr 为网页端的最后一个错误（402 判定用）。
func (h *BookHandler) fetchOnlineContents(fid string, srcIDs []string, titles map[string]string) (map[string]string, error) {
	out := map[string]string{}
	var ferr error
	var missing []string
	for _, sid := range srcIDs {
		cc, err := h.FQ.GetChapterContent(sid)
		if err == nil && len([]rune(cc.Content)) >= 50 {
			out[sid] = cc.Content
			continue
		}
		if err != nil && ferr == nil {
			ferr = err
		}
		missing = append(missing, sid)
	}
	if len(missing) > 0 && h.UNI != nil && h.UNI.Enabled() {
		res, err := h.UNI.ChapterContentsBatch(fid, missing)
		if err == nil {
			for sid, txt := range res {
				txt = strings.TrimPrefix(txt, titles[sid]+"\n")
				if len([]rune(txt)) >= 50 {
					out[sid] = txt
				}
			}
		}
	}
	// 最终兜底：真机签名桥（App 自己签名代发，风控无法区分；unidbg 被打标时的救命通道）
	if h.BridgeURL != "" {
		for _, sid := range missing {
			if _, ok := out[sid]; ok {
				continue
			}
			txt, err := h.bridgeChapter(fid, sid, titles[sid])
			if err != nil {
				log.Printf("[bridge] 正文兜底失败 sid=%s: %v", sid, err)
				continue
			}
			out[sid] = txt
		}
	}
	return out, ferr
}

// bridgeChapter 经真机签名桥取单章正文（App 代签代发 + Java 解密，桥内完成）
func (h *BookHandler) bridgeChapter(fid, srcID, title string) (string, error) {
	body, _ := json.Marshal(map[string]string{
		"path":  "/reading/reader/batch_full/v",
		"query": "item_ids=" + srcID + "&key_register_ts=0&book_id=" + fid + "&req_type=1",
	})
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(h.BridgeURL, "/")+"/content",
		bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		Code int `json:"code"`
		Data struct {
			Chapters map[string]struct {
				TxtContent string `json:"txtContent"`
			} `json:"chapters"`
		} `json:"data"`
		Error string `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if out.Code != 0 {
		return "", errors.New(out.Error)
	}
	item, ok := out.Data.Chapters[srcID]
	if !ok || item.TxtContent == "" {
		return "", errors.New("桥返回无正文")
	}
	return strings.TrimPrefix(item.TxtContent, title+"\n"), nil
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
