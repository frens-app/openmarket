-- name: CreateSession :one
INSERT INTO user_sessions (
    user_id,
    refresh_token_hash,
    refresh_token_expires_at,
    device_platform
)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: CheckActiveSession :one
-- Called on every authenticated RPC. Returns the session id or no rows; the
-- interceptor treats no-rows as unauthenticated so a revoked session stops
-- working immediately rather than at access-token expiry.
SELECT s.id
FROM user_sessions s
JOIN users u ON u.id = s.user_id
WHERE s.id = $1
  AND s.user_id = $2
  AND s.revoked_at IS NULL
  AND u.deleted_at IS NULL;

-- name: GetSessionByRefreshTokenHash :one
SELECT s.*
FROM user_sessions s
JOIN users u ON u.id = s.user_id
WHERE s.refresh_token_hash = $1
  AND s.revoked_at IS NULL
  AND s.refresh_token_expires_at > CURRENT_TIMESTAMP
  AND u.deleted_at IS NULL;

-- name: RotateRefreshToken :one
-- Rotation is a conditional update on the *old* hash, which makes it the
-- concurrency control: two clients racing a refresh with the same token both
-- run this, and only the first matches a row. The loser gets no rows and is
-- told to re-authenticate rather than both being handed live sessions.
UPDATE user_sessions
SET refresh_token_hash = $2,
    refresh_token_expires_at = $3,
    last_used_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE refresh_token_hash = $1
  AND revoked_at IS NULL
RETURNING *;

-- name: RevokeSession :exec
UPDATE user_sessions
SET revoked_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1
  AND user_id = $2
  AND revoked_at IS NULL;

-- name: RevokeAllSessionsForUser :exec
UPDATE user_sessions
SET revoked_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE user_id = $1
  AND revoked_at IS NULL;
