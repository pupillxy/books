package unidbg

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 用 10/05 抓包留档的 new_category 响应样本做离线解析回归（不碰上游）
func TestCategoryFrontParse(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "_probe", "resp_front_male.json"))
	if err != nil {
		t.Skipf("样本不存在，跳过: %v", err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(raw)
	}))
	defer srv.Close()

	c := New(srv.URL)
	out, err := c.CategoryFront(1)
	if err != nil {
		t.Fatalf("CategoryFront: %v", err)
	}
	if out.Tab != 1 || out.Name != "男生" {
		t.Fatalf("tab/name = %d/%s", out.Tab, out.Name)
	}
	if len(out.Tabs) != 6 {
		t.Fatalf("tabs = %d, want 6", len(out.Tabs))
	}
	if out.Tabs[0].Name != "男生" || out.Tabs[0].ID != 1 {
		t.Fatalf("tabs[0] = %+v", out.Tabs[0])
	}
	var hot *CategoryGroup
	for i := range out.Groups {
		if out.Groups[i].Name == "热门标签" {
			hot = &out.Groups[i]
		}
	}
	if hot == nil {
		t.Fatalf("没有热门标签分组: %+v", out.Groups)
	}
	if len(hot.Tags) == 0 || hot.Tags[0].Name != "玄幻" || hot.Tags[0].ID != 7 {
		t.Fatalf("热门标签首项异常: %+v", hot.Tags)
	}
}

func TestCategoryLandingParse(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "_probe", "resp_landing_filtered.json"))
	if err != nil {
		t.Skipf("样本不存在，跳过: %v", err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 校验我们代发的 query 与官方协议一致
		var req struct {
			Path  string `json:"path"`
			Query string `json:"query"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		if !strings.Contains(req.Path, "new_category/landing") {
			t.Errorf("path = %s", req.Path)
		}
		for _, want := range []string{"category_id=7", "query_gender=1", "selected_items=word_num_gte200%2Ccreation_status_end%2Csort_score", "limit=20", "page_version=2"} {
			if !strings.Contains(req.Query, want) {
				t.Errorf("query 缺少 %s: %s", want, req.Query)
			}
		}
		w.Write(raw)
	}))
	defer srv.Close()

	c := New(srv.URL)
	page, err := c.CategoryLanding("7", "1", "word_num_gte200,creation_status_end,sort_score", 0)
	if err != nil {
		t.Fatalf("CategoryLanding: %v", err)
	}
	if len(page.Books) != 20 {
		t.Fatalf("books = %d, want 20", len(page.Books))
	}
	if !page.More {
		t.Fatal("has_more 应为 true")
	}
	if page.Next != 20 {
		t.Fatalf("next = %d, want 20", page.Next)
	}
	for _, b := range page.Books {
		if !b.Finished {
			t.Fatalf("完结筛选下出现未完结标记: %s creation_status", b.BookName)
		}
		if b.ReadCount == "" || !strings.HasSuffix(b.ReadCount, "在读") {
			t.Fatalf("read_count 未格式化: %s -> %q", b.BookName, b.ReadCount)
		}
	}
	if page.Banner == "" {
		t.Fatal("banner 为空")
	}
	if len(page.Related) == 0 || !strings.HasPrefix(page.Related[0].Name, "") {
		t.Logf("related = %+v", page.Related)
	}
}

func TestFormatLandingReadCount(t *testing.T) {
	cases := map[string]string{
		"1167785": "116.8万人在读",
		"999":     "999人在读",
		"10000":   "1万人在读",
		"0":       "",
		"":        "",
		"abc":     "",
	}
	for in, want := range cases {
		if got := formatLandingReadCount(in); got != want {
			t.Errorf("formatLandingReadCount(%q) = %q, want %q", in, got, want)
		}
	}
}
