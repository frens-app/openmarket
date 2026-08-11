-- name: RecordVerificationSend :exec
INSERT INTO verification_sends (created_at)
VALUES (CURRENT_TIMESTAMP);

-- name: CountVerificationSends :one
SELECT count(*)
FROM verification_sends
WHERE created_at > CURRENT_TIMESTAMP - sqlc.arg('window')::interval;

-- name: PruneVerificationSends :exec
DELETE FROM verification_sends
WHERE created_at < CURRENT_TIMESTAMP - sqlc.arg('retention')::interval;
