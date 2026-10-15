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

-- name: RecordListingView :exec
UPDATE listings SET last_viewed_at = sqlc.arg(viewed_at),
    last_viewed_by = sqlc.narg(viewer)::uuid, last_view_received_at = sqlc.arg(received_at)
WHERE id = sqlc.arg(id) AND (last_view_received_at IS NULL OR last_view_received_at < sqlc.arg(received_at));

-- name: RecordListingDetailSource :exec
UPDATE listings SET last_detail_observed_at = sqlc.arg(observed_at), last_detail_source = sqlc.arg(source),
    last_detail_updated_by = sqlc.narg(observer)::uuid, last_detail_received_at = sqlc.arg(received_at)
WHERE id = sqlc.arg(id) AND (last_detail_received_at IS NULL OR last_detail_received_at < sqlc.arg(received_at));

-- name: ClearListingViewerForUser :exec
UPDATE listings SET
    last_viewed_by = CASE WHEN last_viewed_by = $1 THEN NULL ELSE last_viewed_by END,
    last_detail_updated_by = CASE WHEN last_detail_updated_by = $1 THEN NULL ELSE last_detail_updated_by END
WHERE last_viewed_by = $1 OR last_detail_updated_by = $1;
