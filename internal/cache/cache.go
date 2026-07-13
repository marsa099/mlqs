// Package cache is the sqlite store — the single source the render path
// reads from, mirroring slqs's cache.db design.
package cache

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"mlqs/internal/provider"

	_ "modernc.org/sqlite"
)

type DB struct {
	*sql.DB
}

func dbPath() string {
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		base = filepath.Join(os.Getenv("HOME"), ".local", "share")
	}
	return filepath.Join(base, "mlqs", "cache.db")
}

const schema = `
CREATE TABLE IF NOT EXISTS folders(
	account TEXT, id TEXT, name TEXT, role TEXT,
	unread INT DEFAULT 0, total INT DEFAULT 0,
	PRIMARY KEY(account, id));
CREATE TABLE IF NOT EXISTS conversations(
	account TEXT, id TEXT, folder_ids TEXT, subject TEXT, snippet TEXT,
	senders_json TEXT, date INT, unread INT, starred INT, has_attach INT,
	msg_count INT,
	PRIMARY KEY(account, id));
CREATE INDEX IF NOT EXISTS conv_date ON conversations(account, date DESC);
CREATE TABLE IF NOT EXISTS messages(
	account TEXT, id TEXT, conv_id TEXT,
	from_name TEXT, from_email TEXT, recipients_json TEXT,
	subject TEXT, date INT, unread INT, starred INT,
	body_text TEXT, body_html TEXT, attachments_json TEXT,
	PRIMARY KEY(account, id));
CREATE INDEX IF NOT EXISTS msg_conv ON messages(account, conv_id);
CREATE TABLE IF NOT EXISTS contacts(
	account TEXT, email TEXT, name TEXT,
	seen INT DEFAULT 0, last INT DEFAULT 0,
	PRIMARY KEY(account, email));
CREATE TABLE IF NOT EXISTS sync_state(
	account TEXT PRIMARY KEY, delta_token TEXT, synced_at INT);
`

func Open() (*DB, error) {
	p := dbPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", p+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &DB{db}, nil
}

func (d *DB) DeltaToken(account string) string {
	var t string
	d.QueryRow(`SELECT delta_token FROM sync_state WHERE account=?`, account).Scan(&t)
	return t
}

