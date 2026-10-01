package hongguo

import "testing"

// App 取流每档清晰度带 main/backup 多地址，规范化后同档只留一条，且按清晰度降序。
func TestNormalizeMedia(t *testing.T) {
	media := []Media{
		{Name: "720p", Quality: 720},
		{Name: "1080p", Quality: 1080}, // 1080 的 backup 线路（先出现的 h264）
		{Name: "540p", Quality: 540},
		{Name: "1080p", Quality: 1080}, // 1080 的 main 线路
		{Name: "720p", Quality: 720},
	}
	out := normalizeMedia(media)
	if len(out) != 3 {
		t.Fatalf("期望去重后 3 条，实际 %d：%+v", len(out), out)
	}
	for i, want := range []int{1080, 720, 540} {
		if out[i].Quality != want {
			t.Fatalf("第 %d 条期望 %dp，实际 %+v", i, want, out[i])
		}
	}
}
