-- name: CreateObservationBatch :one
INSERT INTO observation_batches (
    observed_at, submitter_id, epoch, submitter_trust,
    facebook_browser_variant, facebook_page_route, extraction_method,
    facebook_authentication_state, extractor_revision, app_version, app_build,
    query_fingerprint, shape_fingerprint,
    cards_seen, cards_submitted, client_drop_reasons, suspended
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
RETURNING *;

-- name: FinalizeObservationBatch :exec
UPDATE observation_batches
SET cards_accepted = $2, cards_quarantined = $3
WHERE id = $1;

-- name: InsertListingObservation :exec
INSERT INTO listing_observations (listing_id, batch_id, observed_at, payload)
VALUES ($1, $2, $3, $4);

-- name: InsertListingChange :exec
INSERT INTO listing_changes (
    listing_id, batch_id, observed_at, price_minor, price_currency,
    availability, availability_raw, changed
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8);

-- name: InsertObservationQuarantine :exec
INSERT INTO observation_quarantine (batch_id, observation_index, reason, field_path, payload)
VALUES ($1, $2, $3, $4, $5);

-- name: CountDistinctSubmittersForListing :one
-- Independence, per docs/ingest-attribution.md §5.2: distinct submitters inside
-- one epoch. Across an epoch boundary the same device gets a new pseudonym, so
-- a cross-epoch count would read one device's own repeats as agreement.
SELECT COUNT(DISTINCT b.submitter_id)::bigint AS submitters
FROM listing_observations o
JOIN observation_batches b ON b.id = o.batch_id
WHERE o.listing_id = sqlc.arg('listing_id')
  AND b.epoch = sqlc.arg('epoch')
  AND o.observed_at > CURRENT_TIMESTAMP - sqlc.arg('window')::interval;
