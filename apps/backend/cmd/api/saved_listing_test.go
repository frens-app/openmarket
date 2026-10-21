package main

import (
	"testing"
	"time"

	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestListingMergeFreshnessAndPresence(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	stamp := func(d time.Duration) *timestamppb.Timestamp { return timestamppb.New(now.Add(d)) }
	snapshot := &v1.SavedListingSnapshot{}
	ages := map[string]time.Time{}
	mergeListingSnapshot(snapshot, &v1.SavedListingSnapshot{
		FacebookListingId: "123", Title: proto.String("Desk"), PriceText: proto.String("$20"), Description: proto.String("Solid oak"), Sold: proto.Bool(true),
		Seller:         &v1.FacebookSeller{Id: "42", Name: "Sam", Rating: proto.Float64(4.8)},
		CardObservedAt: stamp(-time.Hour), PriceObservedAt: stamp(-time.Hour), DetailObservedAt: stamp(-time.Hour), AvailabilityObservedAt: stamp(-time.Hour),
	}, ages)
	mergeListingSnapshot(snapshot, &v1.SavedListingSnapshot{
		FacebookListingId: "123", PriceText: proto.String("Free"), Sold: proto.Bool(false), Pending: proto.Bool(false),
		PriceObservedAt: stamp(0), AvailabilityObservedAt: stamp(0),
	}, ages)
	mergeListingSnapshot(snapshot, &v1.SavedListingSnapshot{
		FacebookListingId: "123", Title: proto.String("Old title"), PriceText: proto.String("$99"), Sold: proto.Bool(true),
		LocationText: proto.String("Toronto"), CardObservedAt: stamp(-2 * time.Hour), PriceObservedAt: stamp(-2 * time.Hour), AvailabilityObservedAt: stamp(-2 * time.Hour),
	}, ages)
	if snapshot.GetTitle() != "Desk" || snapshot.GetPriceText() != "Free" || snapshot.Sold == nil || snapshot.GetSold() || snapshot.Pending == nil || snapshot.GetDescription() != "Solid oak" || snapshot.GetLocationText() != "Toronto" {
		t.Fatalf("bad merge: %v", snapshot)
	}
	// A newer seller name cannot erase an older rating; zero/false remain explicit.
	mergeListingSnapshot(snapshot, &v1.SavedListingSnapshot{FacebookListingId: "123", Seller: &v1.FacebookSeller{Id: "42", Name: "Sam New", RatingCount: proto.Int32(0), IsHighlyRated: proto.Bool(false)}, DetailObservedAt: stamp(0)}, ages)
	if snapshot.Seller.GetRating() != 4.8 || snapshot.Seller.GetName() != "Sam New" || snapshot.Seller.RatingCount == nil || snapshot.Seller.IsHighlyRated == nil {
		t.Fatal(snapshot.Seller)
	}
	// Returning a merged record must not advertise old fields as newly observed.
	if !snapshot.CardObservedAt.AsTime().Equal(now.Add(-2*time.Hour)) || !snapshot.DetailObservedAt.AsTime().Equal(now.Add(-time.Hour)) {
		t.Fatal("incorrect group freshness", snapshot)
	}
}

func TestListingChangeValidation(t *testing.T) {
	now := time.Now()
	valid := func() *v1.SavedListingChange {
		return &v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: "123", Saved: proto.Bool(true), SavedAt: timestamppb.New(now), Snapshot: &v1.SavedListingSnapshot{FacebookListingId: "123", Title: proto.String("Desk"), CardObservedAt: timestamppb.New(now)}}
	}
	for name, mutate := range map[string]func(*v1.SavedListingChange){
		"future":       func(c *v1.SavedListingChange) { c.Snapshot.CardObservedAt = timestamppb.New(now.Add(time.Hour)) },
		"missing time": func(c *v1.SavedListingChange) { c.Snapshot.CardObservedAt = nil },
		"different id": func(c *v1.SavedListingChange) { c.Snapshot.FacebookListingId = "456" },
		"bad url":      func(c *v1.SavedListingChange) { c.Snapshot.ThumbnailUrl = proto.String("file:///etc/passwd") },
		"invalid id":   func(c *v1.SavedListingChange) { c.FacebookListingId = "p:photo" },
		"conflicting availability": func(c *v1.SavedListingChange) {
			c.Snapshot.Sold = proto.Bool(true)
			c.Snapshot.Pending = proto.Bool(true)
		},
	} {
		t.Run(name, func(t *testing.T) {
			c := valid()
			mutate(c)
			if validateListingChange(c, now) == nil {
				t.Fatal("accepted invalid change")
			}
		})
	}
	if err := validateListingChange(valid(), now); err != nil {
		t.Fatal(err)
	}
	if err := validateListingChange(&v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: "123", Saved: proto.Bool(false)}, now); err != nil {
		t.Fatal(err)
	}
}

