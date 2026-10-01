package handler

import (
	"log"
	"time"

	"xiaoshuo/internal/database"
)

// StartUpdater 每日追更：书库中绑定了番茄 ID 且未完结的书，
// 刷新在线目录元数据（新章节即出现在目录，正文由阅读时按需回源）。
// 发现完结即落库 finished 标记，退出追更名单；不再自动整本下载
// （离线缓存走用户显式下载）。
func StartUpdater(h *StoreHandler) {
	go func() {
		time.Sleep(2 * time.Minute) // 启动缓冲：等网络/TND 就绪，避开开机高峰
		for {
			h.updateOnce()
			time.Sleep(24 * time.Hour)
		}
	}()
}

func (h *StoreHandler) updateOnce() {
	books, err := h.DB.ListUnfinishedFanqieBooks()
	if err != nil {
		log.Printf("[追更] 查询未完结书失败: %v", err)
		return
	}
	if len(books) == 0 {
		return
	}
	log.Printf("[追更] 开始检查 %d 本未完结书", len(books))
	for _, b := range books {
		detail, err := h.getBookDetail(b.FanqieID)
		if err != nil {
			log.Printf("[追更] 获取详情失败 %s(%s): %v", b.Title, b.FanqieID, err)
			continue
		}
		// 残缺元数据修复：风控兜底期间导入的书可能缺封面/简介/作者
		if (b.Cover == "" || b.Intro == "") && (detail.Cover != "" || detail.Synopsis != "") {
			_ = h.DB.SetBookMeta(b.ID, detail.Title, detail.Author, detail.Cover, detail.Synopsis)
		}
		if detail.Finished {
			_ = h.DB.SetBookFinished(b.ID, true) // 已完结：落库后退出追更名单
		}
		chapters, err := h.getChapters(b.FanqieID)
		if err != nil {
			log.Printf("[追更] 获取目录失败 %s(%s): %v", b.Title, b.FanqieID, err)
			continue
		}
		if len(chapters) <= b.TotalChapters {
			continue // 无更新
		}
		metas := make([]database.OnlineChapterMeta, 0, len(chapters))
		for _, ch := range chapters {
			metas = append(metas, database.OnlineChapterMeta{Idx: ch.Index - 1, Title: ch.Title, SrcID: ch.ID})
		}
		if err := h.DB.ReplaceChapterMeta(b.ID, metas); err != nil {
			log.Printf("[追更] 目录写入失败 %s(%s): %v", b.Title, b.FanqieID, err)
			continue
		}
		log.Printf("[追更] %s(%s) 目录 %d → %d 章（正文按需回源）", b.Title, b.FanqieID, b.TotalChapters, len(chapters))
		time.Sleep(3 * time.Second) // 轻微限速，避免连续请求触发风控
	}
}
