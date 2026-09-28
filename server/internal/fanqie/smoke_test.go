package fanqie

import (
	"fmt"
	"testing"
)

// 真实网络冒烟测试：go test ./internal/fanqie/ -run TestSmokeRankFlow -v
func TestSmokeRankFlow(t *testing.T) {
	c := NewClient("")

	groups := c.GetRankGroups()
	for _, g := range groups {
		t.Logf("分组: %s (%d 项)", g.Title, len(g.Items))
	}
	if len(groups) == 0 {
		t.Fatal("榜单分组为空")
	}

	books, err := c.GetRankingBooks(groups[0].Items[0].ID, 0, 10)
	if err != nil {
		t.Fatalf("榜单书籍失败: %v", err)
	}
	for _, b := range books[:min(5, len(books))] {
		t.Logf("#%d %s / %s | 封面: %.60s | 简介: %.40s", b.Rank, b.Title, b.Author, b.Cover, b.Synopsis)
	}
	if len(books) == 0 {
		t.Fatal("榜单书籍为空")
	}

	detail, err := c.GetBookDetail(books[0].ID)
	if err != nil {
		t.Fatalf("详情失败: %v", err)
	}
	t.Logf("详情: %s | 页面章节 %d 章", detail.Synopsis, len(detail.Chapters))

	chapters, err := c.GetChapters(books[0].ID)
	if err != nil {
		t.Fatalf("目录失败: %v", err)
	}
	free := 0
	for _, ch := range chapters {
		if ch.IsFree {
			free++
		}
	}
	t.Logf("目录: 共 %d 章, 免费 %d 章, 首章: %s(%s)", len(chapters), free, chapters[0].Title, chapters[0].ID)

	if free > 0 {
		var target ChapterInfo
		for _, ch := range chapters {
			if ch.IsFree {
				target = ch
				break
			}
		}
		content, err := c.GetChapterContent(target.ID)
		if err != nil {
			t.Fatalf("正文失败: %v", err)
		}
		t.Logf("正文《%s》: %d 字 | 开头: %.80s", content.Title, len([]rune(content.Content)), content.Content)
		if len([]rune(content.Content)) < 100 {
			t.Fatalf("正文过短，可能需要 Cookie: %q", content.Content)
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// 预设榜单冒烟测试（App 推荐榜卡的网页端近似，docs §3.7）：go test ./internal/fanqie/ -run TestSmokeFeaturedBoards -v
func TestSmokeFeaturedBoards(t *testing.T) {
	c := NewClient("")
	presets := []struct {
		name                    string
		status, words, sort     int
	}{
		{"推荐榜", -1, 0, 0},
		{"完本榜", 0, 0, 0},
		{"新书榜", -1, 0, 1},
		{"巅峰榜", -1, 5, 0},
	}
	for _, p := range presets {
		books, err := c.GetLibraryBooks("1", -1, p.status, p.words, p.sort, 0, 5)
		if err != nil {
			t.Fatalf("%s 失败: %v", p.name, err)
		}
		if len(books) == 0 {
			t.Fatalf("%s 返回空列表", p.name)
		}
		for i, b := range books {
			t.Logf("%s #%d %s / %s | 在读: %s | 字数: %s", p.name, i+1, b.Title, b.Author, b.ReadCount, b.WordCount)
		}
	}
}

var _ = fmt.Sprintf
