-- +goose Up

-- What was submitted, and what we refused.
--
-- The batch is the unit of everything: one ingest call, one page, one device,
-- one moment. Provenance is written here once rather than on every card, which
-- is also what keeps a foreign key to user_devices off the observation rows —
-- that key would be a browsing record with the join already written
-- (docs/ingest-attribution.md §2.5).

CREATE TABLE observation_batches (
    id uuid PRIMARY KEY DEFAULT uuidv7(),

    -- observed_at is when the device read the live page. received_at is when we
    -- were told. They differ for a batch queued offline, and only the first one
    -- may ever be derived from cached data, which is to say never
    -- (docs/ingest-attribution.md §2.4).
    observed_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- HMAC of user_devices.id under this epoch's key, and not the device id.
    -- Stable within the epoch so corroboration can tell two submitters apart
    -- (docs/ingest-attribution.md §5.2); meaningless
    -- once the key is deleted.
    submitter_id bytea NOT NULL,
    epoch date NOT NULL,
    submitter_trust ingest_trust_tier NOT NULL,

    -- Text rather than enums: these mirror protobuf enums that gain values as
    -- Facebook's surfaces are surveyed, and a database enum would make each new
    -- route a migration before it could even be recorded.
    facebook_browser_variant text NOT NULL,
    facebook_page_route text NOT NULL,
    extraction_method text NOT NULL,
    facebook_authentication_state text NOT NULL,

    extractor_revision text NOT NULL,
    app_version text,
    app_build text,

    -- Derived from the filter parameters, never from a stored query string. Two
    -- runs of the same query share a fingerprint, which is the whole of what
    -- absence from a later run is allowed to mean
    -- (docs/ingest-attribution.md §2.2).
    query_fingerprint bytea,
    -- Hash of the key paths a structured payload carried. A fingerprint nobody
    -- has seen before, across many devices at once, is Facebook shipping a
    -- change (docs/ingest-attribution.md §3.4).
    shape_fingerprint bytea,

    -- cards_seen against cards_submitted is the only way a client-side drop is
    -- visible from here. Without it, an extractor that drops every card and a
    -- page with nothing on it are the same empty batch.
    cards_seen int NOT NULL,
    cards_submitted int NOT NULL,
    cards_accepted int NOT NULL DEFAULT 0,
    cards_quarantined int NOT NULL DEFAULT 0,
    client_drop_reasons text[] NOT NULL DEFAULT '{}',

    -- The circuit breaker was open when this arrived: stored for diagnosis,
    -- nothing merged into canonical rows (docs/ingest-attribution.md §3.3).
    suspended boolean NOT NULL DEFAULT false,

    CONSTRAINT observation_batches_counts_ordered CHECK (
        cards_seen >= cards_submitted
        AND cards_submitted >= cards_accepted + cards_quarantined
    )
);

CREATE INDEX observation_batches_submitter_idx ON observation_batches (epoch, submitter_id);
CREATE INDEX observation_batches_received_at_idx ON observation_batches (received_at DESC);
CREATE INDEX observation_batches_query_idx
    ON observation_batches (query_fingerprint, received_at DESC)
    WHERE query_fingerprint IS NOT NULL;

-- The health of one extractor on one surface, which is what the circuit breaker
-- reads and what a new shape fingerprint is measured against.
CREATE INDEX observation_batches_source_health_idx ON observation_batches (
    facebook_browser_variant,
    facebook_page_route,
    extraction_method,
    extractor_revision,
    received_at DESC
);

-- The raw evidence the reconciler consumed. Bounded retention: this exists to
-- diagnose a parser regression, and listing_changes is the durable history.
CREATE TABLE listing_observations (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    listing_id uuid NOT NULL REFERENCES listings (id) ON DELETE CASCADE,
    batch_id uuid NOT NULL REFERENCES observation_batches (id) ON DELETE CASCADE,
    observed_at timestamptz NOT NULL,
    -- The protobuf observation's JSON form, which retains field presence. An
    -- absent field and a field explicitly set empty are different facts and
    -- collapsing them would lose the distinction the whole model turns on.
    payload jsonb NOT NULL
);

CREATE INDEX listing_observations_listing_time_idx
    ON listing_observations (listing_id, observed_at DESC);
CREATE INDEX listing_observations_batch_idx ON listing_observations (batch_id);

-- The reconciled series for the two volatile fields, kept indefinitely.
--
-- observed_at is when a device saw the value, not when Facebook changed it.
-- Facebook publishes no transition timestamp at all, so no column here may be
-- read as one.
CREATE TABLE listing_changes (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    listing_id uuid NOT NULL REFERENCES listings (id) ON DELETE CASCADE,
    batch_id uuid REFERENCES observation_batches (id) ON DELETE SET NULL,
    observed_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    price_minor bigint,
    price_currency char(3),
    availability listing_availability NOT NULL,
    availability_raw text,
    -- Which fields moved: 'price', 'availability'.
    changed text[] NOT NULL
);

CREATE INDEX listing_changes_listing_time_idx
    ON listing_changes (listing_id, observed_at DESC);

CREATE TYPE observation_rejection_reason AS ENUM (
    'malformed_field',
    'implausible_value',
    'contradictory_fields',
    'key_collision',
    'route_mismatch',
    'origin_conflict',
    'alias_conflict',
    -- Nothing was wrong with the card. The breaker was open for its surface, so
    -- the batch was stored rather than merged.
    'source_suspended'
);

-- Refused cards, with the payload that failed and the gate that failed it.
--
-- Separate from listing_observations on purpose: a quarantined card has no
-- listing to hang off, and mixing the two would put unmerged data one careless
-- join away from the evidence set.
CREATE TABLE observation_quarantine (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    batch_id uuid NOT NULL REFERENCES observation_batches (id) ON DELETE CASCADE,
    observation_index int NOT NULL,
    reason observation_rejection_reason NOT NULL,
    field_path text NOT NULL DEFAULT '',
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX observation_quarantine_batch_idx ON observation_quarantine (batch_id);
CREATE INDEX observation_quarantine_reason_idx ON observation_quarantine (reason, created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS observation_quarantine;
DROP TYPE IF EXISTS observation_rejection_reason;
DROP TABLE IF EXISTS listing_changes;
DROP TABLE IF EXISTS listing_observations;
DROP TABLE IF EXISTS observation_batches;
