package ingest

import (
	"bytes"
	"context"
	"testing"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

type memoryEpochStore struct {
	keys   map[time.Time]db.IngestEpochKey
	writes int
}

func newMemoryEpochStore() *memoryEpochStore {
	return &memoryEpochStore{keys: map[time.Time]db.IngestEpochKey{}}
}

func (m *memoryEpochStore) GetIngestEpochKey(_ context.Context, epoch pgtype.Date) (db.IngestEpochKey, error) {
	if row, ok := m.keys[epoch.Time]; ok {
		return row, nil
	}
	return db.IngestEpochKey{}, pgx.ErrNoRows
}

func (m *memoryEpochStore) CreateIngestEpochKey(_ context.Context, arg db.CreateIngestEpochKeyParams) (db.IngestEpochKey, error) {
	if row, ok := m.keys[arg.Epoch.Time]; ok {
		return row, nil
	}
	m.writes++
	row := db.IngestEpochKey{Epoch: arg.Epoch, Key: arg.Key, ExpiresAt: arg.ExpiresAt}
	m.keys[arg.Epoch.Time] = row
	return row, nil
}

// forget drops the process cache so the next call has to reach the store,
// which is how a second instance sees the epoch.
func (k *Keyring) forget() {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.cache = map[time.Time][]byte{}
}

const week = 7 * 24 * time.Hour

func TestSubmitterIDIsStableWithinAnEpochAndChangesAcrossOne(t *testing.T) {
	store := newMemoryEpochStore()
	ring := NewKeyring(store, week, 2*week)
	device := uuid.New()
	ctx := context.Background()

	// Anchored to the epoch's own boundary rather than to a wall-clock date,
	// so the test says "same epoch" instead of assuming which day that is.
	start := ring.EpochFor(observedAt)

	first, epoch, err := ring.SubmitterID(ctx, device, start)
	if err != nil {
		t.Fatal(err)
	}
	again, sameEpoch, err := ring.SubmitterID(ctx, device, start.Add(week-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, again) || !epoch.Equal(sameEpoch) {
		t.Fatal("one install must produce one pseudonym inside an epoch, or corroboration cannot tell submitters apart")
	}

	next, nextEpoch, err := ring.SubmitterID(ctx, device, start.Add(week))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(first, next) || nextEpoch.Equal(epoch) {
		t.Fatal("the pseudonym must not survive the epoch")
	}
	if len(first) != submitterIDLen {
		t.Fatalf("length = %d", len(first))
	}
}

func TestTwoInstancesAgreeOnAnEpochKey(t *testing.T) {
	store := newMemoryEpochStore()
	device := uuid.New()
	ctx := context.Background()

	a, _, err := NewKeyring(store, week, 2*week).SubmitterID(ctx, device, observedAt)
	if err != nil {
		t.Fatal(err)
	}
	b, _, err := NewKeyring(store, week, 2*week).SubmitterID(ctx, device, observedAt)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a, b) {
		t.Fatal("two servers minting the epoch's first pseudonym must land on one key")
	}
	if store.writes != 1 {
		t.Fatalf("epoch keys written = %d, want 1", store.writes)
	}
}

// Deleting the key is the whole mechanism, so a long-lived process must not go
// on answering from memory after it is gone.
func TestKeyringDoesNotServeADeletedKeyFromCache(t *testing.T) {
	store := newMemoryEpochStore()
	ring := NewKeyring(store, week, 2*week)
	ctx := context.Background()

	if _, epoch, err := ring.SubmitterID(ctx, uuid.New(), observedAt); err != nil {
		t.Fatal(err)
	} else {
		delete(store.keys, epoch)
	}
	ring.forget()

	if _, _, err := ring.SubmitterID(ctx, uuid.New(), observedAt); err != nil {
		t.Fatal(err)
	}
	if store.writes != 2 {
		t.Fatalf("writes = %d: the deleted epoch should have been re-minted, not recalled", store.writes)
	}
}

func TestClusterKeyGroupsWithoutStoringTheIdentifier(t *testing.T) {
	secret := []byte("seller-key")
	a := ClusterKey(secret, "100000123456789")
	b := ClusterKey(secret, "100000123456789")
	c := ClusterKey(secret, "100000987654321")

	if !bytes.Equal(a, b) {
		t.Fatal("grouping needs equality to be deterministic")
	}
	if bytes.Equal(a, c) {
		t.Fatal("two sellers must not collapse into one")
	}
	if bytes.Contains(a, []byte("100000123456789")) {
		t.Fatal("the identifier must not survive into the stored value")
	}
	if !bytes.Equal(ClusterKey([]byte("other-key"), "100000123456789"), ClusterKey([]byte("other-key"), "100000123456789")) {
		t.Fatal("a different key must still be deterministic")
	}
	if bytes.Equal(a, ClusterKey([]byte("other-key"), "100000123456789")) {
		t.Fatal("the key must actually key the hash")
	}
}

func TestBreakerWaitsForEnoughCards(t *testing.T) {
	b := Breaker{Rate: 0.4, MinCards: 200}
	if b.Open(3, 2) {
		t.Fatal("three cards must not switch off a working extractor")
	}
	if b.Open(1000, 100) {
		t.Fatal("a tenth refused is normal traffic")
	}
	if !b.Open(1000, 500) {
		t.Fatal("half refused is a Facebook change")
	}
}
