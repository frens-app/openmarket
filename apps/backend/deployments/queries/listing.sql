-- name: GetListingByFacebookID :one
SELECT * FROM listings
WHERE origin = 'facebook' AND facebook_listing_id = $1;

-- name: GetListingByCoverPhotoFBID :one
SELECT * FROM listings
WHERE origin = 'facebook' AND cover_photo_fbid = $1;

-- name: LockListing :one
-- The merge reads the current row, decides per field group, and writes once.
-- Two devices observing one listing at the same moment must not interleave
-- inside that, or a partial observation can erase a richer fact it never saw.
SELECT * FROM listings WHERE id = $1 FOR UPDATE;

-- name: CreateFacebookListing :one
INSERT INTO listings (origin, facebook_listing_id, cover_photo_fbid, first_observed_at, last_observed_at)
VALUES ('facebook', $1, $2, $3, $3)
ON CONFLICT DO NOTHING
RETURNING *;

-- name: AttachListingAliases :one
-- An observation joined by one alias and carrying the other attaches it. A
-- disagreement is never resolved here: the caller checks first and quarantines,
-- because last-writer-wins on an alias silently merges two listings.
UPDATE listings
SET facebook_listing_id = COALESCE(facebook_listing_id, sqlc.narg('facebook_listing_id')),
    cover_photo_fbid = COALESCE(cover_photo_fbid, sqlc.narg('cover_photo_fbid')),
    updated_at = CURRENT_TIMESTAMP
WHERE id = sqlc.arg('id')
RETURNING *;

-- name: UpdateListingFromObservation :one
-- Every mergeable column, written once. The decisions are made in Go — which
-- source outranks which for a field, whether a value is richer than the one
-- already stored — because they are conditional per field group and a SQL
-- expression that encoded them would be unreadable and untestable.
UPDATE listings
SET title = sqlc.narg('title'),
    description = sqlc.narg('description'),
    condition = sqlc.narg('condition'),
    category_path = sqlc.narg('category_path'),
    facebook_category_id = sqlc.narg('facebook_category_id'),
    price_minor = sqlc.narg('price_minor'),
    price_currency = sqlc.narg('price_currency'),
    price_formatted = sqlc.narg('price_formatted'),
    previous_price_minor = sqlc.narg('previous_price_minor'),
    price_changed_at = sqlc.narg('price_changed_at'),
    price_observed_at = sqlc.narg('price_observed_at'),
    availability = sqlc.arg('availability'),
    availability_raw = sqlc.narg('availability_raw'),
    availability_observed_at = sqlc.narg('availability_observed_at'),
    sold_not_before = sqlc.narg('sold_not_before'),
    sold_not_after = sqlc.narg('sold_not_after'),
    delivery_types = sqlc.narg('delivery_types'),
    listing_location_text = sqlc.narg('listing_location_text'),
    listing_city = sqlc.narg('listing_city'),
    listing_region = sqlc.narg('listing_region'),
    listing_country = sqlc.narg('listing_country'),
    facebook_place_id = sqlc.narg('facebook_place_id'),
    listing_approx_lat = sqlc.narg('listing_approx_lat'),
    listing_approx_lon = sqlc.narg('listing_approx_lon'),
    seller_id = sqlc.narg('seller_id'),
    listed_at = sqlc.narg('listed_at'),
    listed_at_text = sqlc.narg('listed_at_text'),
    listed_at_precision = sqlc.narg('listed_at_precision'),
    first_observed_at = sqlc.narg('first_observed_at'),
    last_observed_at = sqlc.narg('last_observed_at'),
    detail_observed_at = sqlc.narg('detail_observed_at'),
    updated_at = CURRENT_TIMESTAMP
WHERE id = sqlc.arg('id')
RETURNING *;

-- name: UpsertSeller :one
-- The exact profile id is Facebook's stable seller identity. It is intentionally
-- stored even though it may require a signed-in surface to observe; see the
-- documented data-minimization preference and exception.
--
-- COALESCE in that order fills gaps without erasing: a capture that could not
-- see the seller section passes NULL and leaves what is already known alone.
INSERT INTO sellers (facebook_profile_id, display_name, rating, joined_text, joined_year,
                     rating_count, highly_rated, first_observed_at, last_observed_at)
VALUES (sqlc.arg('facebook_profile_id'), sqlc.narg('display_name'), sqlc.narg('rating'),
        sqlc.narg('joined_text'), sqlc.narg('joined_year'), sqlc.narg('rating_count'),
        sqlc.narg('highly_rated'), sqlc.arg('observed_at'), sqlc.arg('observed_at'))
