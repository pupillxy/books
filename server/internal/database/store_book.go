package database

import (
	"database/sql"

	"xiaoshuo/internal/model"
)

// ---------- 书库 ----------

const bookCols = `id, title, author, intro, cover, fanqie_id, source, status, file_path, file_size, file_mtime, total_chapters, finished, created_at`

func (s *DBStore) GetBookByPath(path string) (*model.Book, error) {
	return scanBook(s.QueryRow(
		`SELECT `+bookCols+` FROM books WHERE file_path = ?`, path))
}

func (s *DBStore) GetBookByID(id int64) (*model.Book, error) {
	return scanBook(s.QueryRow(
		`SELECT `+bookCols+` FROM books WHERE id = ?`, id))
}

// GetBookByFanqieID 按番茄书籍 ID 查本地入库的书
func (s *DBStore) GetBookByFanqieID(fid string) (*model.Book, error) {
	return scanBook(s.QueryRow(
		`SELECT `+bookCols+` FROM books WHERE fanqie_id = ?`, fid))
}

// GetComicByFanqieID 按番茄漫画 ID 查入库的漫画行（与小说按 source 隔离）
func (s *DBStore) GetComicByFanqieID(fid string) (*model.Book, error) {
	return scanBook(s.QueryRow(
		`SELECT `+bookCols+` FROM books WHERE fanqie_id = ? AND source = 'comic'`, fid))
}

