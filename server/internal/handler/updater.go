package handler

import (
	"log"
	"time"
)

// StartUpdater 每日追更：书库中绑定了番茄 ID 且未完结的书，
// 对比在线目录章节数，有新增就重新触发 TND 整本下载
// （TND 增量补章后文件 mtime 变化，scanner 自动重扫覆盖入库）。
// 完结书只下载一次；发现完结即落库 finished 标记，退出追更名单。
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
	if !h.TND.Enabled() && !h.UNI.Enabled() {
		return // 未配置下载服务时静默跳过
	}
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
		// 已有进行中的下载任务（上次触发的还没扫完）就不再叠加
		if task, err := h.DB.GetDownloadTask(b.FanqieID); err == nil &&
			(task.Status == "pending" || task.Status == "running") {
			continue
		}
		chapters, err := h.FQ.GetChapters(b.FanqieID)
		if err != nil {
			log.Printf("[追更] 获取目录失败 %s(%s): %v", b.Title, b.FanqieID, err)
			continue
		}
		if len(chapters) <= b.TotalChapters {
			continue // 无更新
		}
		status := h.triggerDownload(b.FanqieID, b.Title, b.ID)
		log.Printf("[追更] %s(%s) %d → %d 章, 任务: %s", b.Title, b.FanqieID, b.TotalChapters, len(chapters), status)
		time.Sleep(3 * time.Second) // 轻微限速，避免连续请求触发风控
	}
}
