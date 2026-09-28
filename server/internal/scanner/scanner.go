package scanner

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"xiaoshuo/internal/database"
	"xiaoshuo/internal/model"
)

type Scanner struct {
	DB  *database.DBStore
	Dir string

	mu           sync.Mutex
	lastScan     time.Time
	scanning     bool
	lastImported int
}

func New(db *database.DBStore, dir string) *Scanner {
	return &Scanner{DB: db, Dir: dir}
}

// Status 返回上次扫描时间、是否在扫、上次导入本数
func (s *Scanner) Status() (time.Time, bool, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastScan, s.scanning, s.lastImported
}

func (s *Scanner) RunOnce() {
	s.mu.Lock()
	if s.scanning {
		s.mu.Unlock()
		return
	}
	s.scanning = true
	s.mu.Unlock()

	start := time.Now()
	imported := s.scan()
	s.mu.Lock()
	s.scanning = false
	s.lastScan = time.Now()
	s.lastImported = imported
	s.mu.Unlock()
	log.Printf("[scanner] 完成: 导入/更新 %d 本, 耗时 %s", imported, time.Since(start).Round(time.Millisecond))
}

func (s *Scanner) scan() int {
	imported := 0
	// TND 下载目录（{bookId}_{书名}/downloaded_chapters.jsonl）
	imported += s.ScanTNDBooks()
	filepath.WalkDir(s.Dir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		// 跳过音频/封面等附属目录
		if d.IsDir() {
			if strings.Contains(strings.ToLower(name), "audio") || strings.HasPrefix(name, ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.EqualFold(filepath.Ext(name), ".txt") {
			return nil
		}
		if s.importOne(path) {
			imported++
		}
		return nil
	})
	return imported
}

func (s *Scanner) importOne(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	size, mtime := info.Size(), info.ModTime().Unix()

	// 未变化的书直接跳过
	if existing, err := s.DB.GetBookByPath(path); err == nil {
		if existing.FileSize == size && existing.FileMtime == mtime && existing.TotalChapters > 0 {
			return false
		}
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		log.Printf("[scanner] 读取失败 %s: %v", path, err)
		return false
	}
	text, err := decodeText(raw)
	if err != nil {
		log.Printf("[scanner] 解码失败 %s: %v", path, err)
		return false
	}

	title, author, intro := extractMeta(text, filepath.Base(path))
	chapters := SplitChapters(text)
	if len(chapters) == 0 {
		log.Printf("[scanner] 未解析到内容 %s", path)
		return false
	}

	cover := findCover(filepath.Dir(path))
	book := &model.Book{
		Title: title, Author: author, Intro: intro, Cover: cover,
		FilePath: path, FileSize: size, FileMtime: mtime,
		TotalChapters: len(chapters),
	}
	bookID, err := s.DB.UpsertBook(book)
	if err != nil {
		log.Printf("[scanner] 入库失败 %s: %v", path, err)
		return false
	}
	for i, ch := range chapters {
		if err := s.DB.InsertChapter(bookID, i, ch.Title, ch.Content); err != nil {
			log.Printf("[scanner] 章节入库失败 %s #%d: %v", path, i, err)
			return false
		}
	}
	log.Printf("[scanner] 导入: %s (%d 章, %s)", title, len(chapters), humanSize(size))

	// 有同名的待下载任务 → 认定 TND 下载完成，合并在线书（书架/进度迁移到本地行）
	if task, err := s.DB.MatchRunningTaskByTitle(title); err == nil {
		if err := s.DB.MergeOnlineIntoLocal(task.FanqieID, bookID); err != nil {
			log.Printf("[scanner] 合并在线书失败 %s: %v", title, err)
		} else {
			_ = s.DB.SetDownloadTaskStatus(task.FanqieID, "done")
			log.Printf("[scanner] 已合并在线书: %s (番茄ID %s)", title, task.FanqieID)
		}
	}
	return true
}

func findCover(dir string) string {
	candidates := []string{"cover.jpg", "cover.png", "cover.jpeg", "cover.webp"}
	for _, c := range candidates {
		p := filepath.Join(dir, c)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func humanSize(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1fMB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1fKB", float64(n)/(1<<10))
	default:
		return fmt.Sprintf("%dB", n)
	}
}
