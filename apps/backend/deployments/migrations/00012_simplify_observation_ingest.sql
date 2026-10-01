-- +goose Up

-- Volatile facts need their own clocks. last_observed_at belongs to the row and
-- can advance on a partial snapshot that carried neither price nor availability.
ALTER TABLE listings
    ADD COLUMN price_observed_at timestamptz,
    ADD COLUMN availability_observed_at timestamptz;

-- Preserve the ordering boundary for rows written by the earlier ingest code.
-- last_observed_at is conservative when a partial snapshot arrived later, but
-- conservatism is preferable to letting an old queued value overwrite it once.
UPDATE listings
SET price_observed_at = last_observed_at
WHERE price_minor IS NOT NULL;

UPDATE listings
SET availability_observed_at = last_observed_at
WHERE availability <> 'unknown';

-- Query identity and absence inference are intentionally outside snapshot
-- ingest. A public hash of a low-entropy search term is dictionary-reversible.
DROP INDEX IF EXISTS observation_batches_query_idx;
ALTER TABLE observation_batches DROP COLUMN query_fingerprint;

-- +goose Down
ALTER TABLE observation_batches ADD COLUMN query_fingerprint bytea;
CREATE INDEX observation_batches_query_idx
    ON observation_batches (query_fingerprint, received_at DESC)
    WHERE query_fingerprint IS NOT NULL;

ALTER TABLE listings
    DROP COLUMN availability_observed_at,
    DROP COLUMN price_observed_at;
