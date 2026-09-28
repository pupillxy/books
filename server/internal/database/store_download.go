package database

import (
	"xiaoshuo/internal/model"
)

// ---------- TND 下载任务 ----------

func (s *DBStore) UpsertDownloadTask(fanqieID, title, status string) error {
	_, err := s.Exec(`INSERT INTO download_tasks (fanqie_id, title, status) VALUES (?, ?, ?)
		ON CONFLICT(fanqie_id) DO UPDATE SET title=excluded.title,
			status = CASE WHEN excluded.status='pending' THEN download_tasks.status ELSE excluded.status END,
			updated_at = CURRENT_TIMESTAMP`,
		fanqieID, title, status)
	return err
}

func (s *DBStore) GetDownloadTask(fanqieID string) (*model.DownloadTask, error) {
	t := &model.DownloadTask{}
	err := s.QueryRow(`SELECT id, fanqie_id, title, status, created_at, updated_at FROM download_tasks WHERE fanqie_id = ?`, fanqieID).
		Scan(&t.ID, &t.FanqieID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return t, nil
}

func (s *DBStore) ListDownloadTasks() ([]*model.DownloadTask, error) {
	rows, err := s.Query(`SELECT id, fanqie_id, title, status, created_at, updated_at FROM download_tasks ORDER BY id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*model.DownloadTask
	for rows.Next() {
		t := &model.DownloadTask{}
		if err := rows.Scan(&t.ID, &t.FanqieID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// HasActiveDownloadTasks 是否有未完成任务（驱动轮询扫描）
func (s *DBStore) HasActiveDownloadTasks() (bool, error) {
	var n int
	err := s.QueryRow(`SELECT COUNT(*) FROM download_tasks WHERE status IN ('pending','running')`).Scan(&n)
	return n > 0, err
}

// MatchRunningTaskByTitle 按书名匹配未完成任务（scanner 导入新 TXT 时调用）
func (s *DBStore) MatchRunningTaskByTitle(title string) (*model.DownloadTask, error) {
	t := &model.DownloadTask{}
	err := s.QueryRow(`SELECT id, fanqie_id, title, status, created_at, updated_at
		FROM download_tasks WHERE status IN ('pending','running') AND title = ?`, title).
		Scan(&t.ID, &t.FanqieID, &t.Title, &t.Status, &t.CreatedAt, &t.UpdatedAt)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return t, nil
}

func (s *DBStore) SetDownloadTaskStatus(fanqieID, status string) error {
	_, err := s.Exec(`UPDATE download_tasks SET status=?, updated_at=CURRENT_TIMESTAMP WHERE fanqie_id=?`, status, fanqieID)
	return err
}
