package handler

import (
	"strings"
	"testing"
)

// 番茄网页格式正文样本（TND status.json / epub 内 chapter_NNN.xhtml 同构）
const sampleWebHTML = `{!--PGC_VOICE:{"type":"audio"}--}
  <h2 class="ejtop20  chapterTitle" idx="10000" p_idx="40000"><blk p_idx="10000" e_idx="0" e_order="0">第一章 测试</blk></h2>

  <p class="zw" idx="0" p_idx="40000"><blk p_idx="0" e_idx="0" e_order="1">林辉的瞳孔微微收缩。</blk></p>

  <p class="zw"><blk>眼前出现了一个只有他能看到的金色轮盘，&ldquo;转起来&rdquo;——&amp;更多&gt;符号。</blk></p>`

func TestStripHTML(t *testing.T) {
	got := stripHTML(sampleWebHTML)
	if strings.Contains(got, "<") || strings.Contains(got, "PGC_VOICE") {
		t.Fatalf("仍残留标签/语音标记:\n%s", got)
	}
	for _, want := range []string{"第一章 测试", "林辉的瞳孔微微收缩。", "眼前出现了一个只有他能看到的金色轮盘，“转起来”——&更多>符号。"} {
		if !strings.Contains(got, want) {
			t.Fatalf("缺少预期文本 %q:\n%s", want, got)
		}
	}
	if strings.Count(got, "\n林辉") != 1 {
		t.Fatalf("块级标签应转换行:\n%q", got)
	}
}

func TestStripHTMLPlain(t *testing.T) {
	// 纯文本应原样通过（unidbg 通道的明文不走这里，但函数需健壮）
	in := "第一行\n\n第二行"
	if got := stripHTML(in); got != in {
		t.Fatalf("纯文本被改动: %q", got)
	}
}
