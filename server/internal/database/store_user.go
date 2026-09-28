package database

import (
	"database/sql"
	"errors"

	"golang.org/x/crypto/bcrypt"

	"xiaoshuo/internal/model"
)

var ErrNotFound = errors.New("not found")

type DBStore struct {
	*sql.DB
}

func NewStore(db *sql.DB) *DBStore {
	return &DBStore{db}
}

// ---------- 用户 ----------

func (s *DBStore) EnsureAdmin(username, password string) error {
	var count int
	if err := s.QueryRow(`SELECT COUNT(*) FROM users WHERE is_admin = 1`).Scan(&count); err != nil {
		return err
	}
	if count > 0 {
		return nil
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	_, err = s.Exec(`INSERT INTO users (username, password_hash, nickname, is_admin) VALUES (?, ?, '管理员', 1)`,
		username, string(hash))
	return err
}

func (s *DBStore) CreateUser(username, passwordHash, nickname string, isAdmin bool) (*model.User, error) {
	res, err := s.Exec(`INSERT INTO users (username, password_hash, nickname, is_admin) VALUES (?, ?, ?, ?)`,
		username, passwordHash, nickname, boolToInt(isAdmin))
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return s.GetUserByID(id)
}

func (s *DBStore) GetUserByUsername(username string) (*model.User, error) {
	return s.scanUser(s.QueryRow(
		`SELECT id, username, password_hash, nickname, is_admin, created_at FROM users WHERE username = ?`, username))
}

func (s *DBStore) GetUserByID(id int64) (*model.User, error) {
	return s.scanUser(s.QueryRow(
		`SELECT id, username, password_hash, nickname, is_admin, created_at FROM users WHERE id = ?`, id))
}

func (s *DBStore) ListUsers() ([]*model.User, error) {
	rows, err := s.Query(`SELECT id, username, password_hash, nickname, is_admin, created_at FROM users ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*model.User
	for rows.Next() {
		u, err := scanUserRows(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *DBStore) UpdateUserPassword(id int64, hash string) error {
	_, err := s.Exec(`UPDATE users SET password_hash = ? WHERE id = ?`, hash, id)
	return err
}

func (s *DBStore) DeleteUser(id int64) error {
	_, err := s.Exec(`DELETE FROM users WHERE id = ?`, id)
	return err
}

func (s *DBStore) scanUser(row *sql.Row) (*model.User, error) {
	u := &model.User{}
	var admin int
	err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.Nickname, &admin, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	u.IsAdmin = admin == 1
	return u, nil
}

func scanUserRows(rows *sql.Rows) (*model.User, error) {
	u := &model.User{}
	var admin int
	err := rows.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.Nickname, &admin, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	u.IsAdmin = admin == 1
	return u, nil
}

func CheckPassword(u *model.User, plain string) bool {
	return bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(plain)) == nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