ON CONFLICT (facebook_profile_id) WHERE facebook_profile_id IS NOT NULL DO UPDATE
SET display_name = COALESCE(EXCLUDED.display_name, sellers.display_name),
    rating = COALESCE(EXCLUDED.rating, sellers.rating),
    joined_text = COALESCE(EXCLUDED.joined_text, sellers.joined_text),
    joined_year = COALESCE(EXCLUDED.joined_year, sellers.joined_year),
    rating_count = COALESCE(EXCLUDED.rating_count, sellers.rating_count),
    highly_rated = COALESCE(EXCLUDED.highly_rated, sellers.highly_rated),
    last_observed_at = GREATEST(sellers.last_observed_at, EXCLUDED.last_observed_at),
    updated_at = CURRENT_TIMESTAMP
RETURNING *;

-- name: UpsertListingMedia :exec
-- An fbcdn URL is an expiring locator, so the same photo id arriving with a new
-- URL refreshes the locator and nothing else. A new photo id inserts.
INSERT INTO listing_media (listing_id, facebook_photo_id, position, last_source_url, last_source_url_at, first_observed_at, last_observed_at)
VALUES ($1, $2, $3, $4, $5, $5, $5)
ON CONFLICT (listing_id, facebook_photo_id) WHERE facebook_photo_id IS NOT NULL
DO UPDATE
SET position = COALESCE(EXCLUDED.position, listing_media.position),
    last_source_url = COALESCE(EXCLUDED.last_source_url, listing_media.last_source_url),
    last_source_url_at = GREATEST(listing_media.last_source_url_at, EXCLUDED.last_source_url_at),
    last_observed_at = GREATEST(listing_media.last_observed_at, EXCLUDED.last_observed_at);

-- name: DeleteListingMediaNotIn :execrows
-- Only a settled item-page capture may shrink a gallery. A search card carries
-- one cover photo and a partial detail read carries whatever had loaded, so
-- either would delete most of a listing's photos on every pass.
DELETE FROM listing_media
WHERE listing_id = sqlc.arg('listing_id')
  AND facebook_photo_id IS NOT NULL
  AND NOT (facebook_photo_id = ANY (sqlc.arg('keep')::text[]));

-- name: ListListingMedia :many
SELECT * FROM listing_media WHERE listing_id = $1 ORDER BY position NULLS LAST, first_observed_at;

-- name: CreateUnresolvedSeller :one
-- A seller observed without Facebook's profile id: mobile item pages publish
-- the name and rating and no profile link at all. The row is deliberately not
-- clustered — data-model.md §4 forbids grouping on (name, coordinate), because
-- a listing's coordinate is not a seller's and names are not identities.
INSERT INTO sellers (display_name, rating, joined_text, joined_year, rating_count,
                     highly_rated, first_observed_at, last_observed_at)
VALUES (sqlc.narg('display_name'), sqlc.narg('rating'), sqlc.narg('joined_text'),
        sqlc.narg('joined_year'), sqlc.narg('rating_count'), sqlc.narg('highly_rated'),
        sqlc.arg('observed_at'), sqlc.arg('observed_at'))
RETURNING *;

-- name: UpdateSellerFields :one
-- Fills gaps on a seller we already have. COALESCE in this order so a capture
-- that could not see the section leaves what is known alone.
UPDATE sellers
SET display_name = COALESCE(sqlc.narg('display_name'), display_name),
    rating = COALESCE(sqlc.narg('rating'), rating),
    joined_text = COALESCE(sqlc.narg('joined_text'), joined_text),
    joined_year = COALESCE(sqlc.narg('joined_year'), joined_year),
    rating_count = COALESCE(sqlc.narg('rating_count'), rating_count),
    highly_rated = COALESCE(sqlc.narg('highly_rated'), highly_rated),
    last_observed_at = GREATEST(last_observed_at, sqlc.arg('observed_at')),
    updated_at = CURRENT_TIMESTAMP
WHERE id = sqlc.arg('id')
RETURNING *;

-- name: ClaimFacebookProfileID :one
-- Promotes an unresolved seller when a capture finally supplies the profile id.
-- DO NOTHING on conflict: another row already holds that key, and merging two
-- seller histories on a first sighting is a guess, so the caller repoints the
-- listing instead.
UPDATE sellers
SET facebook_profile_id = sqlc.arg('facebook_profile_id'),
    updated_at = CURRENT_TIMESTAMP
WHERE sellers.id = sqlc.arg('id')
  AND sellers.facebook_profile_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM sellers s2 WHERE s2.facebook_profile_id = sqlc.arg('facebook_profile_id'))
RETURNING *;
