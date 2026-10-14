-- name: UpsertFacebookSeller :one
INSERT INTO facebook_sellers (id, name, photo_url, joined_text, rating, rating_count, is_highly_rated)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    photo_url = COALESCE(EXCLUDED.photo_url, facebook_sellers.photo_url),
    joined_text = COALESCE(EXCLUDED.joined_text, facebook_sellers.joined_text),
    rating = COALESCE(EXCLUDED.rating, facebook_sellers.rating),
    rating_count = COALESCE(EXCLUDED.rating_count, facebook_sellers.rating_count),
    is_highly_rated = COALESCE(EXCLUDED.is_highly_rated, facebook_sellers.is_highly_rated),
    updated_at = CURRENT_TIMESTAMP
RETURNING *;

-- name: FollowSeller :exec
INSERT INTO seller_follows (user_id, seller_id) VALUES ($1, $2)
ON CONFLICT (user_id, seller_id) DO NOTHING;

-- name: UnfollowSeller :exec
DELETE FROM seller_follows WHERE user_id = $1 AND seller_id = $2;

-- name: ListFollowedSellers :many
SELECT s.* FROM seller_follows f
JOIN facebook_sellers s ON s.id = f.seller_id
WHERE f.user_id = $1 AND f.seller_id > sqlc.arg('after_id')::text
ORDER BY f.seller_id
LIMIT sqlc.arg('page_limit')::integer;

-- name: DeleteSellerFollowsForUser :exec
DELETE FROM seller_follows WHERE user_id = $1;

-- name: LockSellerFollowUser :one
-- Serialize with account deletion, which soft-deletes users rather than
-- removing the row (and therefore does not fire the foreign-key cascade).
SELECT id FROM users WHERE id = $1 AND deleted_at IS NULL FOR UPDATE;
