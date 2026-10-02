// Package store persists push registrations (PostgreSQL in production, memory in tests).
package store

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Registration links an XEP-0357 node to one APNs device token.
type Registration struct {
	Node        string
	SecretHash  []byte
	AccountJID  string
	APNsToken   string
	Sandbox     bool
	DeviceKey   []byte
	CreatedAt   time.Time
	LastSuccess *time.Time
}

// ErrNotFound is returned for unknown nodes.
var ErrNotFound = errors.New("registration not found")

// HashSecret hashes the publish-options secret (only the hash is stored).
func HashSecret(secret string) []byte {
	h := sha256.Sum256([]byte(secret))
	return h[:]
}

// SecretMatches compares in constant time.
func (r *Registration) SecretMatches(secret string) bool {
	return subtle.ConstantTimeCompare(r.SecretHash, HashSecret(secret)) == 1
}

// Store is the persistence interface.
type Store interface {
	Put(ctx context.Context, r Registration) error
	Get(ctx context.Context, node string) (Registration, error)
	Delete(ctx context.Context, node string) error
	DeleteAccount(ctx context.Context, accountJID string) (int, error)
	MarkSuccess(ctx context.Context, node string) error
	SetMute(ctx context.Context, node, opaqueConv string, until time.Time) error
	MutedUntil(ctx context.Context, node, opaqueConv string) (time.Time, error)
	Count(ctx context.Context) (int, error)
}

// ---------------------------------------------------------------- PostgreSQL

// Postgres implements Store.
type Postgres struct{ pool *pgxpool.Pool }

const schema = `
CREATE TABLE IF NOT EXISTS registration (
    node          TEXT PRIMARY KEY,
    secret_hash   BYTEA NOT NULL,
    account_jid   TEXT NOT NULL,
    apns_token    TEXT NOT NULL,
    sandbox       BOOLEAN NOT NULL,
    device_key    BYTEA NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_success  TIMESTAMPTZ,
    UNIQUE (account_jid, apns_token)
);
CREATE TABLE IF NOT EXISTS mute (
    node        TEXT NOT NULL REFERENCES registration(node) ON DELETE CASCADE,
    opaque_conv TEXT NOT NULL,
    until       TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (node, opaque_conv)
);`

// OpenPostgres connects and applies the schema.
func OpenPostgres(ctx context.Context, url string) (*Postgres, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx, schema); err != nil {
		pool.Close()
		return nil, err
	}
	return &Postgres{pool: pool}, nil
}

func (p *Postgres) Put(ctx context.Context, r Registration) error {
	// Re-registering the same token for the same account replaces the old node (token refresh / reinstall).
	_, err := p.pool.Exec(ctx, `DELETE FROM registration WHERE account_jid = $1 AND apns_token = $2`, r.AccountJID, r.APNsToken)
	if err != nil {
		return err
	}
	_, err = p.pool.Exec(ctx, `INSERT INTO registration (node, secret_hash, account_jid, apns_token, sandbox, device_key)
		VALUES ($1, $2, $3, $4, $5, $6)`, r.Node, r.SecretHash, r.AccountJID, r.APNsToken, r.Sandbox, r.DeviceKey)
	return err
}

func (p *Postgres) Get(ctx context.Context, node string) (Registration, error) {
	var r Registration
	err := p.pool.QueryRow(ctx, `SELECT node, secret_hash, account_jid, apns_token, sandbox, device_key, created_at, last_success
		FROM registration WHERE node = $1`, node).
		Scan(&r.Node, &r.SecretHash, &r.AccountJID, &r.APNsToken, &r.Sandbox, &r.DeviceKey, &r.CreatedAt, &r.LastSuccess)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, ErrNotFound
	}
	return r, err
}

func (p *Postgres) Delete(ctx context.Context, node string) error {
	_, err := p.pool.Exec(ctx, `DELETE FROM registration WHERE node = $1`, node)
	return err
}

func (p *Postgres) DeleteAccount(ctx context.Context, accountJID string) (int, error) {
	tag, err := p.pool.Exec(ctx, `DELETE FROM registration WHERE account_jid = $1`, accountJID)
	return int(tag.RowsAffected()), err
}

func (p *Postgres) MarkSuccess(ctx context.Context, node string) error {
	_, err := p.pool.Exec(ctx, `UPDATE registration SET last_success = now() WHERE node = $1`, node)
	return err
}

func (p *Postgres) SetMute(ctx context.Context, node, opaqueConv string, until time.Time) error {
	if until.IsZero() {
		_, err := p.pool.Exec(ctx, `DELETE FROM mute WHERE node = $1 AND opaque_conv = $2`, node, opaqueConv)
		return err
	}
	_, err := p.pool.Exec(ctx, `INSERT INTO mute VALUES ($1, $2, $3)
		ON CONFLICT (node, opaque_conv) DO UPDATE SET until = EXCLUDED.until`, node, opaqueConv, until)
	return err
}

func (p *Postgres) MutedUntil(ctx context.Context, node, opaqueConv string) (time.Time, error) {
	var t time.Time
	err := p.pool.QueryRow(ctx, `SELECT until FROM mute WHERE node = $1 AND opaque_conv = $2`, node, opaqueConv).Scan(&t)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, nil
	}
	return t, err
}

func (p *Postgres) Count(ctx context.Context) (int, error) {
	var n int
	err := p.pool.QueryRow(ctx, `SELECT count(*) FROM registration`).Scan(&n)
	return n, err
}

// Close releases the pool.
func (p *Postgres) Close() { p.pool.Close() }

// ---------------------------------------------------------------- memory (tests)

// Memory implements Store in memory.
type Memory struct {
	mu    sync.Mutex
	regs  map[string]Registration
	mutes map[[2]string]time.Time
}

// NewMemory creates an empty in-memory store.
func NewMemory() *Memory {
	return &Memory{regs: map[string]Registration{}, mutes: map[[2]string]time.Time{}}
}

func (m *Memory) Put(_ context.Context, r Registration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, v := range m.regs {
		if v.AccountJID == r.AccountJID && v.APNsToken == r.APNsToken {
			delete(m.regs, k)
		}
	}
	r.CreatedAt = time.Now()
	m.regs[r.Node] = r
	return nil
}

func (m *Memory) Get(_ context.Context, node string) (Registration, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.regs[node]
	if !ok {
		return r, ErrNotFound
	}
	return r, nil
}

func (m *Memory) Delete(_ context.Context, node string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.regs, node)
	return nil
}

func (m *Memory) DeleteAccount(_ context.Context, jid string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for k, v := range m.regs {
		if v.AccountJID == jid {
			delete(m.regs, k)
			n++
		}
	}
	return n, nil
}

func (m *Memory) MarkSuccess(_ context.Context, node string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if r, ok := m.regs[node]; ok {
		now := time.Now()
		r.LastSuccess = &now
		m.regs[node] = r
	}
	return nil
}

func (m *Memory) SetMute(_ context.Context, node, conv string, until time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if until.IsZero() {
		delete(m.mutes, [2]string{node, conv})
	} else {
		m.mutes[[2]string{node, conv}] = until
	}
	return nil
}

func (m *Memory) MutedUntil(_ context.Context, node, conv string) (time.Time, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.mutes[[2]string{node, conv}], nil
}

func (m *Memory) Count(_ context.Context) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.regs), nil
}
