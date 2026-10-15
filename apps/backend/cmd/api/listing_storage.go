package main

import (
	"encoding/json"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

func decodeListingSnapshot(data []byte, amount string, currency *string, originalAmount string) (*v1.SavedListingSnapshot, error) {
	snapshot := &v1.SavedListingSnapshot{}
	if err := protojson.Unmarshal(data, snapshot); err != nil {
		return nil, err
	}
	// Columns are authoritative, even if an older writer left values in JSONB.
	snapshot.PriceAmountDecimal = nil
	snapshot.PriceCurrencyCode = currency
	snapshot.OriginalPriceAmountDecimal = nil
	if amount != "" {
		snapshot.PriceAmountDecimal = proto.String(amount)
	}
	if originalAmount != "" {
		snapshot.OriginalPriceAmountDecimal = proto.String(originalAmount)
	}
	return snapshot, nil
}

func listingSnapshotUpdate(id uuid.UUID, snapshot *v1.SavedListingSnapshot, ages map[string]time.Time) (db.UpdateListingSnapshotParams, error) {
	params := db.UpdateListingSnapshotParams{ID: id, PriceAmountDecimal: snapshot.PriceAmountDecimal,
		PriceCurrencyCode: snapshot.PriceCurrencyCode, OriginalPriceAmountDecimal: snapshot.OriginalPriceAmountDecimal}
	source := proto.Clone(snapshot).(*v1.SavedListingSnapshot)
	source.PriceAmountDecimal = nil
	source.PriceCurrencyCode = nil
	source.OriginalPriceAmountDecimal = nil
	var err error
	if params.Snapshot, err = protojson.Marshal(source); err != nil {
		return params, err
	}
	params.FieldObservedAt, err = json.Marshal(ages)
	return params, err
}
