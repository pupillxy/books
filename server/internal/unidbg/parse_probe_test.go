package unidbg

import (
	"time"
	"encoding/json"
	"os"
	"testing"
)

// TestParseCellViewSample 用抓包回放保存的真实响应验证 parseCellViewBooks（离线，无服务依赖）
func TestParseCellViewSample(t *testing.T) {
	raw, err := os.ReadFile(`D:\dev\xiaoshuo\_reference\fqemu\capture_xiaoshuo_1003\resp_local_rankpage.json`)
	if err != nil {
		t.Skipf("样本文件不存在: %v", err)
	}
	var env struct {
		Code int             `json:"code"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		t.Fatalf("样本解析: %v", err)
	}
	books, err := parseCellViewBooks(env.Data)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(books) < 10 {
		t.Fatalf("书籍数异常: %d", len(books))
	}
	t.Logf("解析出 %d 本, 第一本: %s / %s (%s)", len(books), books[0].BookName, books[0].Author, books[0].ReadCount)
}

// TestRankPageBooksLive 对本地 unidbg 实拉验证完整榜单协议（服务未启动则跳过）
func TestRankPageBooksLive(t *testing.T) {
	c := New("http://127.0.0.1:9999")
	client := *c.HTTP
	client.Timeout = 2 * time.Second
	if _, err := client.Get(c.BaseURL + "/api/fq-signature/health"); err != nil {
		t.Skipf("unidbg 服务未启动: %v", err)
	}
	boys, err := c.RankPageBooks(100, "1")
	if err != nil {
		t.Skipf("上游不可用（限流/风控冷却中）: %v", err)
	}
	if len(boys) < 10 {
		t.Fatalf("男生榜书籍数异常: %d", len(boys))
	}
	girls, err := c.RankPageBooks(100, "0")
	if err != nil {
		t.Fatalf("女生榜拉取失败: %v", err)
	}
	if len(girls) == 0 {
		t.Fatal("女生榜无数据")
	}
	if girls[0].BookID == boys[0].BookID {
		t.Logf("警告：男/女生榜第一本相同（%s），gender_list_type 可能未生效", girls[0].BookID)
	}
	t.Logf("完本榜男生 %d 本（首: %s），女生 %d 本（首: %s）",
		len(boys), boys[0].BookName, len(girls), girls[0].BookName)
}
