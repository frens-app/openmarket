-- name: GetIngestEpochKey :one
SELECT * FROM ingest_epoch_keys WHERE epoch = $1;

-- name: CreateIngestEpochKey :one
-- Get-or-create in one statement. Two instances minting the first pseudonym of
-- an epoch at the same moment must end up with the same key, or the two halves
-- of that epoch would never compare equal.
INSERT INTO ingest_epoch_keys (epoch, key, expires_at)
VALUES ($1, $2, $3)
ON CONFLICT (epoch) DO UPDATE SET epoch = EXCLUDED.epoch
RETURNING *;

-- name: DeleteExpiredIngestEpochKeys :execrows
-- The operation that makes the privacy claim true. Deliberately a hard delete:
-- a key kept "just in case" is a key that still resolves.
DELETE FROM ingest_epoch_keys WHERE expires_at <= CURRENT_TIMESTAMP;

-- name: GetOrCreateDeviceReputation :one
INSERT INTO device_reputation (device_id)
VALUES ($1)
ON CONFLICT (device_id) DO UPDATE
SET last_seen_at = CURRENT_TIMESTAMP
RETURNING *;

-- name: RecordBatchOutcome :exec
UPDATE device_reputation
SET batches_accepted = batches_accepted + 1,
    cards_accepted = cards_accepted + sqlc.arg('accepted')::bigint,
    cards_quarantined = cards_quarantined + sqlc.arg('quarantined')::bigint,
    conflicts_caused = conflicts_caused + sqlc.arg('conflicts')::bigint,
    last_seen_at = CURRENT_TIMESTAMP
WHERE device_id = sqlc.arg('device_id');

-- name: SetDeviceTrustTier :exec
UPDATE device_reputation SET tier = $2 WHERE device_id = $1;

-- name: BumpDeviceActivity :one
-- The volume half of the split. No listing ids reach this table, which is why
-- rate limiting can read the real device id without reading a history.
INSERT INTO device_activity (device_id, day, batches, cards)
VALUES ($1, CURRENT_DATE, 1, sqlc.arg('cards')::int)
ON CONFLICT (device_id, day) DO UPDATE
SET batches = device_activity.batches + 1,
    cards = device_activity.cards + EXCLUDED.cards
RETURNING *;

-- name: PruneDeviceActivity :execrows
DELETE FROM device_activity WHERE day < (CURRENT_DATE - sqlc.arg('keep_days')::int);

-- name: GetSourceHealth :one
-- The circuit breaker's input: how this extractor is doing on this surface over
-- a window. Counted from batches rather than from quarantine rows so a batch
-- that was refused whole still registers.
SELECT
    COALESCE(SUM(cards_submitted), 0)::bigint AS submitted,
    COALESCE(SUM(cards_quarantined), 0)::bigint AS quarantined,
    COUNT(*)::bigint AS batches
FROM observation_batches
WHERE facebook_browser_variant = sqlc.arg('browser_variant')
  AND facebook_page_route = sqlc.arg('page_route')
  AND extraction_method = sqlc.arg('extraction_method')
  AND extractor_revision = sqlc.arg('extractor_revision')
  AND received_at > CURRENT_TIMESTAMP - sqlc.arg('window')::interval;

-- name: CountBatchesWithShapeFingerprint :one
-- A shape fingerprint nobody has seen on this surface is Facebook shipping a
-- change, and it is worth saying so whether or not anything failed to parse.
SELECT COUNT(*)::bigint AS seen
FROM observation_batches
WHERE facebook_browser_variant = sqlc.arg('browser_variant')
  AND facebook_page_route = sqlc.arg('page_route')
  AND extraction_method = sqlc.arg('extraction_method')
  AND shape_fingerprint = sqlc.arg('shape_fingerprint')
  AND received_at > CURRENT_TIMESTAMP - sqlc.arg('window')::interval;