func TestAlertSaveSourceValidation(t *testing.T) {
	now := time.Now()
	valid := func() *v1.SavedListingChange {
		return &v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: "123", Saved: proto.Bool(true), SavedAt: timestamppb.New(now),
			Snapshot:    &v1.SavedListingSnapshot{FacebookListingId: "123", Title: proto.String("Desk"), CardObservedAt: timestamppb.New(now)},
			AlertSource: &v1.ListingAlertSaveSource{AlertId: uuid.NewString(), NotificationId: proto.String(uuid.NewString()), Source: "alerts_tab"}}
	}
	if err := validateListingChange(valid(), now); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*v1.SavedListingChange){
		func(c *v1.SavedListingChange) { c.AlertSource.AlertId = "invalid" },
		func(c *v1.SavedListingChange) { c.AlertSource.NotificationId = proto.String("invalid") },
		func(c *v1.SavedListingChange) { c.AlertSource.Source = "unknown" },
		func(c *v1.SavedListingChange) { c.AlertSource.Source = "creation" },
		func(c *v1.SavedListingChange) { c.AlertSource.Source = "search" },
		func(c *v1.SavedListingChange) { c.AlertSource.Source = "search_history" },
		func(c *v1.SavedListingChange) { c.Saved = nil },
		func(c *v1.SavedListingChange) { c.Saved = proto.Bool(false); c.Snapshot = nil },
	} {
		c := valid()
		mutate(c)
		if validateListingChange(c, now) == nil {
			t.Fatal("accepted invalid save attribution")
		}
	}
	for _, source := range []string{"creation", "search", "search_history"} {
		c := valid()
		c.AlertSource.Source = source
		c.AlertSource.NotificationId = nil
		if err := validateListingChange(c, now); err != nil {
			t.Fatalf("%s: %v", source, err)
		}
	}
}

func TestStructuredListingPriceValidation(t *testing.T) {
	now := time.Now()
	valid := func() *v1.SavedListingChange {
		return &v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: "123", Snapshot: &v1.SavedListingSnapshot{
			FacebookListingId: "123", PriceText: proto.String("CA$1234.56"), PriceAmountDecimal: proto.String("1234.56"),
			PriceCurrencyCode: proto.String("CAD"), PriceObservedAt: timestamppb.New(now),
		}}
	}
	if err := validateListingChange(valid(), now); err != nil {
		t.Fatal(err)
	}
	for _, amount := range []string{"-1", "1,234.56", "1e3", "NaN", "1.234", "01", "9999999999999999999", ""} {
		c := valid()
		c.Snapshot.PriceAmountDecimal = proto.String(amount)
		if validateListingChange(c, now) == nil {
			t.Fatalf("accepted invalid decimal %q", amount)
		}
	}
	for _, code := range []string{"$", "cad", "USDD", ""} {
		c := valid()
		c.Snapshot.PriceCurrencyCode = proto.String(code)
		if validateListingChange(c, now) == nil {
			t.Fatalf("accepted invalid code %q", code)
		}
	}
	c := valid()
	c.Snapshot.PriceObservedAt = nil
	if validateListingChange(c, now) == nil {
		t.Fatal("accepted price without freshness")
	}
	c = valid()
	c.Snapshot.PriceText = nil
	if validateListingChange(c, now) == nil {
		t.Fatal("accepted detached price metadata")
	}
	c = valid()
	c.Snapshot.OriginalPriceAmountDecimal = proto.String("20")
	if validateListingChange(c, now) == nil {
		t.Fatal("accepted detached original amount")
	}
	c = valid()
	c.Snapshot.PriceCurrencyCode = nil
	c.Snapshot.PriceAmountDecimal = proto.String("0")
	if err := validateListingChange(c, now); err != nil {
		t.Fatal("unknown currency and zero are valid", err)
	}
}

