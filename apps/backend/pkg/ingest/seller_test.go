package ingest

import (
	"bytes"
	"testing"

	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

func TestSellerFromKeepsReputationAndDropsTheIdentifier(t *testing.T) {
	secret := []byte("seller-key")
	obs := sellerFrom(&v1.FacebookMarketplaceSellerObservation{
		SectionStatus:     v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_OBSERVED,
		FacebookProfileId: ptr("100000123456789"),
		DisplayName:       ptr("  Kelsey Jones  "),
		Rating:            ptr(4.8),
		JoinedText:        ptr("Joined Facebook in 2010"),
		JoinedYear:        ptr(int32(2010)),
		RatingCount:       ptr(int32(44)),
		HighlyRated:       ptr(true),
	}, secret)

	if obs == nil {
		t.Fatal("an observed seller section is not nothing")
	}
	if !bytes.Equal(obs.clusterKey, ClusterKey(secret, "100000123456789")) {
		t.Fatal("the cluster key must be the keyed hash of the profile id")
	}
	if bytes.Contains(obs.clusterKey, []byte("100000123456789")) {
		t.Fatal("the profile id must not survive into the stored value")
	}
	if *obs.displayName != "Kelsey Jones" {
		t.Fatalf("display name = %q, want it trimmed", *obs.displayName)
	}
	if *obs.rating != 4.8 || *obs.ratingCount != 44 || *obs.joinedYear != 2010 || !*obs.highlyRated {
		t.Fatalf("reputation dropped: %+v", obs)
	}
	if *obs.joinedText != "Joined Facebook in 2010" {
		t.Fatalf("joined_text = %q", *obs.joinedText)
	}
}

// A capture that could not reach the seller section is not evidence that the
// listing has no seller, so it must not create or touch a row.
func TestSellerFromIgnoresAnUnreachableSection(t *testing.T) {
	for _, status := range []v1.FacebookMarketplaceSellerSectionStatus{
		v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_UNAVAILABLE,
		v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_NOT_OBSERVED,
		v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_UNSPECIFIED,
	} {
		if got := sellerFrom(&v1.FacebookMarketplaceSellerObservation{
			SectionStatus: status,
			DisplayName:   ptr("Dana Whitfield"),
		}, []byte("k")); got != nil {
			t.Fatalf("status %v produced %+v", status, got)
		}
	}
}

// Mobile item pages publish the name and rating with no profile link at all.
// That is a seller we can describe and cannot group, and both halves matter.
func TestSellerFromWithoutAProfileID(t *testing.T) {
	obs := sellerFrom(&v1.FacebookMarketplaceSellerObservation{
		SectionStatus: v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_OBSERVED,
		DisplayName:   ptr("Dana Whitfield"),
		Rating:        ptr(4.2),
	}, []byte("k"))

	if obs == nil || obs.clusterKey != nil {
		t.Fatalf("obs = %+v, want a describable seller with no grouping key", obs)
	}
	if *obs.displayName != "Dana Whitfield" || *obs.rating != 4.2 {
		t.Fatalf("obs = %+v", obs)
	}
}

// An observed section with nothing in it is still nothing to write.
func TestSellerFromEmptySection(t *testing.T) {
	if got := sellerFrom(&v1.FacebookMarketplaceSellerObservation{
		SectionStatus: v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_OBSERVED,
	}, []byte("k")); got != nil {
		t.Fatalf("got %+v", got)
	}
}
