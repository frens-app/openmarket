-- +goose Up
ALTER TABLE users ADD COLUMN facebook_last_connected_at timestamptz;

UPDATE users u
SET facebook_last_connected_at = d.last_connected_at
FROM (
    SELECT user_id, MAX(facebook_connected_at) AS last_connected_at
    FROM user_devices
    GROUP BY user_id
) d
WHERE u.id = d.user_id AND u.deleted_at IS NULL;

-- +goose Down
ALTER TABLE users DROP COLUMN facebook_last_connected_at;
