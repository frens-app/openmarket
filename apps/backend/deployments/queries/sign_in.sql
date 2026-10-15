-- name: CreateSignInChallenge :exec
INSERT INTO sign_in_challenges (nonce_hash, auth_service, install_id)
VALUES ($1, $2, $3);

-- name: ConsumeSignInChallenge :one
DELETE FROM sign_in_challenges
WHERE nonce_hash = $1 AND auth_service = $2 AND install_id = $3
  AND expires_at > CURRENT_TIMESTAMP
  AND linking_session_id IS NULL
RETURNING nonce_hash;

-- name: CreateLinkSignInChallenge :exec
INSERT INTO sign_in_challenges (nonce_hash, auth_service, install_id, linking_session_id)
VALUES ($1, $2, $3, $4);

-- name: ConsumeLinkSignInChallenge :one
DELETE FROM sign_in_challenges
WHERE nonce_hash = $1 AND auth_service = $2 AND linking_session_id = $3
  AND expires_at > CURRENT_TIMESTAMP
RETURNING nonce_hash;

-- name: PruneSignInChallenges :exec
DELETE FROM sign_in_challenges WHERE expires_at <= CURRENT_TIMESTAMP;

-- name: LockAuthIdentity :exec
-- Serializes first sign-ins for one identity across server instances.
SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0));
