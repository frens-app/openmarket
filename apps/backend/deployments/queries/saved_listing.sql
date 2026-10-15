-- name: LockSavedListingUser :one
SELECT id FROM users WHERE id = $1 AND deleted_at IS NULL FOR UPDATE;

-- name: GetSavedListingMutation :one
SELECT request_hash FROM saved_listing_mutations WHERE user_id = $1 AND mutation_id = $2;

-- name: RecordSavedListingMutation :exec
INSERT INTO saved_listing_mutations (user_id, mutation_id, request_hash) VALUES ($1, $2, $3);

-- name: EnsureListing :exec
INSERT INTO listings (facebook_listing_id) VALUES ($1) ON CONFLICT DO NOTHING;

-- name: LockListing :one
SELECT * FROM listings WHERE facebook_listing_id = $1 FOR UPDATE;

-- name: UpdateListingSnapshot :exec
UPDATE listings SET snapshot = $2, field_observed_at = $3, updated_at = CURRENT_TIMESTAMP WHERE id = $1;

-- name: SaveListing :exec
INSERT INTO saved_listings (user_id, listing_id, saved_at) VALUES ($1, $2, $3)
ON CONFLICT (user_id, listing_id) DO NOTHING;

-- name: RemoveSavedListing :exec
DELETE FROM saved_listings WHERE user_id = $1 AND listing_id IN
    (SELECT id FROM listings WHERE facebook_listing_id = $2);

-- name: ListSavedListings :many
SELECT l.id, l.snapshot, s.saved_at FROM saved_listings s
JOIN listings l ON l.id = s.listing_id
WHERE s.user_id = $1 AND l.facebook_listing_id > sqlc.arg('after_id')::text
ORDER BY l.facebook_listing_id LIMIT sqlc.arg('page_limit')::integer;

-- name: DeleteSavedListingsForUser :exec
DELETE FROM saved_listings WHERE user_id = $1;

-- name: DeleteSavedListingMutationsForUser :exec
DELETE FROM saved_listing_mutations WHERE user_id = $1;
