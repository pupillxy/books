package database

import (
	"encoding/json"
	"time"
)

// 猜你喜欢瀑布流持久缓存（last-known-good）。
// 上游 cell/change 是个性化会话端点，冷启动/突发连打会返回软空页（10/04 档案）；
// 内存正/负缓存只扛瞬时，这里落库让「初始加载回放缓存、上游失败回退陈旧值」
// 在进程重启/重新部署后依然成立。

// FeedCacheEntry feed_cache 行
type FeedCacheEntry struct {
	Items      json.RawMessage // 书卡数组的 JSON
	NextOffset int
	HasMore    bool
	UpdatedAt  time.Time
}

// GetFeedCache 读缓存条目，无则返回 nil
func (d *DBStore) GetFeedCache(key string) *FeedCacheEntry {
	var items string
	var next, hasMore, updatedAt int64
	err := d.QueryRow(`SELECT items, next_offset, has_more, updated_at FROM feed_cache WHERE key = ?`, key).
		Scan(&items, &next, &hasMore, &updatedAt)
	if err != nil {
		return nil
	}
	return &FeedCacheEntry{
		Items:      json.RawMessage(items),
		NextOffset: int(next),
		HasMore:    hasMore == 1,
		UpdatedAt:  time.Unix(updatedAt, 0),
	}
}

// PutFeedCache 写入（UPSERT）并清理 48h 未更新的旧条目
func (d *DBStore) PutFeedCache(key string, itemsJSON string, nextOffset int, hasMore bool) {
	_, err := d.Exec(`INSERT INTO feed_cache (key, items, next_offset, has_more, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET items = excluded.items, next_offset = excluded.next_offset,
			has_more = excluded.has_more, updated_at = excluded.updated_at`,
		key, itemsJSON, nextOffset, boolToInt(hasMore), time.Now().Unix())
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-48 * time.Hour).Unix()
	d.Exec(`DELETE FROM feed_cache WHERE updated_at < ?`, cutoff)
}
