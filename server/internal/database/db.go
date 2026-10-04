package database

import (
	"database/sql"
	"strings"

	_ "modernc.org/sqlite"
)

func Open(path string) (*sql.DB, error) {
	dsn := path + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// SQLite 单写者，串行化即可
	db.SetMaxOpenConns(1)
	if err := migrate(db); err != nil {
		return nil, err
	}
	return db, nil
}

func migrate(db *sql.DB) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id            INTEGER PRIMARY KEY AUTOINCREMENT,
			username      TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			nickname      TEXT NOT NULL DEFAULT '',
			is_admin      INTEGER NOT NULL DEFAULT 0,
			created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS books (
			id             INTEGER PRIMARY KEY AUTOINCREMENT,
			title          TEXT NOT NULL,
			author         TEXT NOT NULL DEFAULT '',
			intro          TEXT NOT NULL DEFAULT '',
			cover          TEXT NOT NULL DEFAULT '',
			fanqie_id      TEXT NOT NULL DEFAULT '',
			file_path      TEXT NOT NULL UNIQUE,
			file_size      INTEGER NOT NULL DEFAULT 0,
			file_mtime     INTEGER NOT NULL DEFAULT 0,
			total_chapters INTEGER NOT NULL DEFAULT 0,
			finished       INTEGER NOT NULL DEFAULT 0,
			created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE INDEX IF NOT EXISTS idx_books_title ON books(title)`,
		`CREATE TABLE IF NOT EXISTS chapters (
			id      INTEGER PRIMARY KEY AUTOINCREMENT,
			book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
			idx     INTEGER NOT NULL,
			title   TEXT NOT NULL,
			content TEXT NOT NULL,
			UNIQUE(book_id, idx)
		)`,
		`CREATE TABLE IF NOT EXISTS shelf (
			user_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			book_id  INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
			added_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(user_id, book_id)
		)`,
		`CREATE TABLE IF NOT EXISTS reading_progress (
			user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			book_id     INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
			chapter_idx INTEGER NOT NULL DEFAULT 0,
			updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(user_id, book_id)
		)`,
		`CREATE TABLE IF NOT EXISTS drama_history (
			user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
			sid        TEXT NOT NULL,
			title      TEXT NOT NULL DEFAULT '',
			cover      TEXT NOT NULL DEFAULT '',
			total_eps  INTEGER NOT NULL DEFAULT 0,
			ep_index   INTEGER NOT NULL DEFAULT 1,
			updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(user_id, sid)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_drama_history ON drama_history(user_id, updated_at)`,
		`CREATE TABLE IF NOT EXISTS download_tasks (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			fanqie_id  TEXT NOT NULL UNIQUE,
			title      TEXT NOT NULL DEFAULT '',
			status     TEXT NOT NULL DEFAULT 'pending',
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		// 猜你喜欢瀑布流的持久缓存（last-known-good）：上游个性化会话冷启动会返回
		// 软空页，有兜底缓存后初始加载直接回放、上游失败也回退陈旧值，App 端不再报错
		`CREATE TABLE IF NOT EXISTS feed_cache (
			key         TEXT PRIMARY KEY,
			items       TEXT NOT NULL,
			next_offset INTEGER NOT NULL DEFAULT 0,
			has_more    INTEGER NOT NULL DEFAULT 0,
			updated_at  INTEGER NOT NULL DEFAULT 0
		)`,

		// 旧库补列（chapters.src_id 存番茄在线章节 ID，用于按需拉正文回填）
		`ALTER TABLE books ADD COLUMN source TEXT NOT NULL DEFAULT 'local'`,
		`ALTER TABLE books ADD COLUMN status TEXT NOT NULL DEFAULT 'ready'`,
		`ALTER TABLE books ADD COLUMN finished INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE chapters ADD COLUMN src_id TEXT NOT NULL DEFAULT ''`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			// ALTER TABLE 对已含该列的库会报错，属预期，忽略
			if strings.Contains(err.Error(), "duplicate column name") {
				continue
			}
			return err
		}
	}
	return nil
}
