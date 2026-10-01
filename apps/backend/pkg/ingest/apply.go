package ingest

import (
	"context"
	"errors"
	"fmt"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// apply merges one observation into one canonical listing.
//
// A non-nil Rejection is a refusal the batch survives: the card is quarantined
// and the rest of the batch continues. An error is a failure of ours, and it
// takes the whole transaction down rather than committing a batch whose counts
// describe work that did not happen.
func (s *Service) apply(
	ctx context.Context,
	q *db.Queries,
	batch db.ObservationBatch,
	c Candidate,
	src source,
	observedAt time.Time,
	epoch time.Time,
) (*Rejection, error) {
	if d := c.Detail; d != nil {
		src.settled = d.GetCaptureSettled()
	}

	listing, rejection, err := s.resolveListing(ctx, q, c, observedAt)
	if err != nil || rejection != nil {
		return rejection, err
	}

	sellerID, err := s.resolveSeller(ctx, q, listing, c, observedAt)
	if err != nil {
		return nil, err
	}

	result := mergeListing(listing, c, src, observedAt, false)
	if result.needsCorroboration {
		// Backwards, from a source that is not an item page. Relisting is real,
		// so the transition has to be possible; a stale card resurrecting a
		// sold listing is the likelier cause and the more damaging one, so a
		// second submitter has to agree first.
		agreed, err := s.corroborated(ctx, q, listing.ID, epoch)
		if err != nil {
			return nil, err
		}
		result = mergeListing(listing, c, src, observedAt, agreed)
	}
	if sellerID != nil {
		result.params.SellerID = sellerID
	}

	updated, err := q.UpdateListingFromObservation(ctx, result.params)
	if err != nil {
		return nil, fmt.Errorf("update listing: %w", err)
	}

	if err := s.applyMedia(ctx, q, listing.ID, c, src, observedAt); err != nil {
		return nil, err
	}

	payload, err := marshalObservation([]*v1.FacebookMarketplaceListingObservation{observationOf(c)}, 0)
	if err != nil {
		return nil, err
	}
	if err := q.InsertListingObservation(ctx, db.InsertListingObservationParams{
		ListingID:  listing.ID,
		BatchID:    batch.ID,
		ObservedAt: timestamp(observedAt),
		Payload:    payload,
	}); err != nil {
		return nil, fmt.Errorf("insert observation: %w", err)
	}

	// The narrow, durable history. Written only when something moved, because a
	// row per sighting would make "when did the price change" a scan for the
	// two rows that differ.
	if len(result.changed) > 0 {
		if err := q.InsertListingChange(ctx, db.InsertListingChangeParams{
			ListingID:       listing.ID,
			BatchID:         &batch.ID,
			ObservedAt:      timestamp(observedAt),
			PriceMinor:      updated.PriceMinor,
			PriceCurrency:   updated.PriceCurrency,
			Availability:    updated.Availability,
			AvailabilityRaw: updated.AvailabilityRaw,
			Changed:         result.changed,
		}); err != nil {
			return nil, fmt.Errorf("insert change: %w", err)
		}
	}

	return nil, nil
}

// resolveListing finds the row this observation belongs to, or creates it.
//
// Two aliases can each resolve, and when they resolve to different rows the
// observation is refused rather than merged. Attaching either alias to either
// row would silently fuse two listings, and no later evidence separates them.
func (s *Service) resolveListing(
	ctx context.Context,
	q *db.Queries,
	c Candidate,
	observedAt time.Time,
) (db.Listing, *Rejection, error) {
	var byID, byPhoto *db.Listing

	if c.FacebookListingID != nil {
		row, err := q.GetListingByFacebookID(ctx, c.FacebookListingID)
		switch {
		case err == nil:
			byID = &row
		case !errors.Is(err, pgx.ErrNoRows):
			return db.Listing{}, nil, fmt.Errorf("lookup by facebook id: %w", err)
		}
	}
	if c.CoverPhotoFBID != nil {
		row, err := q.GetListingByCoverPhotoFBID(ctx, c.CoverPhotoFBID)
		switch {
		case err == nil:
			byPhoto = &row
		case !errors.Is(err, pgx.ErrNoRows):
			return db.Listing{}, nil, fmt.Errorf("lookup by cover photo: %w", err)
		}
	}

	if byID != nil && byPhoto != nil && byID.ID != byPhoto.ID {
		return db.Listing{}, &Rejection{
			Index:     c.Index,
			Reason:    v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ALIAS_CONFLICT,
			FieldPath: "key",
		}, nil
	}

	found := byID
	if found == nil {
		found = byPhoto
	}

	if found == nil {
		created, err := q.CreateFacebookListing(ctx, db.CreateFacebookListingParams{
			FacebookListingID: c.FacebookListingID,
			CoverPhotoFbid:    c.CoverPhotoFBID,
			FirstObservedAt:   timestamp(observedAt),
		})
		if errors.Is(err, pgx.ErrNoRows) {
			// Another submitter created one of these aliases after our lookup.
			// ON CONFLICT waited for that transaction; resolve again so a normal
			// first-sighting race does not abort this whole batch.
			return s.resolveListing(ctx, q, c, observedAt)
		}
		if err != nil {
			return db.Listing{}, nil, fmt.Errorf("create listing: %w", err)
		}
		return created, nil, nil
	}

	// Locked before the merge reads it. Two devices observing one listing at
	// once must not interleave inside read-decide-write, or the partial
	// observation can erase a richer fact it never saw.
	locked, err := q.LockListing(ctx, found.ID)
	if err != nil {
		return db.Listing{}, nil, fmt.Errorf("lock listing: %w", err)
	}
	if locked.Origin != db.ListingOriginFacebook {
		return db.Listing{}, &Rejection{
			Index:  c.Index,
			Reason: v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ORIGIN_CONFLICT,
		}, nil
	}

	// An observation that joined on one alias and carries the other attaches it.
	if (locked.FacebookListingID == nil && c.FacebookListingID != nil) ||
		(locked.CoverPhotoFbid == nil && c.CoverPhotoFBID != nil) {
		attached, err := q.AttachListingAliases(ctx, db.AttachListingAliasesParams{
			ID:                locked.ID,
			FacebookListingID: c.FacebookListingID,
			CoverPhotoFbid:    c.CoverPhotoFBID,
		})
		if err != nil {
			return db.Listing{}, nil, fmt.Errorf("attach aliases: %w", err)
		}
		locked = attached
	}
	return locked, nil, nil
}

// corroborated reports whether a second submitter has observed this listing
// inside the current epoch.
//
// The epoch qualifier is load-bearing. Across a boundary the same device gets a
// new pseudonym, so a window that spanned one would read a device's own repeats
// as independent agreement.
func (s *Service) corroborated(ctx context.Context, q *db.Queries, listingID uuid.UUID, epoch time.Time) (bool, error) {
	count, err := q.CountDistinctSubmittersForListing(ctx, db.CountDistinctSubmittersForListingParams{
		ListingID: listingID,
		Epoch:     pgtype.Date{Time: epoch, Valid: true},
		Window:    interval(s.limits.CorroborationWindow),
	})
	if err != nil {
		return false, fmt.Errorf("count submitters: %w", err)
	}
	return count >= 2, nil
}

func (s *Service) applyMedia(
	ctx context.Context,
	q *db.Queries,
	listingID uuid.UUID,
	c Candidate,
	src source,
	observedAt time.Time,
) error {
	plan := planMedia(listingID, c, src, observedAt)
	for _, m := range plan.upsert {
		if err := q.UpsertListingMedia(ctx, m); err != nil {
			return fmt.Errorf("upsert media: %w", err)
		}
	}
	if plan.keep == nil {
		return nil
	}
	if _, err := q.DeleteListingMediaNotIn(ctx, db.DeleteListingMediaNotInParams{
		ListingID: listingID,
		Keep:      plan.keep,
	}); err != nil {
		return fmt.Errorf("prune media: %w", err)
	}
	return nil
}

// resolveSeller writes the observed seller fields and exact Facebook profile id.
//
// Three cases, and the order matters. A capture with the profile id joins on
// that id. A capture without one — every mobile item page — updates the
// seller this listing already has, or creates an unresolved row. And when a
// identified capture finds an unresolved row already attached, it promotes
// that row rather than leaving an orphan behind.
func (s *Service) resolveSeller(
	ctx context.Context,
	q *db.Queries,
	listing db.Listing,
	c Candidate,
	observedAt time.Time,
) (*uuid.UUID, error) {
	if c.Detail == nil {
		return nil, nil
	}
	obs := sellerFrom(c.Detail.GetSeller())
	if obs == nil {
		return nil, nil
	}
	at := timestamp(observedAt)

	if obs.facebookProfileID == nil {
		if listing.SellerID == nil {
			created, err := q.CreateUnresolvedSeller(ctx, db.CreateUnresolvedSellerParams{
				DisplayName: obs.displayName,
				Rating:      obs.rating,
				JoinedText:  obs.joinedText,
				JoinedYear:  obs.joinedYear,
				RatingCount: obs.ratingCount,
				HighlyRated: obs.highlyRated,
				ObservedAt:  at,
			})
			if err != nil {
				return nil, fmt.Errorf("create seller: %w", err)
			}
			return &created.ID, nil
		}
		updated, err := q.UpdateSellerFields(ctx, db.UpdateSellerFieldsParams{
			ID:          *listing.SellerID,
			DisplayName: obs.displayName,
			Rating:      obs.rating,
			JoinedText:  obs.joinedText,
			JoinedYear:  obs.joinedYear,
			RatingCount: obs.ratingCount,
			HighlyRated: obs.highlyRated,
			ObservedAt:  at,
		})
		if err != nil {
			return nil, fmt.Errorf("update seller: %w", err)
		}
		return &updated.ID, nil
	}

	if listing.SellerID != nil {
		claimed, err := q.ClaimFacebookProfileID(ctx, db.ClaimFacebookProfileIDParams{
			ID:                *listing.SellerID,
			FacebookProfileID: obs.facebookProfileID,
		})
		switch {
		case err == nil:
			updated, err := q.UpdateSellerFields(ctx, db.UpdateSellerFieldsParams{
				ID:          claimed.ID,
				DisplayName: obs.displayName,
				Rating:      obs.rating,
				JoinedText:  obs.joinedText,
				JoinedYear:  obs.joinedYear,
				RatingCount: obs.ratingCount,
				HighlyRated: obs.highlyRated,
				ObservedAt:  at,
			})
			if err != nil {
				return nil, fmt.Errorf("update claimed seller: %w", err)
			}
			return &updated.ID, nil
		case !errors.Is(err, pgx.ErrNoRows):
			return nil, fmt.Errorf("claim seller: %w", err)
		}
		// No rows: the row is already identified, or that id belongs elsewhere.
		// Either way the upsert below is the answer, and the listing repoints.
	}

	seller, err := q.UpsertSeller(ctx, db.UpsertSellerParams{
		FacebookProfileID: obs.facebookProfileID,
		DisplayName:       obs.displayName,
		Rating:            obs.rating,
		JoinedText:        obs.joinedText,
		JoinedYear:        obs.joinedYear,
		RatingCount:       obs.ratingCount,
		HighlyRated:       obs.highlyRated,
		ObservedAt:        at,
	})
	if err != nil {
		return nil, fmt.Errorf("upsert seller: %w", err)
	}
	return &seller.ID, nil
}

func observationOf(c Candidate) *v1.FacebookMarketplaceListingObservation {
	if c.Detail != nil {
		return &v1.FacebookMarketplaceListingObservation{
			Observation: &v1.FacebookMarketplaceListingObservation_Detail{Detail: c.Detail},
		}
	}
	return &v1.FacebookMarketplaceListingObservation{
		Observation: &v1.FacebookMarketplaceListingObservation_Search{Search: c.Search},
	}
}
