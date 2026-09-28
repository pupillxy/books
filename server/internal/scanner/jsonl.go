package scanner

// TND (Tomato-Novel-Downloader) 下载目录支持：
// 每本书一个目录，命名 `{bookId}_{书名}`，内含
//   - downloaded_chapters.jsonl  每行一章 {"id","title","content"(HTML)}
//   - status.json                {"book_id","book_name","author","description","chapter_count",...}
//
// 未下载完时只导入已有章节并保持 status=downloading（阅读器走在线兜底），
// 下载完成后重扫升级为 ready。

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"xiaoshuo/internal/model"
)

var reTNDBookDir = regexp.MustCompile(`^(\d+)(?:_(.+))?$`) // 兼容裸 ID 目录（TND 拿不到书名时不加后缀）
var reH1Block = regexp.MustCompile(`<h1[\s\S]*?</h1>`)
var reHTMLTag = regexp.MustCompile(`<[^>]+>`)

type tndStatus struct {
	BookID       string `json:"book_id"`
	BookName     string `json:"book_name"`
	Author       string `json:"author"`
	Description  string `json:"description"`
	ChapterCount int    `json:"chapter_count"`
}

// ScanTNDBooks 扫描下载目录中的 TND 书籍目录（\d+_书名），导入或升级。
// 返回导入/更新的本数。
func (s *Scanner) ScanTNDBooks() int {
	imported := 0
	entries, err := os.ReadDir(s.Dir)
	if err != nil {
		return 0
	}
	for _, e := range entries {
		if !e.IsDir() || !reTNDBookDir.MatchString(e.Name()) {
			continue
		}
		dir := filepath.Join(s.Dir, e.Name())
		if s.importTND(dir) {
			imported++
		}
	}
	return imported
}

func (s *Scanner) importTND(dir string) bool {
	jsonlPath := filepath.Join(dir, "downloaded_chapters.jsonl")
	info, err := os.Stat(jsonlPath)
	if err != nil || info.IsDir() {
		return false
	}

	// 元数据：status.json 优先，缺字段时回退目录名
	st := tndStatus{}
	if raw, err := os.ReadFile(filepath.Join(dir, "status.json")); err == nil {
		_ = json.Unmarshal(bytes.TrimPrefix(raw, []byte("\xEF\xBB\xBF")), &st) // 容忍 BOM
	}
	m := reTNDBookDir.FindStringSubmatch(filepath.Base(dir))
	if st.BookID == "" && m != nil {
		st.BookID = m[1]
	}
	if st.BookName == "" && m != nil {
		st.BookName = m[2]
	}
	if st.BookID == "" || st.BookName == "" {
		return false
	}

	chapters, err := parseTNDJSONL(jsonlPath)
	if err != nil {
		log.Printf("[scanner] TND jsonl 解析失败 %s: %v", dir, err)
		return false
	}
	if len(chapters) == 0 {
		return false
	}

	complete := st.ChapterCount > 0 && len(chapters) >= st.ChapterCount
	if !complete && st.ChapterCount == 0 {
		complete = true // 元数据缺失时按已完成处理
	}

	// 未变化的书跳过（TND 增量写入会更新 mtime）
	if existing, err := s.DB.GetBookByPath(jsonlPath); err == nil {
		if existing.FileMtime == info.ModTime().Unix() && existing.TotalChapters == len(chapters) {
			return false
		}
	}

	status := "downloading"
	if complete {
		status = "ready"
	}

	// 已在库（在线行）→ 原地升级；不在库 → 新建本地行
	book, err := s.DB.GetBookByFanqieID(st.BookID)
	if err == nil {
		if complete {
			// 全本到手：整体替换
			if err := s.DB.ReplaceChapters(book.ID, chapters); err != nil {
				log.Printf("[scanner] TND 章节写入失败 %s: %v", st.BookName, err)
				return false
			}
		} else {
			// 下载中：按 idx 回填已下章节，保留其余章节的在线兜底 meta
			for _, ch := range chapters {
				if err := s.DB.UpsertChapterContent(book.ID, ch.Idx, ch.Title, ch.Content); err != nil {
					log.Printf("[scanner] TND 章节回填失败 %s #%d: %v", st.BookName, ch.Idx, err)
					return false
				}
			}
		}
		intro := book.Intro
		if intro == "" {
			intro = st.Description
		}
		total := len(chapters)
		if book.TotalChapters > total {
			total = book.TotalChapters
		}
		if _, err := s.DB.Exec(`UPDATE books SET status=?, total_chapters=?, intro=?, file_path=?, file_size=?, file_mtime=? WHERE id=?`,
			status, total, intro, jsonlPath, info.Size(), info.ModTime().Unix(), book.ID); err != nil {
			log.Printf("[scanner] TND 更新书籍失败 %s: %v", st.BookName, err)
			return false
		}
	} else {
		nb := &model.Book{
			Title: st.BookName, Author: st.Author, Intro: st.Description,
			FanqieID: st.BookID, Source: "fanqie", Status: status,
			FilePath: jsonlPath, FileSize: info.Size(), FileMtime: info.ModTime().Unix(),
			TotalChapters: len(chapters),
		}
		id, err := s.DB.UpsertBook(nb)
		if err != nil {
			log.Printf("[scanner] TND 入库失败 %s: %v", st.BookName, err)
			return false
		}
		if err := s.DB.ReplaceChapters(id, chapters); err != nil {
			log.Printf("[scanner] TND 章节写入失败 %s: %v", st.BookName, err)
			return false
		}
		book, _ = s.DB.GetBookByPath(jsonlPath)
		if book == nil {
			return false
		}
	}

	// 有下载任务则标记完成
	if task, err := s.DB.GetDownloadTask(st.BookID); err == nil && task.Status != "done" && complete {
		_ = s.DB.SetDownloadTaskStatus(st.BookID, "done")
	}

	if complete {
		log.Printf("[scanner] TND 导入: %s (%d 章, 全本)", st.BookName, len(chapters))
	} else {
		log.Printf("[scanner] TND 增量: %s (%d/%s 章, 下载中)",
			st.BookName, len(chapters), strconv.Itoa(st.ChapterCount))
	}
	return true
}

type tndChapter struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Content string `json:"content"`
}

func parseTNDJSONL(path string) ([]model.Chapter, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	raw = bytes.TrimPrefix(raw, []byte("\xEF\xBB\xBF")) // 容忍 BOM

	var out []model.Chapter
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var c tndChapter
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			continue // 跳过损坏行
		}
		content := cleanTNDHTML(c.Content)
		if content == "" && c.Title == "" {
			continue
		}
		out = append(out, model.Chapter{Idx: len(out), Title: c.Title, Content: content})
	}
	return out, nil
}

// cleanTNDHTML 清洗 TND 章节正文：丢 <h1> 标题块，</p> 转换行，去标签，反转义实体
func cleanTNDHTML(raw string) string {
	if raw == "" {
		return ""
	}
	s := reH1Block.ReplaceAllString(raw, "")
	s = strings.ReplaceAll(s, "</p>", "\n")
	s = reHTMLTag.ReplaceAllString(s, "")
	r := strings.NewReplacer(
		"&nbsp;", " ", "&lt;", "<", "&gt;", ">",
		"&amp;", "&", "&quot;", `"`, "&apos;", "'", "&#39;", "'",
	)
	s = r.Replace(s)
	// 规整空白行
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimSpace(l)
	}
	return strings.Trim(strings.Join(lines, "\n"), "\n")
}
