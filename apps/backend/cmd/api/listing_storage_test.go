package main

import (
	"encoding/json"
	"testing"
	"time"

	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"
)

func TestListingColumnsOverrideSnapshotPriceMetadata(t *testing.T) {
	stale := []byte(`{"priceText":"CA$12.50","priceAmountDecimal":"999","priceCurrencyCode":"USD","originalPriceAmountDecimal":"999"}`)
	snapshot, err := decodeListingSnapshot(stale, "12.50", proto.String("CAD"), "20.00")
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.GetPriceAmountDecimal() != "12.50" || snapshot.GetPriceCurrencyCode() != "CAD" || snapshot.GetOriginalPriceAmountDecimal() != "20.00" {
		t.Fatal(snapshot)
	}
	snapshot, err = decodeListingSnapshot(stale, "", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.PriceAmountDecimal != nil || snapshot.PriceCurrencyCode != nil || snapshot.OriginalPriceAmountDecimal != nil || snapshot.GetPriceText() != "CA$12.50" {
		t.Fatal("JSONB overrode unknown columns", snapshot)
	}
}

func TestListingStorageKeepsOneAuthoritativePrice(t *testing.T) {
	snapshot := &v1.SavedListingSnapshot{PriceText: proto.String("CA$12.50"), PriceAmountDecimal: proto.String("12.50"), PriceCurrencyCode: proto.String("CAD"), OriginalPriceAmountDecimal: proto.String("20.00")}
	id := uuid.New()
	ages := map[string]time.Time{"price_text": time.Now().UTC()}
	update, err := listingSnapshotUpdate(id, snapshot, ages)
	if err != nil {
		t.Fatal(err)
	}
	if update.ID != id || *update.PriceAmountDecimal != "12.50" || *update.PriceCurrencyCode != "CAD" || *update.OriginalPriceAmountDecimal != "20.00" {
		t.Fatal(update)
	}
	var source map[string]any
	if err := json.Unmarshal(update.Snapshot, &source); err != nil {
		t.Fatal(err)
	}
	if source["priceText"] != "CA$12.50" {
		t.Fatal("source text lost")
	}
	for _, key := range []string{"priceAmountDecimal", "priceCurrencyCode", "originalPriceAmountDecimal"} {
		if _, exists := source[key]; exists {
			t.Fatalf("duplicated %s in JSONB", key)
		}
	}
	if snapshot.GetPriceAmountDecimal() != "12.50" {
		t.Fatal("serialization mutated input")
	}
	var restored map[string]time.Time
	if err := json.Unmarshal(update.FieldObservedAt, &restored); err != nil || !restored["price_text"].Equal(ages["price_text"]) {
		t.Fatal("freshness lost", err)
	}
}
