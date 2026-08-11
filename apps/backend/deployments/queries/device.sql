-- name: UpsertDevice :one
-- Called at login. The install is the identity, so signing in again on the same
-- phone finds the existing row and keeps its Facebook and push state rather than
-- starting a second one.
INSERT INTO user_devices (user_id, install_id, platform)
VALUES ($1, $2, $3)
ON CONFLICT (user_id, install_id) DO UPDATE
SET platform = EXCLUDED.platform,
    last_seen_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
RETURNING *;

-- name: GetDeviceForSession :one
-- Every authenticated call already carries a session, and the session knows its
-- device — so the client never has to send install_id again after login, and
-- cannot claim to be a device it isn't.
SELECT d.*
FROM user_devices d
JOIN user_sessions s ON s.device_id = d.id
WHERE s.id = $1;

-- name: SetSessionDevice :exec
UPDATE user_sessions
SET device_id = $2,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1;

-- name: SetDeviceFacebookConnection :one
-- Idempotent: reporting the state it already holds leaves the timestamps alone,
-- so a client that reports on every foreground doesn't rewrite history.
UPDATE user_devices
SET facebook_connected = sqlc.arg('connected')::boolean,
    facebook_connected_at = CASE
        WHEN sqlc.arg('connected')::boolean AND NOT facebook_connected
            THEN CURRENT_TIMESTAMP
        ELSE facebook_connected_at
    END,
    facebook_disconnected_at = CASE
        WHEN NOT sqlc.arg('connected')::boolean AND facebook_connected
            THEN CURRENT_TIMESTAMP
        ELSE facebook_disconnected_at
    END,
    last_seen_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1
RETURNING *;

-- name: UpdateDevicePushToken :exec
UPDATE user_devices
SET push_token = $2,
    push_token_updated_at = CURRENT_TIMESTAMP,
    notification_permission_status = $3,
    last_seen_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1;

-- name: ClearDevicePushTokenElsewhere :exec
-- The same token can migrate between rows — one phone, two accounts. The unique
-- index would reject the new holder, so the old one is cleared first, in the
-- same transaction.
UPDATE user_devices
SET push_token = NULL,
    push_token_updated_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE push_token = $1
  AND id <> $2;
