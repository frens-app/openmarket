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
-- Partial update: a NULL argument leaves the column alone. Callers that want to
-- clear display_name pass the empty string, which the service maps to NULL
-- before it gets here.
UPDATE users
SET
    display_name = COALESCE(sqlc.narg('display_name'), display_name),
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

-- name: ClearUserDisplayName :one
UPDATE users
SET display_name = NULL,
    updated_at = CURRENT_TIMESTAMP
WHERE id = $1
  AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteUser :exec
UPDATE users
SET deleted_at = CURRENT_TIMESTAMP,
    -- The phone number is the account. Nulling the profile here without
    -- releasing the auth method would leave the number permanently unusable for
    -- a new signup, so DeleteAccount removes the auth-method row in the same
    -- transaction.
    display_name = NULL,
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
-- Releases a number whose user row is gone, so signing up again works instead
-- of hitting the primary key.
DELETE FROM user_auth_methods
WHERE auth_service = $1
  AND subject = $2;

-- name: GetPhoneNumberForUser :one
SELECT subject
FROM user_auth_methods
WHERE user_id = $1
  AND auth_service = 'PHONE';
