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
