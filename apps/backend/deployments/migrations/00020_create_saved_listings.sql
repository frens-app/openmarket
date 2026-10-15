-- +goose Up
CREATE TABLE listings (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    facebook_listing_id text NOT NULL UNIQUE CHECK (facebook_listing_id ~ '^[0-9]{1,64}$'),
    -- Validated SavedListingSnapshot protobuf JSON. Field freshness is stored
    -- separately so a partial upload cannot advance the age of absent fields.
    snapshot jsonb NOT NULL DEFAULT '{}',
    field_observed_at jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE saved_listings (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    listing_id uuid NOT NULL REFERENCES listings(id),
    saved_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, listing_id)
);
CREATE INDEX saved_listings_listing_id_idx ON saved_listings(listing_id);

-- Retry receipts are not observation history. Keep them for the account's
-- lifetime: an old offline retry must not replay a save after a later removal.
CREATE TABLE saved_listing_mutations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mutation_id uuid NOT NULL,
    request_hash bytea NOT NULL,
    PRIMARY KEY (user_id, mutation_id)
);

-- +goose Down
DROP TABLE saved_listing_mutations;
DROP TABLE saved_listings;
DROP TABLE listings;
