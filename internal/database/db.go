package database

import (
	"database/sql"
	"fmt"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/paths"
)

const (
	ConfigTypeSite = 0
	ConfigTypeLive = 1
)

type DB struct {
	conn *sql.DB
	mu   sync.Mutex
}

var defaultDB *DB

func Open() (*DB, error) {
	if defaultDB != nil {
		return defaultDB, nil
	}
	conn, err := sql.Open("sqlite", paths.DB())
	if err != nil {
		return nil, err
	}
	// 单连接 + busy 等待，降低并发写时 SQLITE_BUSY
	conn.SetMaxOpenConns(1)
	conn.SetMaxIdleConns(1)
	conn.SetConnMaxLifetime(0)
	_, _ = conn.Exec(`PRAGMA busy_timeout = 8000`)
	_, _ = conn.Exec(`PRAGMA journal_mode = WAL`)
	db := &DB{conn: conn}
	if err := db.migrate(); err != nil {
		return nil, err
	}
	defaultDB = db
	return db, nil
}

func (db *DB) Close() error {
	if db.conn != nil {
		return db.conn.Close()
	}
	return nil
}

func (db *DB) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS config (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			type INTEGER NOT NULL,
			time INTEGER NOT NULL,
			url TEXT,
			json TEXT,
			name TEXT,
			home TEXT,
			parse TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS site (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			key TEXT NOT NULL,
			name TEXT,
			searchable INTEGER,
			changeable INTEGER,
			recordable INTEGER,
			config_id INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS history (
			key TEXT PRIMARY KEY,
			vod_pic TEXT,
			vod_name TEXT,
			vod_flag TEXT,
			vod_remarks TEXT,
			episode_url TEXT,
			rev_sort INTEGER,
			rev_play INTEGER,
			create_time INTEGER,
			opening INTEGER,
			ending INTEGER,
			position INTEGER,
			duration INTEGER,
			speed REAL,
			player INTEGER,
			scale INTEGER,
			cid INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS keep (
			key TEXT PRIMARY KEY,
			vod_pic TEXT,
			vod_name TEXT,
			vod_flag TEXT,
			vod_remarks TEXT,
			create_time INTEGER,
			type INTEGER DEFAULT 0,
			cid INTEGER DEFAULT 0,
			site_name TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS spider_status (
			site_key TEXT PRIMARY KEY,
			status INTEGER,
			message TEXT,
			updated_at INTEGER
		)`,
		`CREATE TABLE IF NOT EXISTS track (
			key TEXT NOT NULL,
			kind TEXT NOT NULL,
			track_id INTEGER NOT NULL DEFAULT -1,
			name TEXT,
			format TEXT,
			PRIMARY KEY (key, kind)
		)`,
	}
	for _, s := range stmts {
		if _, err := db.conn.Exec(s); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	// 兼容旧 keep 表：补列
	alterCols := []string{
		`ALTER TABLE keep ADD COLUMN type INTEGER DEFAULT 0`,
		`ALTER TABLE keep ADD COLUMN cid INTEGER DEFAULT 0`,
		`ALTER TABLE keep ADD COLUMN site_name TEXT`,
	}
	for _, s := range alterCols {
		_, _ = db.conn.Exec(s)
	}
	return nil
}

type Config struct {
	ID    int64
	Type  int64
	Time  int64
	URL   string
	JSON  string
	Name  string
	Home  string
	Parse string
}

func (db *DB) FindConfig(url string, typ int64) (*Config, error) {
	row := db.conn.QueryRow(
		`SELECT id, type, time, COALESCE(url,''), COALESCE(json,''), COALESCE(name,''), COALESCE(home,''), COALESCE(parse,'')
		 FROM config WHERE (url = ? OR json = ?) AND type = ? ORDER BY time DESC LIMIT 1`,
		url, url, typ,
	)
	return scanConfig(row)
}

func (db *DB) FindConfigByType(typ int64) (*Config, error) {
	row := db.conn.QueryRow(
		`SELECT id, type, time, COALESCE(url,''), COALESCE(json,''), COALESCE(name,''), COALESCE(home,''), COALESCE(parse,'')
		 FROM config WHERE type = ? ORDER BY time DESC LIMIT 1`, typ,
	)
	return scanConfig(row)
}

func scanConfig(row *sql.Row) (*Config, error) {
	var c Config
	err := row.Scan(&c.ID, &c.Type, &c.Time, &c.URL, &c.JSON, &c.Name, &c.Home, &c.Parse)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// ListConfigs 列出某类型的全部历史配置（多仓/线路）。
func (db *DB) ListConfigs(typ int64) ([]Config, error) {
	rows, err := db.conn.Query(
		`SELECT id, type, time, COALESCE(url,''), COALESCE(json,''), COALESCE(name,''), COALESCE(home,''), COALESCE(parse,'')
		 FROM config WHERE type = ? ORDER BY time DESC`, typ)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Config
	for rows.Next() {
		var c Config
		if err := rows.Scan(&c.ID, &c.Type, &c.Time, &c.URL, &c.JSON, &c.Name, &c.Home, &c.Parse); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (db *DB) UpsertConfig(c *Config) (int64, error) {
	now := time.Now().UnixMilli()
	if c.ID == 0 && c.URL != "" {
		if existing, err := db.FindConfig(c.URL, c.Type); err == nil && existing != nil && existing.ID > 0 {
			c.ID = existing.ID
			if c.Home == "" {
				c.Home = existing.Home
			}
			if c.Parse == "" {
				c.Parse = existing.Parse
			}
			if c.JSON == "" {
				c.JSON = existing.JSON
			}
			if c.Name == "" {
				c.Name = existing.Name
			}
		}
	}
	if c.ID == 0 {
		res, err := db.conn.Exec(
			`INSERT INTO config(type, time, url, json, name, home, parse) VALUES(?,?,?,?,?,?,?)`,
			c.Type, now, nullStr(c.URL), nullStr(c.JSON), nullStr(c.Name), nullStr(c.Home), nullStr(c.Parse),
		)
		if err != nil {
			return 0, err
		}
		return res.LastInsertId()
	}
	_, err := db.conn.Exec(
		`UPDATE config SET time=?, url=?, json=?, name=?, home=?, parse=? WHERE id=?`,
		now, nullStr(c.URL), nullStr(c.JSON), nullStr(c.Name), nullStr(c.Home), nullStr(c.Parse), c.ID,
	)
	return c.ID, err
}

// DeleteConfigByURL 按 URL 删除配置记录。
func (db *DB) DeleteConfigByURL(url string, typ int64) error {
	if strings.TrimSpace(url) == "" {
		return nil
	}
	_, err := db.conn.Exec(`DELETE FROM config WHERE url = ? AND type = ?`, url, typ)
	return err
}

// SetConfigHome 按 url+type 更新记住的首页站点 key。
// 无匹配行时（配置尚未入库）视为失败并返回错误，调用方可感知持久化未生效。
func (db *DB) SetConfigHome(url string, typ int64, home string) error {
	now := time.Now().UnixMilli()
	res, err := db.conn.Exec(
		`UPDATE config SET home=?, time=? WHERE url=? AND type=?`,
		nullStr(home), now, url, typ,
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("config row not found: url=%s type=%d", url, typ)
	}
	return nil
}

// SetConfigName 更新配置显示名（空字符串表示清除自定义名，列表回落为完整地址）。
func (db *DB) SetConfigName(url string, typ int64, name string) error {
	url = strings.TrimSpace(url)
	if url == "" {
		return nil
	}
	now := time.Now().UnixMilli()
	res, err := db.conn.Exec(
		`UPDATE config SET name=?, time=? WHERE url=? AND type=?`,
		nullStr(strings.TrimSpace(name)), now, url, typ,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n > 0 {
		return nil
	}
	_, err = db.conn.Exec(
		`INSERT INTO config(type, time, url, json, name, home, parse) VALUES(?,?,?,?,?,?,?)`,
		typ, now, url, nil, nullStr(strings.TrimSpace(name)), nil, nil,
	)
	return err
}

// UpdateConfigURLName 编辑源：改地址和/或名称（对齐 TV ConfigDialog.edit）。
func (db *DB) UpdateConfigURLName(oldURL string, typ int64, newURL, name string) error {
	oldURL = strings.TrimSpace(oldURL)
	newURL = strings.TrimSpace(newURL)
	name = strings.TrimSpace(name)
	if newURL == "" {
		return fmt.Errorf("empty url")
	}
	if oldURL == "" {
		oldURL = newURL
	}
	now := time.Now().UnixMilli()
	if oldURL == newURL {
		return db.SetConfigName(newURL, typ, name)
	}
	existing, err := db.FindConfig(oldURL, typ)
	if err != nil {
		return err
	}
	if existing == nil {
		_, err = db.UpsertConfig(&Config{Type: typ, URL: newURL, Name: name})
		return err
	}
	// 若新 URL 已有另一行，先删旧再更新保留字段到新键。
	if other, err := db.FindConfig(newURL, typ); err == nil && other != nil && other.ID != existing.ID {
		_ = db.DeleteConfigByURL(oldURL, typ)
		other.Name = name
		if other.JSON == "" {
			other.JSON = existing.JSON
		}
		if other.Home == "" {
			other.Home = existing.Home
		}
		_, err = db.UpsertConfig(other)
		return err
	}
	_, err = db.conn.Exec(
		`UPDATE config SET url=?, name=?, time=? WHERE id=?`,
		newURL, nullStr(name), now, existing.ID,
	)
	return err
}

func (db *DB) SyncSites(configID int64, sites []model.Site) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	rows, err := tx.Query(`SELECT id, key, searchable, changeable FROM site WHERE config_id = ?`, configID)
	if err != nil {
		return err
	}
	existing := map[string]struct {
		id                     int
		searchable, changeable *int
	}{}
	for rows.Next() {
		var key string
		var id int
		var s, c sql.NullInt64
		if err := rows.Scan(&id, &key, &s, &c); err != nil {
			rows.Close()
			return err
		}
		e := struct {
			id                     int
			searchable, changeable *int
		}{id: id}
		if s.Valid {
			v := int(s.Int64)
			e.searchable = &v
		}
		if c.Valid {
			v := int(c.Int64)
			e.changeable = &v
		}
		existing[key] = e
	}
	rows.Close()

	for i := range sites {
		site := &sites[i]
		if ex, ok := existing[site.Key]; ok {
			site.ID = ex.id
			if ex.searchable != nil {
				site.Searchable = model.FlexInt{Valid: true, Value: *ex.searchable}
			}
			if ex.changeable != nil {
				site.Changeable = model.FlexInt{Valid: true, Value: *ex.changeable}
			}
			_, err = tx.Exec(`UPDATE site SET name=?, searchable=?, changeable=? WHERE id=?`,
				site.Name, flexIntPtr(site.Searchable), flexIntPtr(site.Changeable), site.ID)
		} else {
			res, err := tx.Exec(`INSERT INTO site(key, name, searchable, changeable, recordable, config_id) VALUES(?,?,?,?,0,?)`,
				site.Key, site.Name, flexIntPtr(site.Searchable), flexIntPtr(site.Changeable), configID)
			if err != nil {
				return err
			}
			id, _ := res.LastInsertId()
			site.ID = int(id)
		}
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

// UpdateSiteFlags 持久化站源 searchable/changeable（站源配置）。
func (db *DB) UpdateSiteFlags(siteID int, searchable, changeable model.FlexInt) error {
	if siteID <= 0 {
		return fmt.Errorf("invalid site id")
	}
	db.mu.Lock()
	defer db.mu.Unlock()
	_, err := db.conn.Exec(`UPDATE site SET searchable=?, changeable=? WHERE id=?`,
		flexIntPtr(searchable), flexIntPtr(changeable), siteID)
	return err
}

// UpdateSiteFlagsByKey 按 config + key 更新（无 site.ID 时的回退）。
func (db *DB) UpdateSiteFlagsByKey(configID int64, key string, searchable, changeable model.FlexInt) error {
	if configID <= 0 || key == "" {
		return fmt.Errorf("invalid site key")
	}
	db.mu.Lock()
	defer db.mu.Unlock()
	_, err := db.conn.Exec(`UPDATE site SET searchable=?, changeable=? WHERE config_id=? AND key=?`,
		flexIntPtr(searchable), flexIntPtr(changeable), configID, key)
	return err
}

type History struct {
	Key        string  `json:"key"`
	VodPic     string  `json:"vodPic"`
	VodName    string  `json:"vodName"`
	VodFlag    string  `json:"vodFlag"`
	VodRemarks string  `json:"vodRemarks"`
	EpisodeURL string  `json:"episodeUrl"`
	CreateTime int64   `json:"createTime"`
	Position   int64   `json:"position"`
	Duration   int64   `json:"duration"`
	Speed      float64 `json:"speed"`
	Opening    int64   `json:"opening"`
	Ending     int64   `json:"ending"`
}

// StartPositionMs max(opening, position)。
func StartPositionMs(h *History) int64 {
	if h == nil {
		return 0
	}
	start := h.Position
	if h.Opening > start {
		start = h.Opening
	}
	if start < 0 {
		return 0
	}
	return start
}

func (db *DB) ListHistory(limit int) ([]History, error) {
	rows, err := db.conn.Query(
		`SELECT key, COALESCE(vod_pic,''), COALESCE(vod_name,''), COALESCE(vod_flag,''), COALESCE(vod_remarks,''),
		        COALESCE(episode_url,''), COALESCE(create_time,0), COALESCE(position,0), COALESCE(duration,0), COALESCE(speed,1),
		        COALESCE(opening,0), COALESCE(ending,0)
		 FROM history ORDER BY rev_play DESC, create_time DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []History
	for rows.Next() {
		var h History
		if err := rows.Scan(&h.Key, &h.VodPic, &h.VodName, &h.VodFlag, &h.VodRemarks, &h.EpisodeURL,
			&h.CreateTime, &h.Position, &h.Duration, &h.Speed, &h.Opening, &h.Ending); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

func (db *DB) SaveHistory(h History) error {
	now := time.Now().UnixMilli()
	_, err := db.conn.Exec(`INSERT OR REPLACE INTO history
		(key, vod_pic, vod_name, vod_flag, vod_remarks, episode_url, create_time, rev_play, position, duration, speed, opening, ending)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		h.Key, h.VodPic, h.VodName, h.VodFlag, h.VodRemarks, h.EpisodeURL, now, now,
		h.Position, h.Duration, h.Speed, h.Opening, h.Ending)
	return err
}

// UpdateHistoryProgress 更新续播进度。
func (db *DB) UpdateHistoryProgress(key string, position, duration int64) error {
	_, err := db.conn.Exec(`UPDATE history SET position=?, duration=?, rev_play=? WHERE key=?`,
		position, duration, time.Now().UnixMilli(), key)
	return err
}

// UpdateHistoryOffsets 更新片头/片尾（毫秒），跨集复用；无历史行时插入占位。
func (db *DB) UpdateHistoryOffsets(key string, opening, ending int64) error {
	if key == "" {
		return nil
	}
	if opening < 0 {
		opening = 0
	}
	if ending < 0 {
		ending = 0
	}
	now := time.Now().UnixMilli()
	_, err := db.conn.Exec(`INSERT INTO history(key, opening, ending, create_time, rev_play, speed)
		VALUES(?,?,?,?,?,1)
		ON CONFLICT(key) DO UPDATE SET opening=excluded.opening, ending=excluded.ending, rev_play=excluded.rev_play`,
		key, opening, ending, now, now)
	return err
}

// DeleteHistory 删除单条历史。
func (db *DB) DeleteHistory(key string) error {
	_, err := db.conn.Exec(`DELETE FROM history WHERE key = ?`, key)
	return err
}

// ClearHistory 清空全部历史。
func (db *DB) ClearHistory() error {
	_, err := db.conn.Exec(`DELETE FROM history`)
	return err
}

// ListAllHistory 导出全部历史（备份/同步）。
func (db *DB) ListAllHistory() ([]History, error) {
	return db.ListHistory(10000)
}

// ListAllKeep 导出全部收藏。
func (db *DB) ListAllKeep(typ int64) ([]Keep, error) {
	return db.ListKeep(typ, 10000)
}

// ImportHistory 批量导入历史；mode 1=合并，2=覆盖。
func (db *DB) ImportHistory(items []History, mode int) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if mode == 2 {
		if _, err := tx.Exec(`DELETE FROM history`); err != nil {
			return err
		}
	}
	stmt := `INSERT OR REPLACE INTO history
		(key, vod_pic, vod_name, vod_flag, vod_remarks, episode_url, create_time, rev_play, position, duration, speed, opening, ending)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`
	for _, h := range items {
		ct := h.CreateTime
		if ct == 0 {
			ct = time.Now().UnixMilli()
		}
		speed := h.Speed
		if speed == 0 {
			speed = 1
		}
		if _, err := tx.Exec(stmt, h.Key, h.VodPic, h.VodName, h.VodFlag, h.VodRemarks, h.EpisodeURL,
			ct, ct, h.Position, h.Duration, speed, h.Opening, h.Ending); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ImportKeep 批量导入收藏；mode 1=合并，2=覆盖。
func (db *DB) ImportKeep(items []Keep, mode int) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if mode == 2 {
		if _, err := tx.Exec(`DELETE FROM keep WHERE type = ?`, KeepTypeVod); err != nil {
			return err
		}
	}
	stmt := `INSERT OR REPLACE INTO keep(key, vod_pic, vod_name, vod_flag, vod_remarks, create_time, type, cid, site_name)
		VALUES(?,?,?,?,?,?,?,?,?)`
	for _, k := range items {
		ct := k.CreateTime
		if ct == 0 {
			ct = time.Now().UnixMilli()
		}
		if _, err := tx.Exec(stmt, k.Key, k.VodPic, k.VodName, k.VodFlag, k.VodRemarks,
			ct, k.Type, k.CID, k.SiteName); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// DeleteKeep 删除单条收藏。
func (db *DB) DeleteKeep(key string) error {
	_, err := db.conn.Exec(`DELETE FROM keep WHERE key = ?`, key)
	return err
}

// GetHistory 按 key 读取历史。
func (db *DB) GetHistory(key string) (*History, error) {
	row := db.conn.QueryRow(
		`SELECT key, COALESCE(vod_pic,''), COALESCE(vod_name,''), COALESCE(vod_flag,''), COALESCE(vod_remarks,''),
		        COALESCE(episode_url,''), COALESCE(create_time,0), COALESCE(position,0), COALESCE(duration,0), COALESCE(speed,1),
		        COALESCE(opening,0), COALESCE(ending,0)
		 FROM history WHERE key = ?`, key)
	var h History
	err := row.Scan(&h.Key, &h.VodPic, &h.VodName, &h.VodFlag, &h.VodRemarks, &h.EpisodeURL,
		&h.CreateTime, &h.Position, &h.Duration, &h.Speed, &h.Opening, &h.Ending)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &h, nil
}

const (
	KeepTypeVod  int64 = 0
	KeepTypeLive int64 = 1
)

// Keep 收藏。
type Keep struct {
	Key        string `json:"key"`
	VodPic     string `json:"vodPic"`
	VodName    string `json:"vodName"`
	VodFlag    string `json:"vodFlag"`
	VodRemarks string `json:"vodRemarks"`
	CreateTime int64  `json:"createTime"`
	Type       int64  `json:"type"`
	CID        int64  `json:"cid"`
	SiteName   string `json:"siteName"`
}

func KeepVodKey(siteKey, vodID string) string { return siteKey + "$$$" + vodID }
func KeepLiveKey(liveName, channel string) string {
	return liveName + "$$$" + channel
}

func (db *DB) IsKept(key string) (bool, error) {
	var n int
	err := db.conn.QueryRow(`SELECT COUNT(1) FROM keep WHERE key = ?`, key).Scan(&n)
	return n > 0, err
}

func (db *DB) ToggleKeep(k Keep) (bool, error) {
	kept, err := db.IsKept(k.Key)
	if err != nil {
		return false, err
	}
	if kept {
		_, err = db.conn.Exec(`DELETE FROM keep WHERE key = ?`, k.Key)
		return false, err
	}
	k.CreateTime = time.Now().UnixMilli()
	_, err = db.conn.Exec(`INSERT INTO keep(key, vod_pic, vod_name, vod_flag, vod_remarks, create_time, type, cid, site_name)
		VALUES(?,?,?,?,?,?,?,?,?)`,
		k.Key, k.VodPic, k.VodName, k.VodFlag, k.VodRemarks, k.CreateTime, k.Type, k.CID, k.SiteName)
	return true, err
}

func (db *DB) ListKeep(typ int64, limit int) ([]Keep, error) {
	rows, err := db.conn.Query(
		`SELECT key, COALESCE(vod_pic,''), COALESCE(vod_name,''), COALESCE(vod_flag,''), COALESCE(vod_remarks,''),
		        COALESCE(create_time,0), COALESCE(type,0), COALESCE(cid,0), COALESCE(site_name,'')
		 FROM keep WHERE type = ? ORDER BY create_time DESC LIMIT ?`, typ, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Keep
	for rows.Next() {
		var k Keep
		if err := rows.Scan(&k.Key, &k.VodPic, &k.VodName, &k.VodFlag, &k.VodRemarks,
			&k.CreateTime, &k.Type, &k.CID, &k.SiteName); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

func (db *DB) ListKeepLive() ([]Keep, error) {
	return db.ListKeep(KeepTypeLive, 500)
}

// SpiderStatus 爬虫检测结果。
type SpiderStatus struct {
	SiteKey   string
	Status    int // 1 ok, 0 fail
	Message   string
	UpdatedAt int64
}

func (db *DB) UpsertSpiderStatus(s SpiderStatus) error {
	s.UpdatedAt = time.Now().UnixMilli()
	_, err := db.conn.Exec(`INSERT OR REPLACE INTO spider_status(site_key, status, message, updated_at) VALUES(?,?,?,?)`,
		s.SiteKey, s.Status, s.Message, s.UpdatedAt)
	return err
}

// MediaTrack 音轨/字幕偏好（按 history key 持久化）。
type MediaTrack struct {
	Key     string
	Kind    string // audio / sub
	TrackID int64
	Name    string
	Format  string
}

func (db *DB) SaveTrack(t MediaTrack) error {
	_, err := db.conn.Exec(`INSERT OR REPLACE INTO track(key, kind, track_id, name, format) VALUES(?,?,?,?,?)`,
		t.Key, t.Kind, t.TrackID, t.Name, t.Format)
	return err
}

func (db *DB) GetTrack(key, kind string) (*MediaTrack, error) {
	row := db.conn.QueryRow(
		`SELECT key, kind, track_id, COALESCE(name,''), COALESCE(format,'')
		 FROM track WHERE key = ? AND kind = ?`, key, kind)
	var t MediaTrack
	if err := row.Scan(&t.Key, &t.Kind, &t.TrackID, &t.Name, &t.Format); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	return &t, nil
}

func (db *DB) ListSpiderStatus() ([]SpiderStatus, error) {
	rows, err := db.conn.Query(`SELECT site_key, status, COALESCE(message,''), COALESCE(updated_at,0) FROM spider_status`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SpiderStatus
	for rows.Next() {
		var s SpiderStatus
		if err := rows.Scan(&s.SiteKey, &s.Status, &s.Message, &s.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func nullStr(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func intPtr(p *int) interface{} {
	if p == nil {
		return nil
	}
	return *p
}

func flexIntPtr(f model.FlexInt) interface{} {
	if !f.Valid {
		return nil
	}
	return f.Value
}
