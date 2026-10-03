package unidbg

import (
	"encoding/json"
	"os"
	"testing"
)

// TestParseComicFeedSample 用 10/04 抓包回放的真实漫画 feed 响应验证解析
// （book_data 直接挂在 cell_view 上——与小说频道的 cell_data 嵌套形状不同）
func TestParseComicFeedSample(t *testing.T) {
	raw, err := os.ReadFile(`D:\dev\xiaoshuo\_reference\fqemu\capture_xiaoshuo_1004\resp_comic_feed.json`)
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
	cards := parseComicCards(env.Data)
	if len(cards) < 10 {
		t.Fatalf("漫画卡解析数异常: %d", len(cards))
	}
	if cards[0].BookID == "" || cards[0].ThumbURL == "" {
		t.Fatalf("漫画卡关键字段缺失: %+v", cards[0])
	}
	t.Logf("解析出 %d 张漫画卡, 首张: %s (%s话, %s)", len(cards), cards[0].BookName, cards[0].SerialCount, cards[0].ReadCntText)
}

// TestParseCellFeedShapes 两种 cell 形状都要能解析：
// A) book_data 挂在 cell_view 本身（漫画频道实测）；B) 嵌套在 cell_data 子树（小说/榜单实测）
func TestParseCellFeedShapes(t *testing.T) {
	shapeA := `{"cell_view":{"cell_id":"1","book_data":[
		{"book_id":"11","book_name":"甲","creation_status":"0"},
		{"book_id":"12","book_name":"乙","creation_status":"1"}]}}`
	shapeB := `{"cell_view":{"cell_data":[
		{"cell_name":"x","book_data":[{"book_id":"21","book_name":"丙","creation_status":"0"}]},
		{"cell_data":[{"book_data":[{"book_id":"22","book_name":"丁","creation_status":"1"}]}]}]}}`

	booksA, err := parseCellViewBooks(json.RawMessage(shapeA))
	if err != nil || len(booksA) != 2 || booksA[0].BookName != "甲" || booksA[1].BookName != "乙" {
		t.Fatalf("形状A解析失败: %v %+v", err, booksA)
	}
	// 书城卡 creation_status：0=完结 1=连载（10/04 定案）
	if !booksA[0].Finished || booksA[1].Finished {
		t.Fatalf("creation_status 语义错误: %+v", booksA)
	}
	booksB, err := parseCellViewBooks(json.RawMessage(shapeB))
	if err != nil || len(booksB) != 2 {
		t.Fatalf("形状B解析失败: %v %+v", err, booksB)
	}
}

// TestExtractComicImages 整话图片列表的宽容解析（uri/url 皆可，取最长列表保序）
func TestExtractComicImages(t *testing.T) {
	body := `{"data":{"chapterName":"第1话","pictures":[
		{"uri":"https://cdn.example/p1.jpg","width":800,"height":1200},
		{"uri":"https://cdn.example/p2.jpg","width":800,"height":1200},
		{"uri":"https://cdn.example/p3.jpg","width":800,"height":1200}],
		"comment_list":[{"url":"https://cdn.example/avatar.jpg"}]}}`
	imgs := extractComicImages(json.RawMessage(body))
	if len(imgs) != 3 || imgs[0].URL != "https://cdn.example/p1.jpg" || imgs[2].Width != 800 {
		t.Fatalf("图片解析异常: %+v", imgs)
	}

	// url 键名变体 + 嵌套层级
	body2 := `{"data":{"content_list":{"image_list":[
		{"url":"https://cdn.example/a.webp"},{"url":"https://cdn.example/b.webp"}]}}}`
	imgs2 := extractComicImages(json.RawMessage(body2))
	if len(imgs2) != 2 || imgs2[1].URL != "https://cdn.example/b.webp" {
		t.Fatalf("嵌套图片解析异常: %+v", imgs2)
	}

	// 无图片字段 → 空
	if got := extractComicImages(json.RawMessage(`{"data":{"content":"xx"}}`)); len(got) != 0 {
		t.Fatalf("应解析为空: %+v", got)
	}
}

// TestEncryptedContentBlob 密文字段识别
func TestEncryptedContentBlob(t *testing.T) {
	enc := make([]byte, 200)
	for i := range enc {
		enc[i] = 'A'
	}
	ok := `{"content":"` + string(enc) + `"}`
	if encryptedContentBlob(json.RawMessage(ok)) == "" {
		t.Fatal("密文应被识别")
	}
	if encryptedContentBlob(json.RawMessage(`{"content":"short"}`)) != "" {
		t.Fatal("短内容不应视为密文")
	}
	if encryptedContentBlob(json.RawMessage(`{"content":"https://x.com/aAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}`)) != "" {
		t.Fatal("含 http 的内容不应视为密文")
	}
}
