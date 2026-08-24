-- +goose Up

-- Attribution for submitted data, without a browsing history.
--
-- Two records, and neither one alone is a profile. observation_batches knows
-- what was submitted and carries a pseudonym; device_activity and
-- device_reputation know which install and how much, and hold no listing ids
-- and no content. Nothing joins them, and after an epoch key is deleted nothing
-- can (docs/ingest-attribution.md §4).

-- One random key per epoch, and it is deleted rather than aged out of use.
--
-- Deriving these from a master secret would be less to operate and would defeat
-- the purpose: a derived key is recomputable forever, so no observation would
-- ever actually become unlinkable. Deleting the row is the operation that makes
-- the privacy claim true.
--
-- Rotation and deletion are separate events. A key stops minting at the end of
-- its epoch and stays readable through expires_at, because a poisoned batch is
-- usually noticed days after it lands and the question then is which install
-- sent it.
CREATE TABLE ingest_epoch_keys (
    epoch date PRIMARY KEY,
    key bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamptz NOT NULL,

    CONSTRAINT ingest_epoch_keys_key_length CHECK (octet_length(key) = 32)
);

CREATE INDEX ingest_epoch_keys_expires_at_idx ON ingest_epoch_keys (expires_at);

CREATE TYPE ingest_trust_tier AS ENUM ('probation', 'normal', 'trusted');

-- How good this install's data is. Counters and a tier, and nothing about what
-- it looked at.
--
-- Keyed on the real device rather than a pseudonym on purpose: trust must not
-- rotate weekly, or a submitter poisoning the corpus resets by waiting. The
-- ingest handler reads the tier and stamps it onto the batch as a snapshot, so
-- the reconciler never joins back here.
CREATE TABLE device_reputation (
    device_id uuid PRIMARY KEY REFERENCES user_devices (id) ON DELETE CASCADE,
    batches_accepted bigint NOT NULL DEFAULT 0,
    cards_accepted bigint NOT NULL DEFAULT 0,
    cards_quarantined bigint NOT NULL DEFAULT 0,
    conflicts_caused bigint NOT NULL DEFAULT 0,
    tier ingest_trust_tier NOT NULL DEFAULT 'normal',
    first_seen_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Volume, per install per day. This is what rate limiting and "one install is
-- flooding us" read, and it is why the epoch grain can be short without
-- weakening either: neither question involves content, so neither needs the
-- pseudonym or the key.
CREATE TABLE device_activity (
    device_id uuid NOT NULL REFERENCES user_devices (id) ON DELETE CASCADE,
    day date NOT NULL,
    batches int NOT NULL DEFAULT 0,
    cards int NOT NULL DEFAULT 0,
    PRIMARY KEY (device_id, day)
);

CREATE INDEX device_activity_day_idx ON device_activity (day);

-- +goose Down
DROP TABLE IF EXISTS device_activity;
DROP TABLE IF EXISTS device_reputation;
DROP TYPE IF EXISTS ingest_trust_tier;
DROP TABLE IF EXISTS ingest_epoch_keys;