func (s *DBStore) ListBooks(keyword string, offset, limit int) ([]*model.Book, int, error) {
	// 书库只列有本地内容的书（漫画仅元数据入库，进了会跳到错误的文字阅读器）
	where := `WHERE source != 'comic'`
	args := []any{}
	if keyword != "" {
		where += ` AND (title LIKE ? OR author LIKE ?)`
		kw := "%" + keyword + "%"
		args = append(args, kw, kw)
	}
	var total int
	if err := s.QueryRow(`SELECT COUNT(*) FROM books `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	q := `SELECT ` + bookCols + ` FROM books ` + where + ` ORDER BY title LIMIT ? OFFSET ?`
	rows, err := s.Query(q, append(args, limit, offset)...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []*model.Book
	for rows.Next() {
		b, err := scanBookRows(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, b)
	}
	return out, total, rows.Err()
}

// UpsertBook 本地文件导入（TXT: source=local；TND jsonl 传入 source/status）
func (s *DBStore) UpsertBook(b *model.Book) (int64, error) {
	source, status := b.Source, b.Status
	if source == "" {
		source = "local"
	}
	if status == "" {
		status = "ready"
	}
	existing, err := s.GetBookByPath(b.FilePath)
	if err == nil {
		_, err = s.Exec(`DELETE FROM chapters WHERE book_id = ?`, existing.ID)
		if err != nil {
			return 0, err
		}
		_, err = s.Exec(`UPDATE books SET title=?, author=?, intro=?, cover=?, fanqie_id=?, source=?, status=?, file_size=?, file_mtime=?, total_chapters=? WHERE id=?`,
			b.Title, b.Author, b.Intro, b.Cover, b.FanqieID, source, status, b.FileSize, b.FileMtime, b.TotalChapters, existing.ID)
		return existing.ID, err
	}
	if err != ErrNotFound {
		return 0, err
	}
	res, err := s.Exec(`INSERT INTO books (title, author, intro, cover, fanqie_id, source, status, file_path, file_size, file_mtime, total_chapters)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		b.Title, b.Author, b.Intro, b.Cover, b.FanqieID, source, status, b.FilePath, b.FileSize, b.FileMtime, b.TotalChapters)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// UpsertOnlineBook 在线书入库（无本地文件，file_path 用合成占位满足 UNIQUE；目录 meta 另行写入）
func (s *DBStore) UpsertOnlineBook(b *model.Book) (int64, error) {
	existing, err := s.GetBookByFanqieID(b.FanqieID)
	if err == nil {
		_, err = s.Exec(`UPDATE books SET title=?, author=?, intro=?, cover=?, total_chapters=?, status=?, finished=? WHERE id=?`,
			b.Title, b.Author, b.Intro, b.Cover, b.TotalChapters, b.Status, b.Finished, existing.ID)
		return existing.ID, err
	}
	if err != ErrNotFound {
		return 0, err
	}
	res, err := s.Exec(`INSERT INTO books (title, author, intro, cover, fanqie_id, source, status, file_path, total_chapters, finished)
		VALUES (?, ?, ?, ?, ?, 'fanqie', ?, ?, ?, ?)`,
		b.Title, b.Author, b.Intro, b.Cover, b.FanqieID, b.Status, "fanqie:"+b.FanqieID, b.TotalChapters, b.Finished)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// UpsertComicBook 漫画轻量入库：只有元数据，无本地文件、无章节正文（阅读走 unidbg
// 实时代理）；入库后即可复用通用书架/阅读进度链路，source=comic 与小说隔离
func (s *DBStore) UpsertComicBook(b *model.Book) (int64, error) {
	existing, err := s.GetComicByFanqieID(b.FanqieID)
	if err == nil {
		_, err = s.Exec(`UPDATE books SET title=?, author=?, intro=?, cover=?, total_chapters=?, finished=? WHERE id=?`,
			b.Title, b.Author, b.Intro, b.Cover, b.TotalChapters, b.Finished, existing.ID)
		return existing.ID, err
	}
	if err != ErrNotFound {
		return 0, err
	}
	res, err := s.Exec(`INSERT INTO books (title, author, intro, cover, fanqie_id, source, status, file_path, total_chapters, finished)
		VALUES (?, ?, ?, ?, ?, 'comic', 'online', ?, ?, ?)`,
		b.Title, b.Author, b.Intro, b.Cover, b.FanqieID, "comic:"+b.FanqieID, b.TotalChapters, b.Finished)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// SetBookStatus 更新书籍状态（downloading→ready 等）
func (s *DBStore) SetBookStatus(bookID int64, status string) error {
	_, err := s.Exec(`UPDATE books SET status=? WHERE id=?`, status, bookID)
	return err
}

// SetBookFinished 落库完结标记（追更发现完结后不再每日查询该书）
func (s *DBStore) SetBookFinished(bookID int64, finished bool) error {
	_, err := s.Exec(`UPDATE books SET finished=? WHERE id=?`, finished, bookID)
	return err
}

// SetBookMeta 补全书籍元数据（风控兜底期间导入的书在追更时修复封面/简介/作者）
func (s *DBStore) SetBookMeta(bookID int64, title, author, cover, intro string) error {
	_, err := s.Exec(`UPDATE books SET title=?, author=?, cover=?, intro=? WHERE id=?`,
		title, author, cover, intro, bookID)
	return err
}

// ListUnfinishedFanqieBooks 追更对象：绑定了番茄 ID 且未完结的书（不含漫画）
func (s *DBStore) ListUnfinishedFanqieBooks() ([]*model.Book, error) {
	rows, err := s.Query(`SELECT ` + bookCols + ` FROM books WHERE fanqie_id != '' AND source != 'comic' AND finished = 0`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*model.Book
	for rows.Next() {
		b, err := scanBookRows(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// MergeOnlineIntoLocal TND 下载完成、scanner 导入本地 TXT 后调用：
// 把在线行的书架/进度迁移到本地行，删除在线行，并把番茄 ID 补到本地行。
func (s *DBStore) MergeOnlineIntoLocal(fanqieID string, localID int64) error {
	online, err := s.GetBookByFanqieID(fanqieID)
	if err != nil {
		return err // 不存在视为已合并
	}
	if online.ID == localID {
		return nil // 本地行本身就是在线行升级而来
	}
	tx, err := s.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// 迁书架（冲突时保留已有的本地行书架记录）
	if _, err := tx.Exec(`INSERT OR IGNORE INTO shelf (user_id, book_id, added_at)
		SELECT user_id, ?, added_at FROM shelf WHERE book_id=?`, localID, online.ID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM shelf WHERE book_id=?`, online.ID); err != nil {
		return err
	}
	// 迁阅读进度
	if _, err := tx.Exec(`INSERT OR IGNORE INTO reading_progress (user_id, book_id, chapter_idx, updated_at)
		SELECT user_id, ?, chapter_idx, updated_at FROM reading_progress WHERE book_id=?`, localID, online.ID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM reading_progress WHERE book_id=?`, online.ID); err != nil {
		return err
	}
	// 本地行补番茄 ID（保留番茄 ID 以便后续"回到在线源"等扩展）
	if _, err := tx.Exec(`UPDATE books SET fanqie_id=? WHERE id=? AND (fanqie_id='' OR fanqie_id IS NULL)`, fanqieID, localID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM books WHERE id=?`, online.ID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *DBStore) DeleteBook(id int64) error {
	_, err := s.Exec(`DELETE FROM books WHERE id = ?`, id)
	return err
}

// ---------- 章节 ----------

func (s *DBStore) InsertChapter(bookID int64, idx int, title, content string) error {
	_, err := s.Exec(`INSERT INTO chapters (book_id, idx, title, content) VALUES (?, ?, ?, ?)`, bookID, idx, title, content)
	return err
}

// OnlineChapterMeta 在线书章节元数据（content 置空，按需在线拉取回填）
type OnlineChapterMeta struct {
	Idx   int
	Title string
	SrcID string // 番茄章节 item_id
}

// ReplaceChapterMeta 整体替换章节元数据（在线书目录），单事务
func (s *DBStore) ReplaceChapterMeta(bookID int64, metas []OnlineChapterMeta) error {
	tx, err := s.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM chapters WHERE book_id = ?`, bookID); err != nil {
		return err
	}
	stmt, err := tx.Prepare(`INSERT INTO chapters (book_id, idx, title, content, src_id) VALUES (?, ?, ?, '', ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, m := range metas {
		if _, err := stmt.Exec(bookID, m.Idx, m.Title, m.SrcID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ReplaceChapters 整体替换书章节（TND 全本/增量导入），单事务
func (s *DBStore) ReplaceChapters(bookID int64, chapters []model.Chapter) error {
	tx, err := s.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM chapters WHERE book_id = ?`, bookID); err != nil {
		return err
	}
	stmt, err := tx.Prepare(`INSERT INTO chapters (book_id, idx, title, content, src_id) VALUES (?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, ch := range chapters {
		if _, err := stmt.Exec(bookID, ch.Idx, ch.Title, ch.Content, ch.SrcID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// UpsertChapterContent 按 idx 回填/插入章节内容（TND 增量导入，保留在线兜底 meta）
func (s *DBStore) UpsertChapterContent(bookID int64, idx int, title, content string) error {
	_, err := s.Exec(`INSERT INTO chapters (book_id, idx, title, content) VALUES (?, ?, ?, ?)
		ON CONFLICT(book_id, idx) DO UPDATE SET title=excluded.title, content=excluded.content`,
		bookID, idx, title, content)
	return err
}

// UpsertChapterContentSrc 按 idx 回填/插入章节内容（可带 src_id；冲突时保留原 src_id）
func (s *DBStore) UpsertChapterContentSrc(bookID int64, idx int, title, content, srcID string) error {
	_, err := s.Exec(`INSERT INTO chapters (book_id, idx, title, content, src_id) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(book_id, idx) DO UPDATE SET title=excluded.title, content=excluded.content`,
		bookID, idx, title, content, srcID)
	return err
}

// FillChapterContent 在线拉取的正文回填缓存
func (s *DBStore) FillChapterContent(bookID int64, idx int, content string) error {
	_, err := s.Exec(`UPDATE chapters SET content = ? WHERE book_id = ? AND idx = ?`, content, bookID, idx)
	return err
}

// GetChapterSrcID 取章节对应的番茄在线章节 ID
func (s *DBStore) GetChapterSrcID(bookID int64, idx int) (string, error) {
	var srcID string
	err := s.QueryRow(`SELECT src_id FROM chapters WHERE book_id = ? AND idx = ?`, bookID, idx).Scan(&srcID)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return "", ErrNotFound
		}
		return "", err
	}
	return srcID, nil
}

func (s *DBStore) ListChapterMeta(bookID int64) ([]*model.ChapterMeta, error) {
	rows, err := s.Query(`SELECT idx, title FROM chapters WHERE book_id = ? ORDER BY idx`, bookID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*model.ChapterMeta
	for rows.Next() {
		m := &model.ChapterMeta{}
		if err := rows.Scan(&m.Idx, &m.Title); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *DBStore) GetChapter(bookID int64, idx int) (*model.Chapter, error) {
	ch := &model.Chapter{}
	err := s.QueryRow(`SELECT idx, title, content FROM chapters WHERE book_id = ? AND idx = ?`, bookID, idx).
		Scan(&ch.Idx, &ch.Title, &ch.Content)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return ch, nil
}

// ---------- 书架 ----------

func (s *DBStore) AddShelf(userID, bookID int64) error {
	_, err := s.Exec(`INSERT OR IGNORE INTO shelf (user_id, book_id) VALUES (?, ?)`, userID, bookID)
	return err
}

func (s *DBStore) RemoveShelf(userID, bookID int64) error {
	_, err := s.Exec(`DELETE FROM shelf WHERE user_id = ? AND book_id = ?`, userID, bookID)
	return err
}

// IsOnShelf 某用户书架是否已收录某本书（详情页据此展示 加入书架/已在书架）
func (s *DBStore) IsOnShelf(userID, bookID int64) (bool, error) {
	var n int
	err := s.QueryRow(`SELECT COUNT(1) FROM shelf WHERE user_id = ? AND book_id = ?`, userID, bookID).Scan(&n)
	return n > 0, err
}

type ShelfItem struct {
	Book          *model.Book `json:"book"`
	ProgressChapter int       `json:"progress_chapter_idx"`
}

func (s *DBStore) ListShelf(userID int64) ([]*ShelfItem, error) {
	rows, err := s.Query(`
		SELECT b.id, b.title, b.author, b.intro, b.cover, b.fanqie_id, b.source, b.status, b.file_path, b.file_size, b.file_mtime, b.total_chapters, b.finished, b.created_at,
		       COALESCE(p.chapter_idx, 0)
		FROM shelf s2
		JOIN books b ON b.id = s2.book_id
		LEFT JOIN reading_progress p ON p.user_id = s2.user_id AND p.book_id = s2.book_id
		WHERE s2.user_id = ?
		ORDER BY s2.added_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*ShelfItem
	for rows.Next() {
		b := &model.Book{}
		var progress int
		if err := rows.Scan(&b.ID, &b.Title, &b.Author, &b.Intro, &b.Cover, &b.FanqieID, &b.Source, &b.Status, &b.FilePath, &b.FileSize, &b.FileMtime, &b.TotalChapters, &b.Finished, &b.CreatedAt, &progress); err != nil {
			return nil, err
		}
		out = append(out, &ShelfItem{Book: b, ProgressChapter: progress})
	}
	return out, rows.Err()
}

// ---------- 阅读进度 ----------

func (s *DBStore) UpsertProgress(userID, bookID int64, chapterIdx int) error {
	_, err := s.Exec(`INSERT INTO reading_progress (user_id, book_id, chapter_idx, updated_at)
		VALUES (?, ?, ?, CURRENT_TIMESTAMP)
		ON CONFLICT(user_id, book_id) DO UPDATE SET chapter_idx = excluded.chapter_idx, updated_at = CURRENT_TIMESTAMP`,
		userID, bookID, chapterIdx)
	return err
}

func (s *DBStore) GetProgress(userID, bookID int64) (int, error) {
	var idx int
	err := s.QueryRow(`SELECT chapter_idx FROM reading_progress WHERE user_id = ? AND book_id = ?`, userID, bookID).Scan(&idx)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return 0, ErrNotFound
		}
		return 0, err
	}
	return idx, nil
}

// ---------- scan helpers ----------

func scanBook(row interface{ Scan(...any) error }) (*model.Book, error) {
	b := &model.Book{}
	err := row.Scan(&b.ID, &b.Title, &b.Author, &b.Intro, &b.Cover, &b.FanqieID, &b.Source, &b.Status, &b.FilePath, &b.FileSize, &b.FileMtime, &b.TotalChapters, &b.Finished, &b.CreatedAt)
	if err != nil {
		if err.Error() == "sql: no rows in result set" {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return b, nil
}

func scanBookRows(rows *sql.Rows) (*model.Book, error) {
	b := &model.Book{}
	err := rows.Scan(&b.ID, &b.Title, &b.Author, &b.Intro, &b.Cover, &b.FanqieID, &b.Source, &b.Status, &b.FilePath, &b.FileSize, &b.FileMtime, &b.TotalChapters, &b.Finished, &b.CreatedAt)
	if err != nil {
		return nil, err
	}
	return b, nil
}
