package scanner

import (
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

// 章节标题：第X章/节/卷/回/集/篇、序章、楔子、终章、尾声、番外
var chapterRe = regexp.MustCompile(
	`^\s*(?:` +
		`第\s*[0-9零〇一二三四五六七八九十百千万两]+\s*[章节卷回集部篇][^\n]{0,60}` +
		`|序章[^\n]{0,40}|楔子[^\n]{0,40}|前言[^\n]{0,40}|终章[^\n]{0,40}|尾声[^\n]{0,40}` +
		`|番外[^\n]{0,40}` +
		`)\s*$`)

var (
	reTitle              = regexp.MustCompile(`(?m)^\s*书\s*名\s*[:：]\s*(.+)$`)
	reAuthor             = regexp.MustCompile(`(?m)^\s*作\s*者\s*[:：]\s*(.+)$`)
	reIntro              = regexp.MustCompile(`(?m)^\s*简\s*介\s*[:：]\s*(.+)$`)
	reBookNameInGuillemet = regexp.MustCompile(`《([^》]+)》`)
	reAuthorInName       = regexp.MustCompile(`(?:作者|author)\s*[:：]\s*([^\n]+)$`)
)

type ParsedChapter struct {
	Title   string
	Content string
}

// decodeText: BOM → UTF-8 校验 → GBK 兜底
func decodeText(raw []byte) (string, error) {
	if len(raw) >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF {
		return string(raw[3:]), nil
	}
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		return utf16DecodeLE(raw[2:]), nil
	}
	if utf8.Valid(raw) {
		return string(raw), nil
	}
	out, err := simplifiedchinese.GBK.NewDecoder().Bytes(raw)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func utf16DecodeLE(b []byte) string {
	u := make([]uint16, 0, len(b)/2)
	for i := 0; i+1 < len(b); i += 2 {
		u = append(u, uint16(b[i])|uint16(b[i+1])<<8)
	}
	runes := make([]rune, 0, len(u))
	for i := 0; i < len(u); i++ {
		r := rune(u[i])
		if r >= 0xD800 && r <= 0xDBFF && i+1 < len(u) {
			lo := rune(u[i+1])
			if lo >= 0xDC00 && lo <= 0xDFFF {
				runes = append(runes, ((r-0xD800)<<10|(lo-0xDC00))+0x10000)
				i++
				continue
			}
		}
		runes = append(runes, r)
	}
	return string(runes)
}

// extractMeta 从文件头部和文件名提取书名/作者/简介
func extractMeta(text, fileName string) (title, author, intro string) {
	head := text
	if i := strings.Index(text, "\n\n"); i > 0 && i < 2000 {
		head = text[:i]
	}
	if m := reTitle.FindStringSubmatch(head); m != nil {
		title = strings.TrimSpace(m[1])
	}
	if m := reAuthor.FindStringSubmatch(head); m != nil {
		author = strings.TrimSpace(m[1])
	}
	if m := reIntro.FindStringSubmatch(head); m != nil {
		intro = strings.TrimSpace(m[1])
	}
	base := strings.TrimSuffix(fileName, filepathExt(fileName))
	if title == "" {
		if m := reBookNameInGuillemet.FindStringSubmatch(fileName); m != nil {
			title = m[1]
		} else {
			title = base
		}
	}
	if author == "" {
		if m := reAuthorInName.FindStringSubmatch(base); m != nil {
			author = strings.TrimSpace(m[1])
		}
	}
	title = strings.TrimSpace(strings.Trim(title, "《》"))
	return
}

func filepathExt(name string) string {
	for i := len(name) - 1; i >= 0; i-- {
		if name[i] == '.' {
			return name[i:]
		}
	}
	return ""
}

// SplitChapters 按章节标题行拆分；无标题则整本单章
func SplitChapters(text string) []ParsedChapter {
	lines := strings.Split(text, "\n")

	type marker struct{ idx int; title string }
	var markers []marker
	for i, line := range lines {
		t := strings.Trim(line, "\r\u3000 ")
		if chapterRe.MatchString(t) {
			markers = append(markers, marker{idx: i, title: t})
		}
	}

	if len(markers) == 0 {
		content := strings.TrimSpace(text)
		if content == "" {
			return nil
		}
		return []ParsedChapter{{Title: "全文", Content: content}}
	}

	var out []ParsedChapter
	for mi, m := range markers {
		end := len(lines)
		if mi+1 < len(markers) {
			end = markers[mi+1].idx
		}
		content := strings.Trim(strings.Join(lines[m.idx+1:end], "\n"), "\n\r \u3000")
		out = append(out, ParsedChapter{Title: m.title, Content: content})
	}
	return out
}

var _ = fmt.Sprintf
