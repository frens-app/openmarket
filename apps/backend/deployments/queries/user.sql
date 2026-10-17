-- name: CreateUser :one
INSERT INTO users (time_zone)
VALUES (sqlc.narg('time_zone'))
RETURNING *;

-- name: GetUser :one
SELECT *
FROM users
WHERE id = $1
  AND deleted_at IS NULL;

-- name: UpdateUser :one
-- Presence flags distinguish an omitted name from explicitly clearing it.
UPDATE users
SET
    display_name = CASE WHEN sqlc.arg('set_display_name')::boolean
        THEN sqlc.narg('display_name') ELSE display_name END,
    first_name = CASE WHEN sqlc.arg('set_first_name')::boolean
        THEN sqlc.narg('first_name') ELSE first_name END,
    last_name = CASE WHEN sqlc.arg('set_last_name')::boolean
        THEN sqlc.narg('last_name') ELSE last_name END,
    time_zone = COALESCE(sqlc.narg('time_zone'), time_zone),
    -- Latch: once completed, it stays completed at its original timestamp.
    onboarding_completed_at = CASE
        WHEN sqlc.narg('mark_onboarding_complete')::boolean IS TRUE
            THEN COALESCE(onboarding_completed_at, CURRENT_TIMESTAMP)
        ELSE onboarding_completed_at
    END,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1
  AND deleted_at IS NULL
RETURNING *;

-- name: FillMissingUserNames :one
UPDATE users
SET first_name = COALESCE(first_name, sqlc.narg('first_name')),
    last_name = COALESCE(last_name, sqlc.narg('last_name')),
    display_name = COALESCE(display_name, sqlc.narg('display_name')),
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1 AND deleted_at IS NULL
RETURNING *;

-- name: RecordUserFacebookConnection :exec
UPDATE users
SET facebook_last_connected_at = GREATEST(facebook_last_connected_at, sqlc.arg('connected_at')::timestamptz),
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1 AND deleted_at IS NULL
    AND (facebook_last_connected_at IS NULL OR facebook_last_connected_at < sqlc.arg('connected_at')::timestamptz);

-- name: SetUserEmail :exec
UPDATE users
SET email = sqlc.arg('email')::text,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1 AND deleted_at IS NULL
    AND email IS DISTINCT FROM sqlc.arg('email')::text;

-- name: SoftDeleteUser :exec
UPDATE users
SET deleted_at = CURRENT_TIMESTAMP,
    display_name = NULL,
    first_name = NULL,
    last_name = NULL,
    email = NULL,
    facebook_last_connected_at = NULL,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1
  AND deleted_at IS NULL;

-- name: GetAuthMethod :one
SELECT *
FROM user_auth_methods
WHERE auth_service = $1
  AND subject = $2;

-- name: CreateAuthMethod :one
INSERT INTO user_auth_methods (user_id, auth_service, subject)
VALUES ($1, $2, $3)
RETURNING *;

-- name: TouchAuthMethod :exec
UPDATE user_auth_methods
SET last_used_at = CURRENT_TIMESTAMP
WHERE auth_service = $1
  AND subject = $2;

-- name: DeleteAuthMethodsForUser :exec
DELETE FROM user_auth_methods
WHERE user_id = $1;

-- name: DeleteAuthMethodBySubject :exec
DELETE FROM user_auth_methods
WHERE auth_service = $1
  AND subject = $2;

-- name: GetAuthMethodForUser :one
SELECT * FROM user_auth_methods WHERE user_id = $1
ORDER BY CASE WHEN auth_service IN ('APPLE', 'GOOGLE') THEN 0 ELSE 1 END,
         created_at, auth_service
LIMIT 1;

-- name: LockUser :one
SELECT * FROM users WHERE id = $1 AND deleted_at IS NULL FOR UPDATE;
