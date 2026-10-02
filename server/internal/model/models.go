package model

type User struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"`
	Nickname     string `json:"nickname"`
	IsAdmin      bool   `json:"is_admin"`
	CreatedAt    string `json:"created_at"`
}

type Book struct {
	ID            int64  `json:"id"`
	Title         string `json:"title"`
	Author        string `json:"author"`
	Intro         string `json:"intro"`
	Cover         string `json:"cover"`
	FanqieID      string `json:"fanqie_id"`
	Source        string `json:"source"`  // local=TXT导入 fanqie=在线书
	Status        string `json:"status"`  // ready=本地全文 online=仅在线免费章 downloading=TND下载中
	Finished      bool   `json:"finished"` // 番茄完结标记（完结书不参与每日追更）
	FilePath      string `json:"-"`
	FileSize      int64  `json:"-"`
	FileMtime     int64  `json:"-"`
	TotalChapters int    `json:"total_chapters"`
	CreatedAt     string `json:"created_at"`
}

type ChapterMeta struct {
	Idx   int    `json:"idx"`
	Title string `json:"title"`
}

type Chapter struct {
	Idx     int    `json:"idx"`
	Title   string `json:"title"`
	Content string `json:"content"`
	SrcID   string `json:"src_id,omitempty"` // 番茄在线章节 item_id（TND/在线导入时保留）
}

// DownloadTask TND 下载任务
type DownloadTask struct {
	ID        int64  `json:"id"`
	FanqieID  string `json:"fanqie_id"`
	Title     string `json:"title"`
	Status    string `json:"status"` // pending/running/done/failed
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

// DramaHistoryItem 短剧观看记录（每用户每部剧一条，更新即置顶）
type DramaHistoryItem struct {
	SID       string `json:"sid"`
	Title     string `json:"title"`
	Cover     string `json:"cover"`
	TotalEps  int    `json:"total_eps"`
	EpIndex   int    `json:"ep_index"` // 看到的集（1-based）
	UpdatedAt string `json:"updated_at"`
}
