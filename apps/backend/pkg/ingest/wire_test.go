package ingest

import (
	"bytes"
	"testing"
	"time"

	protovalidate "buf.build/go/protovalidate"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// The schema's own rules, run against a request shaped the way the iOS client
// builds one.
//
// The interceptor enforces these in production, so a client that assembles a
// request the schema refuses gets an error and no explanation of which field.
// This is the cheap version of that round trip: the field set below mirrors
// ObservationCapture and ObservationBatch, and it fails here if either drifts
// away from what the schema will accept.
func TestClientShapedRequestsSatisfyTheSchema(t *testing.T) {
	validator, err := protovalidate.New()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()

	listingID, photoID := "1054280080442808", "1105285382678938"
	placeID := "112604772073309"

	searchBatch := &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:              v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_DESKTOP,
			PageRoute:                   v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH,
			ExtractionMethod:            v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_HYBRID,
			FacebookAuthenticationState: v1.FacebookAuthenticationState_FACEBOOK_AUTHENTICATION_STATE_SIGNED_IN,
			ObservedAt:                  timestamppb.New(now),
		},
		ExtractorRevision: "desktop-2026-08-23",
		Counts: &v1.ClientExtractionCounts{
			CardsSeen:   20,
			DropReasons: []string{"card_unparseable"},
		},
		ShapeFingerprint: make([]byte, 32),
		Observations: []*v1.FacebookMarketplaceListingObservation{
			{Observation: &v1.FacebookMarketplaceListingObservation_Search{
				Search: &v1.FacebookMarketplaceSearchListingObservation{
					Key: &v1.FacebookListingKey{
						FacebookListingId: &listingID,
						CoverPhotoFbid:    &photoID,
					},
					Title: ptr("Solid oak six-drawer dresser"),
					Price: &v1.FacebookMarketplacePriceObservation{
						AmountDecimal:           ptr("40.00"),
						FormattedAmount:         ptr("$40"),
						PreviousAmountDecimal:   ptr("60.00"),
						PreviousFormattedAmount: ptr("$60"),
						CurrencyCode:            ptr("USD"),
					},
					ListingLocation: &v1.FacebookMarketplacePlaceObservation{
						DisplayText:     ptr("San Francisco, CA"),
						City:            ptr("San Francisco"),
						Region:          ptr("CA"),
						FacebookPlaceId: &placeID,
					},
					PrimaryPhoto: &v1.FacebookMarketplaceMediaObservation{
						FacebookPhotoId: &photoID,
						Url:             ptr("https://scontent.example/photo.jpg"),
						Position:        ptr(int32(0)),
					},
					ListedAt:      timestamppb.New(now.Add(-72 * time.Hour)),
					DeliveryTypes: []string{"IN_PERSON", "SHIPPING_ONSITE"},
					Availability: &v1.FacebookMarketplaceAvailabilityObservation{
						Sold: ptr(true), Pending: ptr(false), Live: ptr(true),
					},
					FacebookCategoryId: ptr("807311116002614"),
				},
			}},
		},
	}

	itemBatch := &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:              v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_DESKTOP,
			PageRoute:                   v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_ITEM,
			ExtractionMethod:            v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_HYBRID,
			FacebookAuthenticationState: v1.FacebookAuthenticationState_FACEBOOK_AUTHENTICATION_STATE_SIGNED_IN,
			ObservedAt:                  timestamppb.New(now),
		},
		ExtractorRevision: "desktop-2026-08-23",
		Counts:            &v1.ClientExtractionCounts{CardsSeen: 1},
		Observations: []*v1.FacebookMarketplaceListingObservation{
			{Observation: &v1.FacebookMarketplaceListingObservation_Detail{
				Detail: &v1.FacebookMarketplaceListingDetailObservation{
					Key:            &v1.FacebookListingKey{FacebookListingId: &listingID},
					Title:          ptr("Solid oak six-drawer dresser"),
					Description:    ptr("Barely used, one small scratch on the top."),
					Condition:      ptr("Used - Good"),
					ListedAtText:   ptr("Listed 3 weeks ago"),
					CaptureSettled: false,
					ListingLocation: &v1.FacebookMarketplacePlaceObservation{
						DisplayText: ptr("San Francisco, CA"),
						Latitude:    ptr(37.7749),
						Longitude:   ptr(-122.4194),
					},
					Media: []*v1.FacebookMarketplaceMediaObservation{
						{FacebookPhotoId: &photoID, Url: ptr("https://scontent.example/1.jpg"), Position: ptr(int32(0))},
					},
					Seller: &v1.FacebookMarketplaceSellerObservation{
						SectionStatus:     v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_OBSERVED,
						FacebookProfileId: ptr("100000123456789"),
						DisplayName:       ptr("Kelsey Jones"),
						JoinedText:        ptr("Joined Facebook in 2010"),
						JoinedYear:        ptr(int32(2010)),
						Rating:            ptr(4.8),
						RatingCount:       ptr(int32(44)),
						HighlyRated:       ptr(true),
					},
				},
			}},
		},
	}

	for name, req := range map[string]*v1.SubmitObservationsRequest{
		"search": searchBatch,
		"item":   itemBatch,
	} {
		t.Run(name, func(t *testing.T) {
			if err := validator.Validate(req); err != nil {
				t.Fatalf("the client's own shape is refused by the schema: %v", err)
			}
		})
	}
}

func TestMarshalObservationKeepsSellerID(t *testing.T) {
	profileID := "100000123456789"
	observation := &v1.FacebookMarketplaceListingObservation{
		Observation: &v1.FacebookMarketplaceListingObservation_Detail{
			Detail: &v1.FacebookMarketplaceListingDetailObservation{
				Seller: &v1.FacebookMarketplaceSellerObservation{
					FacebookProfileId: &profileID,
					DisplayName:       ptr("Public seller name"),
				},
			},
		},
	}

	payload, err := marshalObservation([]*v1.FacebookMarketplaceListingObservation{observation}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(payload, []byte(profileID)) || !bytes.Contains(payload, []byte("facebookProfileId")) {
		t.Fatalf("seller id missing from stored evidence: %s", payload)
	}
	if !bytes.Contains(payload, []byte("Public seller name")) {
		t.Fatalf("public seller fields were removed with the id: %s", payload)
	}
}
