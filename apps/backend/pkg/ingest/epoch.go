// Package ingest turns Facebook Marketplace observations into canonical
// listing rows, and does it without recording who browsed what.
//
// Three concerns meet here and they are separable. What may be stored at all is
// the public-visibility rule (docs/ingest-attribution.md §1). What is refused
// is the gates in validate.go. Who submitted it is a per-epoch pseudonym rather
// than a device, which is this file.
package ingest

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"sync"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
)

// submitterIDLen truncates the HMAC. Sixteen bytes is far past any collision
// concern and keeps the column narrow: it is on every batch row forever, long
// after the key that gave it meaning is gone.
const submitterIDLen = 16

// clusterKeyLen truncates the seller cluster key. Same reasoning, and the value
// is compared for equality only — nothing ever reads it back out.
const clusterKeyLen = 16

// epochOrigin is a Monday, so a seven-day epoch lands on week boundaries. The
// length is configurable, and anchoring to a fixed instant is what makes two
// instances agree on which epoch it is without coordinating.
var epochOrigin = time.Date(1970, 1, 5, 0, 0, 0, 0, time.UTC)

// EpochStore is the part of db.Queries the keyring needs.
type EpochStore interface {
	GetIngestEpochKey(context.Context, pgtype.Date) (db.IngestEpochKey, error)
	CreateIngestEpochKey(context.Context, db.CreateIngestEpochKeyParams) (db.IngestEpochKey, error)
}

// Keyring mints and caches the per-epoch secret behind a submitter pseudonym.
//
// The keys are random and stored, never derived from a master secret. A derived
// key is recomputable forever, which would mean no observation ever actually
// becomes unlinkable — deleting the row is the whole mechanism.
type Keyring struct {
	store  EpochStore
	length time.Duration
	grace  time.Duration

	mu    sync.Mutex
	cache map[time.Time][]byte
}

func NewKeyring(store EpochStore, length, grace time.Duration) *Keyring {
	return &Keyring{
		store:  store,
		length: length,
		grace:  grace,
		cache:  make(map[time.Time][]byte),
	}
}

// EpochFor returns the start of the epoch containing at.
func (k *Keyring) EpochFor(at time.Time) time.Time {
	elapsed := at.UTC().Sub(epochOrigin)
	return epochOrigin.Add(elapsed - elapsed%k.length)
}

// SubmitterID derives the pseudonym a batch is stored under.
//
// Deterministic within the epoch, which is what corroboration needs
// (docs/ingest-attribution.md §5.2): two submissions
// corroborate only when their submitter ids differ, and that comparison is
// meaningless if one device can produce two values in the same window.
func (k *Keyring) SubmitterID(ctx context.Context, deviceID uuid.UUID, at time.Time) ([]byte, time.Time, error) {
	epoch := k.EpochFor(at)
	key, err := k.keyFor(ctx, epoch)
	if err != nil {
		return nil, time.Time{}, err
	}
	mac := hmac.New(sha256.New, key)
	id := deviceID
	mac.Write(id[:])
	return mac.Sum(nil)[:submitterIDLen], epoch, nil
}

func (k *Keyring) keyFor(ctx context.Context, epoch time.Time) ([]byte, error) {
	k.mu.Lock()
	cached, ok := k.cache[epoch]
	k.mu.Unlock()
	if ok {
		return cached, nil
	}

	date := pgtype.Date{Time: epoch, Valid: true}
	row, err := k.store.GetIngestEpochKey(ctx, date)
	if err == nil {
		k.remember(epoch, row.Key)
		return row.Key, nil
	}

	fresh := make([]byte, 32)
	if _, err := rand.Read(fresh); err != nil {
		return nil, fmt.Errorf("generate epoch key: %w", err)
	}
	// Get-or-create rather than insert. Two instances minting the epoch's first
	// pseudonym at the same moment must end up with one key, or half the
	// epoch's batches would never compare equal to the other half.
	row, err = k.store.CreateIngestEpochKey(ctx, db.CreateIngestEpochKeyParams{
		Epoch:     date,
		Key:       fresh,
		ExpiresAt: pgtype.Timestamptz{Time: epoch.Add(k.length + k.grace), Valid: true},
	})
	if err != nil {
		return nil, fmt.Errorf("create epoch key: %w", err)
	}
	k.remember(epoch, row.Key)
	return row.Key, nil
}

// remember caches the key and drops entries for epochs that have expired.
//
// The eviction is not about memory — it is a handful of keys. It is so that a
// key deleted from the database cannot go on being served from a long-lived
// process, which would make the deletion a matter of restarting the server.
func (k *Keyring) remember(epoch time.Time, key []byte) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.cache[epoch] = key
	cutoff := epoch.Add(-(k.length + k.grace))
	for at := range k.cache {
		if at.Before(cutoff) {
			delete(k.cache, at)
		}
	}
}

// ClusterKey derives a stable, non-enumerable grouping key from an identifier
// we are not allowed to store.
//
// Used for Facebook's seller profile id, which is readable only with a session
// and so fails the public-visibility rule. Grouping a seller's listings needs
// equality and nothing else, and that is exactly what survives here.
//
// The input space matters: a Facebook profile id is numeric, so anyone holding
// this key can enumerate candidates and recover the ids. That makes the key the
// thing being protected, and it is why the key never rotates and never leaves
// the server.
func ClusterKey(secret []byte, value string) []byte {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(value))
	return mac.Sum(nil)[:clusterKeyLen]
}
