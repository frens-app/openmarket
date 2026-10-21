-- name: RecordUserListingClick :exec
INSERT INTO user_listing_clicks (
    user_id, listing_id, first_clicked_at, first_clicked_from,
    last_clicked_at, last_clicked_from, click_count
)
VALUES (sqlc.arg(user_id), sqlc.arg(listing_id), sqlc.arg(clicked_at)::timestamptz, sqlc.arg(referrer)::text,
    sqlc.arg(clicked_at)::timestamptz, sqlc.arg(referrer)::text, 1)
ON CONFLICT (user_id, listing_id) DO UPDATE SET
    first_clicked_from = CASE WHEN EXCLUDED.first_clicked_at < user_listing_clicks.first_clicked_at
        THEN EXCLUDED.first_clicked_from ELSE user_listing_clicks.first_clicked_from END,
    first_clicked_at = LEAST(user_listing_clicks.first_clicked_at, EXCLUDED.first_clicked_at),
    last_clicked_from = CASE WHEN EXCLUDED.last_clicked_at > user_listing_clicks.last_clicked_at
        THEN EXCLUDED.last_clicked_from ELSE user_listing_clicks.last_clicked_from END,
    last_clicked_at = GREATEST(user_listing_clicks.last_clicked_at, EXCLUDED.last_clicked_at),
    click_count = user_listing_clicks.click_count + 1;

-- name: DeleteListingClicksForUser :exec
DELETE FROM user_listing_clicks WHERE user_id = $1;
