package unidbg

import (
	"strings"
	"testing"
	"time"
)

// TestSmokeUnidbg 对着真实 unidbg 服务（默认 127.0.0.1:9999）验证搜索/目录/批量正文。
// 服务未启动时跳过：go test 时设 XS_UNIDBG_SMOKE=1 强制执行。
func TestSmokeUnidbg(t *testing.T) {
	c := New("http://127.0.0.1:9999")
	if !c.Enabled() {
		t.Skip("unidbg 未配置")
	}

	// 探活：100ms 内连不上视为服务未启动，跳过而非失败
	client := *c.HTTP
	client.Timeout = 2 * time.Second
	if _, err := client.Get(c.BaseURL + "/api/fq-signature/health"); err != nil {
		t.Skipf("unidbg 服务未启动: %v", err)
	}

	// 1) 搜索（上游 IP 限流/风控时跳过，不视为代码缺陷）
	books, err := c.Search("剑来", 3)
	if err != nil {
		t.Skipf("上游不可用（限流/风控冷却中）: %v", err)
	}
	if len(books) == 0 {
		t.Fatal("搜索无结果")
	}
	t.Logf("搜索命中: %s / %s (bookId=%s)", books[0].BookName, books[0].Author, books[0].BookID)
	fid := books[0].BookID

	// 2) 目录
	metas, err := c.Directory(fid)
	if err != nil {
		t.Skipf("上游目录不可用: %v", err)
	}
	if len(metas) < 2 || metas[0].ItemID == "" {
		t.Fatalf("目录异常: %d 章", len(metas))
	}
	t.Logf("目录: %d 章, 第1章 %q (item=%s)", len(metas), metas[0].Title, metas[0].ItemID)

	// 3) 书籍信息
	info, err := c.BookInfo(fid)
	if err != nil || info == nil || info.BookName == "" {
		t.Fatalf("BookInfo: %v", err)
	}
	t.Logf("book_info: %s / %s / creationStatus=%s", info.BookName, info.Author, info.CreationStatus)

	// 4) 批量正文（DownloadBook 的核心调用，取前 2 章验证）
	var out struct {
		Chapters map[string]struct {
			ChapterName string `json:"chapterName"`
			TxtContent  string `json:"txtContent"`
		} `json:"chapters"`
	}
	req := map[string]any{"bookId": fid, "chapterIds": []string{metas[0].ItemID, metas[1].ItemID}}
	if err := c.postJSON("/api/fqnovel/chapters/batch", req, &out); err != nil {
		t.Skipf("上游批量内容不可用: %v", err)
	}
	c0 := out.Chapters[metas[0].ItemID].TxtContent
	if len(c0) < 100 {
		t.Fatalf("正文过短: %d 字", len(c0))
	}
	t.Logf("批量正文: 第1章 %d 字, 开头 %q", len(c0), truncate(c0, 40))
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
