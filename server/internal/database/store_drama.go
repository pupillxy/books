package database

// 短剧观看记录：每用户每部剧一条，汇报进度即 upsert（updated_at 置为当前，列表按此倒序）

import (
	"database/sql"
	"errors"

	"xiaoshuo/internal/model"
)

// UpsertDramaProgress 记录/刷新某用户某部短剧的观看进度
func (s *DBStore) UpsertDramaProgress(userID int64, sid, title, cover string, totalEps, epIndex int) error {
	if epIndex < 1 {
		epIndex = 1
	}
	_, err := s.Exec(`
		INSERT INTO drama_history (user_id, sid, title, cover, total_eps, ep_index, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(user_id, sid) DO UPDATE SET
			title      = excluded.title,
			cover      = excluded.cover,
			total_eps  = excluded.total_eps,
			ep_index   = excluded.ep_index,
			updated_at = CURRENT_TIMESTAMP`,
		userID, sid, title, cover, totalEps, epIndex)
	return err
}

// GetDramaProgress 查某用户某部短剧的观看集数（无记录返回 ErrNotFound）
func (s *DBStore) GetDramaProgress(userID int64, sid string) (int, error) {
	var ep int
	err := s.QueryRow(`SELECT ep_index FROM drama_history WHERE user_id = ? AND sid = ?`, userID, sid).Scan(&ep)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, ErrNotFound
		}
		return 0, err
	}
	return ep, nil
}

// ListDramaHistory 某用户的观看记录，最近观看在前
func (s *DBStore) ListDramaHistory(userID int64, limit int) ([]*model.DramaHistoryItem, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.Query(`
		SELECT sid, title, cover, total_eps, ep_index, updated_at
		FROM drama_history WHERE user_id = ?
		ORDER BY updated_at DESC LIMIT ?`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*model.DramaHistoryItem
	for rows.Next() {
		it := &model.DramaHistoryItem{}
		if err := rows.Scan(&it.SID, &it.Title, &it.Cover, &it.TotalEps, &it.EpIndex, &it.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// DeleteDramaHistory 删除某用户某条观看记录
func (s *DBStore) DeleteDramaHistory(userID int64, sid string) error {
	_, err := s.Exec(`DELETE FROM drama_history WHERE user_id = ? AND sid = ?`, userID, sid)
	return err
}
