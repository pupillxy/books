package handler

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"xiaoshuo/internal/database"
	"xiaoshuo/internal/fanqie"
	"xiaoshuo/internal/middleware"
	"xiaoshuo/internal/scanner"
	"xiaoshuo/internal/tnd"
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
	// TND 按需单章兜底通道（XS_TND_URL）：范围任务拉当前章+下一章，产物落 BooksDir
	TND      *tnd.Client
	BooksDir string // TND 产物目录（= XS_DOWNLOAD_DIR，server 与 TND 共享挂载）

	// 通道健康记忆：某通道连续失败后 10 分钟内直接跳过，避免每章白等超时
	// （设备被标时 unidbg 每次白耗 10s、桥下线时每次白耗 12~24s）
	healthMu        sync.Mutex
	uniDeadUntil    time.Time
	bridgeDeadUntil time.Time
}

const channelCooldown = 10 * time.Minute

func (h *BookHandler) markDead(dead *time.Time) {
	h.healthMu.Lock()
	*dead = time.Now().Add(channelCooldown)
	h.healthMu.Unlock()
}

func (h *BookHandler) markAlive(dead *time.Time) {
	h.healthMu.Lock()
	*dead = time.Time{}
	h.healthMu.Unlock()
}

func (h *BookHandler) isDead(dead *time.Time) bool {
	h.healthMu.Lock()
	defer h.healthMu.Unlock()
	return time.Now().Before(*dead)
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
	res, ferr := h.fetchOnlineContents(book.FanqieID, idx, ids, titles)
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

// uniChannelEnabled 临时开关：unidbg 设备被内容风控标记期间（响应格式异常，
// 冷却 >1h 且反复）关闭该通道，正文直接走桥/TND，省掉每章 ~10s 的必败重试。
// 换设备或确认冷却自愈后改回 true（10/04）。
const uniChannelEnabled = false

// bridgeChannelEnabled / webChannelEnabled 临时开关（10/05）：桥只在 PC 开机且
// 模拟器常驻时可用，其余时间每个健康记忆窗口（10min）到期后的第一笔正文都要
// 白等 12s 拨号超时；网页端对「仅试读」章必败且慢。当前正文只走 TND（③），
// 恢复对应通道时改回 true。
const bridgeChannelEnabled = false
const webChannelEnabled = false

// fetchOnlineContents 在线正文：当前只走 TND 范围任务（读全量正文、无设备风控
// 压力，实测 ~5s/次）。App 协议/真机签名桥/网页端三个通道临时关闭（见上方
// const 开关）。整体预算 50s（App 接收超时 60s）。titles 用于剥掉 unidbg
// txtContent 首行的章节名；ferr 为 TND 的最后一个错误（402 日志判定用）。
func (h *BookHandler) fetchOnlineContents(fid string, firstIdx int, srcIDs []string, titles map[string]string) (map[string]string, error) {
	out := map[string]string{}
	var ferr error
	deadline := time.Now().Add(50 * time.Second)

	// ① App 协议批量（当前章+下一章一请求；设备被标记时在此失败，静默降级）
	if uniChannelEnabled && h.UNI != nil && h.UNI.Enabled() && !h.isDead(&h.uniDeadUntil) {
		res, err := h.UNI.ChapterContentsBatch(fid, srcIDs)
		if err != nil {
			log.Printf("[uni] 批量正文失败 fid=%s n=%d: %v（10 分钟内跳过）", fid, len(srcIDs), err)
			h.markDead(&h.uniDeadUntil)
		} else {
			h.markAlive(&h.uniDeadUntil)
			for sid, txt := range res {
				txt = strings.TrimPrefix(txt, titles[sid]+"\n")
				if len([]rune(txt)) >= 50 {
					out[sid] = txt
				}
			}
		}
	}

	// ② 真机签名桥（App 代签代发，风控无法区分；unidbg 被打标时的救命通道）
	if bridgeChannelEnabled && h.BridgeURL != "" && !h.isDead(&h.bridgeDeadUntil) {
		for i, sid := range srcIDs {
			if _, ok := out[sid]; ok || time.Now().After(deadline) {
				continue
			}
			txt, err := h.bridgeChapter(fid, sid, titles[sid])
			if err != nil {
				log.Printf("[bridge] 正文兜底失败 sid=%s: %v（10 分钟内跳过）", sid, err)
				h.markDead(&h.bridgeDeadUntil)
				break // 桥挂了其余 sid 也会挂，把时间留给后面的通道
			}
			if i == 0 {
				h.markAlive(&h.bridgeDeadUntil)
			}
			out[sid] = txt
		}
	}

	// ③ TND 范围任务（读全量正文、走官方接口无设备风控压力，8~15s/次）；
	// unidbg 关闭期间它就是主力通道，网页端降为最后兜底
	if h.TND != nil && h.TND.Enabled() && len(out) < len(srcIDs) && time.Now().Before(deadline) {
		need := make([]string, 0, len(srcIDs))
		for _, sid := range srcIDs {
			if _, ok := out[sid]; !ok {
				need = append(need, sid)
			}
		}
		txts, err := h.tndChapters(fid, firstIdx, srcIDs, need, deadline)
		if err != nil {
			log.Printf("[tnd] 单章兜底失败 fid=%s need=%d: %v", fid, len(need), err)
			if ferr == nil {
				ferr = err
			}
		} else {
			log.Printf("[tnd] 单章兜底成功 fid=%s got=%d", fid, len(txts))
			for sid, txt := range txts {
				out[sid] = txt
			}
		}
	}

	// ④ 网页端最后兜底（免费章可用；「付费仅预览」章在网页端判定锁定）
	if webChannelEnabled && h.FQ != nil {
		for _, sid := range srcIDs {
			if _, ok := out[sid]; ok || time.Now().After(deadline) {
				continue
			}
			cc, err := h.FQ.GetChapterContent(sid)
			if err == nil && len([]rune(cc.Content)) >= 50 {
				out[sid] = cc.Content
				continue
			}
			if err != nil && ferr == nil {
				ferr = err
			}
		}
	}
	return out, ferr
}

// tndChapters 经 TND 范围任务拉取缺失章节并解析产物。from/to 按 TND 的
// 1 基目录序；产物优先 status.json（item_id 精确匹配），回退最新 epub 按序。
func (h *BookHandler) tndChapters(fid string, firstIdx int, srcIDs []string, need []string, deadline time.Time) (map[string]string, error) {
	// 缺失章在 srcIDs 里的位置 → TND 1 基目录序（srcIDs[0] = firstIdx+1 话/章）
	posSet := map[int]bool{}
	for _, sid := range need {
		for k, s := range srcIDs {
			if s == sid {
				posSet[k] = true
			}
		}
	}
	minK, maxK := len(srcIDs)-1, 0
	for k := range posSet {
		if k < minK {
			minK = k
		}
		if k > maxK {
			maxK = k
		}
	}
	from, to := firstIdx+minK+1, firstIdx+maxK+1

	jobStart := time.Now()
	jid, err := h.TND.CreateRangeJob(fid, from, to)
	if err != nil {
		return nil, err
	}
	wait := time.Until(deadline)
	if wait > 35*time.Second {
		wait = 35 * time.Second
	}
	state, err := h.TND.WaitJob(jid, wait)
	if err != nil {
		return nil, err
	}
	if state != "done" {
		return nil, fmt.Errorf("TND 任务 %d 结束态 %s", jid, state)
	}

	// 产物 A：status.json 的 downloaded[item_id] = [章名, HTML]，item_id 精确匹配
	res := map[string]string{}
	var sj struct {
		Downloaded map[string][]string `json:"downloaded"`
	}
	if raw, rerr := os.ReadFile(filepath.Join(h.BooksDir, fid, "status.json")); rerr == nil {
		if json.Unmarshal(raw, &sj) == nil {
			for _, sid := range need {
				if pair := sj.Downloaded[sid]; len(pair) >= 2 {
					if txt := stripHTML(pair[1]); len([]rune(txt)) >= 50 {
						res[sid] = txt
					}
				}
			}
		}
	}
	if len(res) == len(need) {
		return res, nil
	}

	// 产物 B：任务窗口内新生成的《书名》.epub，OEBPS/chapter_NNN.xhtml 按范围序排列
	epub, err := newestEpubSince(h.BooksDir, jobStart.Add(-2*time.Second))
	if err != nil {
		if len(res) > 0 {
			return res, nil
		}
		return nil, err
	}
	chs, err := epubChapters(epub)
	if err != nil {
		if len(res) > 0 {
			return res, nil
		}
		return nil, err
	}
	for k, sid := range srcIDs {
		if !posSet[k] {
			continue
		}
		i := (firstIdx + k) - from // epub 内的序号
		if i < 0 || i >= len(chs) {
			continue
		}
		if txt := stripHTML(chs[i]); len([]rune(txt)) >= 50 {
			if _, ok := res[sid]; !ok {
				res[sid] = txt
			}
		}
	}
	if len(res) == 0 {
		return nil, fmt.Errorf("TND 产物中未找到 %d 章（status.json/epub 均未命中）", len(need))
	}
	return res, nil
}

var (
	reHTMLBlock = regexp.MustCompile(`(?i)</?(p|h[1-6]|div|blk|br)[^>]*>`)
	reHTMLAny   = regexp.MustCompile(`<[^>]+>`)
	reVoiceMark = regexp.MustCompile(`\{!--\s*PGC_VOICE:.*?--\}`)
	reBlankLine = regexp.MustCompile(`\n{3,}`)
)

// stripHTML 番茄网页格式正文 → 纯文本（块级标签转换行，剥其余标签，解实体）
func stripHTML(s string) string {
	s = reVoiceMark.ReplaceAllString(s, "")
	s = reHTMLBlock.ReplaceAllString(s, "\n")
	s = reHTMLAny.ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	s = reBlankLine.ReplaceAllString(s, "\n\n")
	return strings.TrimSpace(s)
}

// newestEpubSince 找目录里 mtime 晚于 since 的最新 epub（TND 任务刚生成的）
func newestEpubSince(dir string, since time.Time) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var best string
	var bestAt time.Time
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(strings.ToLower(e.Name()), ".epub") {
			continue
		}
		info, err := e.Info()
		if err != nil || info.ModTime().Before(since) {
			continue
		}
		if info.ModTime().After(bestAt) {
			best, bestAt = filepath.Join(dir, e.Name()), info.ModTime()
		}
	}
	if best == "" {
		return "", fmt.Errorf("目录中无新生成的 epub")
	}
	return best, nil
}

// epubChapters 解开 epub，按 chapter_NNN 序返回各章 xhtml 原文（未剥标签）
func epubChapters(path string) ([]string, error) {
	zr, err := zip.OpenReader(path)
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	reCh := regexp.MustCompile(`chapter_(\d+)\.xhtml$`)
	type numbered struct {
		n int
		i int
	}
	var nums []numbered
	for i, f := range zr.File {
		if m := reCh.FindStringSubmatch(f.Name); m != nil {
			n, _ := strconv.Atoi(m[1])
			nums = append(nums, numbered{n: n, i: i})
		}
	}
	if len(nums) == 0 {
		return nil, fmt.Errorf("epub 内无 chapter_NNN.xhtml")
	}
	sort.Slice(nums, func(a, b int) bool { return nums[a].n < nums[b].n })
	out := make([]string, 0, len(nums))
	for _, x := range nums {
		rc, err := zr.File[x.i].Open()
		if err != nil {
			return nil, err
		}
		raw, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, err
		}
		out = append(out, string(raw))
	}
	return out, nil
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
	// 桥下线时连接会挂住，必须短超时把时间留给后面的网页兜底
	client := &http.Client{Timeout: 12 * time.Second}
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