func TestListingPriceMetadataFollowsPriceFreshness(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	snapshot := &v1.SavedListingSnapshot{}
	ages := map[string]time.Time{}
	source := &v1.SavedListingSnapshot{FacebookListingId: "123", PriceText: proto.String("CA$12.50"),
		PriceAmountDecimal: proto.String("12.50"), PriceCurrencyCode: proto.String("CAD"),
		OriginalPriceText: proto.String("CA$15.99"), OriginalPriceAmountDecimal: proto.String("15.99"),
		PriceObservedAt: timestamppb.New(now)}
	mergeListingSnapshot(snapshot, source, ages)
	if snapshot.GetPriceAmountDecimal() != "12.50" || snapshot.GetPriceCurrencyCode() != "CAD" || snapshot.GetOriginalPriceAmountDecimal() != "15.99" {
		t.Fatal(snapshot)
	}
	older := proto.Clone(source).(*v1.SavedListingSnapshot)
	older.PriceCurrencyCode = proto.String("USD")
	older.PriceAmountDecimal = proto.String("999")
	older.PriceObservedAt = timestamppb.New(now.Add(-time.Hour))
	mergeListingSnapshot(snapshot, older, ages)
	if snapshot.GetPriceCurrencyCode() != "CAD" || snapshot.GetPriceAmountDecimal() != "12.50" {
		t.Fatal("older price replaced newer metadata", snapshot)
	}
	// An old app can refresh text, but cannot leave a stale amount or currency.
	legacy := &v1.SavedListingSnapshot{FacebookListingId: "123", PriceText: proto.String("$20"), PriceObservedAt: timestamppb.New(now.Add(time.Hour))}
	mergeListingSnapshot(snapshot, legacy, ages)
	if snapshot.GetPriceText() != "$20" || snapshot.PriceAmountDecimal != nil || snapshot.PriceCurrencyCode != nil || snapshot.OriginalPriceAmountDecimal != nil {
		t.Fatal("stale metadata survived", snapshot)
	}
	mergeListingSnapshot(snapshot, source, ages)
	if snapshot.PriceAmountDecimal != nil || snapshot.PriceCurrencyCode != nil {
		t.Fatal("old retry restored cleared metadata", snapshot)
	}
}

func TestPriceCurrencyChangeCannotMixNewerOriginalWithOlderCurrent(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	snapshot := &v1.SavedListingSnapshot{}
	ages := map[string]time.Time{}
	mergeListingSnapshot(snapshot, &v1.SavedListingSnapshot{FacebookListingId: "123", PriceText: proto.String("CAD10"), PriceAmountDecimal: proto.String("10"), PriceCurrencyCode: proto.String("CAD"), PriceObservedAt: timestamppb.New(now)}, ages)
	mergeListingSnapshot(snapshot, &v1.SavedListingSnapshot{FacebookListingId: "123", OriginalPriceText: proto.String("CAD20"), OriginalPriceAmountDecimal: proto.String("20"), PriceObservedAt: timestamppb.New(now.Add(2 * time.Hour))}, ages)
	mergeListingSnapshot(snapshot, &v1.SavedListingSnapshot{FacebookListingId: "123", PriceText: proto.String("USD15"), PriceAmountDecimal: proto.String("15"), PriceCurrencyCode: proto.String("USD"), PriceObservedAt: timestamppb.New(now.Add(time.Hour))}, ages)
	if snapshot.GetPriceCurrencyCode() != "CAD" || snapshot.GetOriginalPriceText() != "CAD20" {
		t.Fatal("older currency mixed with newer original price", snapshot)
	}
}