func (d *DB) SetDeltaToken(account, token string, syncedAt int64) error {
	_, err := d.Exec(`INSERT INTO sync_state(account, delta_token, synced_at) VALUES(?,?,?)
		ON CONFLICT(account) DO UPDATE SET delta_token=excluded.delta_token, synced_at=excluded.synced_at`,
		account, token, syncedAt)
	return err
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// UpsertConversations persists the list rows for warm-start rendering. Called
// on every live fetch and delta update, so the cache tracks what the UI last
// saw. senders/folder membership are stored as JSON.
func (d *DB) UpsertConversations(account string, convs []provider.Conversation) {
	if len(convs) == 0 {
		return
	}
	tx, err := d.Begin()
	if err != nil {
		return
	}
	stmt, err := tx.Prepare(`INSERT INTO conversations(account,id,folder_ids,subject,snippet,senders_json,date,unread,starred,has_attach,msg_count)
		VALUES(?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(account,id) DO UPDATE SET
			folder_ids=excluded.folder_ids, subject=excluded.subject, snippet=excluded.snippet,
			senders_json=excluded.senders_json, date=excluded.date, unread=excluded.unread,
			starred=excluded.starred, has_attach=excluded.has_attach, msg_count=excluded.msg_count`)
	if err != nil {
		tx.Rollback()
		return
	}
	defer stmt.Close()
	for _, c := range convs {
		fj, _ := json.Marshal(c.FolderIDs)
		sj, _ := json.Marshal(c.Senders)
		stmt.Exec(account, c.ID, string(fj), c.Subject, c.Snippet, string(sj),
			c.Date.Unix(), b2i(c.Unread), b2i(c.Starred), b2i(c.HasAttach), c.MsgCount)
	}
	tx.Commit()
}

func (d *DB) RemoveConversation(account, id string) {
	d.Exec(`DELETE FROM conversations WHERE account=? AND id=?`, account, id)
}

// SetConvFlags mirrors a local read/star toggle into the cache so the warm
// paint after a restart reflects the action (the next live fetch is still
// authoritative). col must be "unread" or "starred" — caller-fixed, not input.
func (d *DB) SetConvFlags(account, id, col string, v bool) {
	if col != "unread" && col != "starred" {
		return
	}
	d.Exec(`UPDATE conversations SET `+col+`=? WHERE account=? AND id=?`, b2i(v), account, id)
}

// CachedConversations returns a folder's rows for the instant paint, unread
// pinned on top then newest-first — the same order the live stitch produces.
// folder_ids is a JSON array; the quoted-id LIKE matches one token exactly.
func (d *DB) CachedConversations(account, folder string, limit int) []provider.Conversation {
	rows, err := d.Query(`SELECT id,folder_ids,subject,snippet,senders_json,date,unread,starred,has_attach,msg_count
		FROM conversations WHERE account=? AND folder_ids LIKE ?
		ORDER BY unread DESC, date DESC LIMIT ?`, account, `%"`+folder+`"%`, limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []provider.Conversation
	for rows.Next() {
		var c provider.Conversation
		var fj, sj string
		var date int64
		var unread, starred, hasAttach int
		if rows.Scan(&c.ID, &fj, &c.Subject, &c.Snippet, &sj, &date,
			&unread, &starred, &hasAttach, &c.MsgCount) != nil {
			continue
		}
		json.Unmarshal([]byte(fj), &c.FolderIDs)
		json.Unmarshal([]byte(sj), &c.Senders)
		c.Date = time.Unix(date, 0)
		c.Unread, c.Starred, c.HasAttach = unread != 0, starred != 0, hasAttach != 0
		out = append(out, c)
	}
	return out
}

func (d *DB) UpsertFolders(account string, folders []provider.Folder) {
	if len(folders) == 0 {
		return
	}
	tx, err := d.Begin()
	if err != nil {
		return
	}
	stmt, err := tx.Prepare(`INSERT INTO folders(account,id,name,role,unread,total)
		VALUES(?,?,?,?,?,?)
		ON CONFLICT(account,id) DO UPDATE SET
			name=excluded.name, role=excluded.role, unread=excluded.unread, total=excluded.total`)
	if err != nil {
		tx.Rollback()
		return
	}
	defer stmt.Close()
	for _, f := range folders {
		stmt.Exec(account, f.ID, f.Name, f.Role, f.Unread, f.Total)
	}
	tx.Commit()
}

func (d *DB) CachedFolders(account string) []provider.Folder {
	rows, err := d.Query(`SELECT id,name,role,unread,total FROM folders WHERE account=?`, account)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []provider.Folder
	for rows.Next() {
		var f provider.Folder
		if rows.Scan(&f.ID, &f.Name, &f.Role, &f.Unread, &f.Total) == nil {
			out = append(out, f)
		}
	}
	return out
}

func (d *DB) UpsertContact(account, email, name string, ts int64) {
	if email == "" {
		return
	}
	d.Exec(`INSERT INTO contacts(account, email, name, seen, last) VALUES(?,?,?,1,?)
		ON CONFLICT(account, email) DO UPDATE SET
		seen = seen + 1, last = excluded.last,
		name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END`,
		account, email, name, ts)
}

type Contact struct {
	Email string `json:"email"`
	Name  string `json:"name"`
}

func (d *DB) QueryContacts(account, prefix string, limit int) []Contact {
	rows, err := d.Query(`SELECT email, name FROM contacts
		WHERE account = ? AND (email LIKE ? OR name LIKE ?)
		ORDER BY seen DESC, last DESC LIMIT ?`,
		account, prefix+"%", "%"+prefix+"%", limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []Contact
	for rows.Next() {
		var c Contact
		rows.Scan(&c.Email, &c.Name)
		out = append(out, c)
	}
	return out
}
