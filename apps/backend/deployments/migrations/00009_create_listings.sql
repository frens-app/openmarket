-- +goose Up

-- The canonical listing, plus the two tables it owns.
--
-- These rows are a merge, not a record of any one page. What a device could see
-- is determined by the Facebook browser variant, the page route, the extraction
-- method and the Facebook authentication state, and none of those are properties
-- of a listing — they live on the batch that carried the observation
-- (docs/data-model.md §2, docs/ingest-attribution.md §2).

CREATE TYPE listing_origin AS ENUM ('facebook', 'native');

-- Facebook publishes is_sold, is_pending and is_live as three independent
-- booleans and we reconcile them to one value here. is_live is not part of that
-- derivation: it has been observed true on sold cards
-- (docs/filter-parameters.md §10).
CREATE TYPE listing_availability AS ENUM ('unknown', 'available', 'pending', 'sold');

-- How precisely we know when the listing was posted. The embedded search
-- payload carries an exact creation_time; an item page carries "Listed 3 weeks
-- ago" and nothing better. A duration derived from the second is a different
-- claim from the same duration derived from the first, so the precision has to
-- travel with the timestamp.
CREATE TYPE listed_at_precision AS ENUM ('exact', 'day', 'week', 'month');

CREATE TABLE sellers (
    id uuid PRIMARY KEY DEFAULT uuidv7(),

    -- HMAC of Facebook's /marketplace/profile/<id>, never the id itself.
    --
    -- The id is only readable with a session (docs/logged-in-findings.md §1:
    -- zero profile links signed out, three signed in), so it fails the
    -- public-visibility rule in docs/ingest-attribution.md §1. Grouping a
    -- seller's listings needs equality and not the value, and a keyed hash
    -- preserves exactly that much.
    seller_cluster_key bytea UNIQUE,

    -- Visible to an unauthenticated mobile browser, confirmed 2026-08-22.
    display_name text,
    rating real,

    -- Reputation, attached to a key that already names nobody. None of these
    -- four identifies a seller: a review count, a join year and Facebook's own
    -- badge describe how somebody trades, and the identifier they hang off is
    -- an HMAC (docs/ingest-attribution.md §1.4).
    --
    -- joined_text keeps Facebook's rendered string beside the parsed year. A
    -- year we failed to parse and a page that carried none are different facts,
    -- and only the raw value tells them apart.
    joined_text text,
    joined_year int,
    rating_count int,
    -- Facebook's rendered "Highly rated on Marketplace" designation, never
    -- derived from rating and rating_count: the threshold behind it is not
    -- published, so computing one here would put the badge on sellers Facebook
    -- does not.
    highly_rated boolean,

    first_observed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_observed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT sellers_rating_range CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5)),
    CONSTRAINT sellers_rating_count_nonnegative CHECK (rating_count IS NULL OR rating_count >= 0),
    CONSTRAINT sellers_joined_year_range CHECK (
        joined_year IS NULL OR (joined_year >= 2004 AND joined_year <= 2200)
    )
);

-- Deliberately absent: seller location, in any form. The item page publishes a
-- city and an approximate point for the **listing**, and that is not evidence of
-- where the seller lives or trades. Those values are already on listings, as
-- listing_location_text and listing_approx_lat/lon. A seller_location column
-- here would exist only to be filled from the listing's, which is the exact
-- inference docs/data-model.md §1 forbids. Add one when a surface is observed
-- publishing text explicitly associated with the seller.

CREATE TABLE listings (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    origin listing_origin NOT NULL,
    owner_id uuid REFERENCES users (id) ON DELETE SET NULL,

    facebook_listing_id text,
    -- Parsed from the fbcdn filename, and not primary_listing_photo.id — those
    -- differ in measured samples. It is the only key a mobile card has before
    -- it is opened, which is why it is an alias rather than a fallback.
    cover_photo_fbid text,

    title text,
    description text,
    condition text,
    category_path text[],
    facebook_category_id text,

    price_minor bigint,
    -- From the page's marketplace, not from the card. `listing_price` carries a
    -- decimal and a rendered string and no code at all; the search page
    -- publishes one at marketplace_settings.current_marketplace.primary_currency
    -- (docs/ingest-attribution.md §5.5).
    --
    -- price_minor is null without it, and that is not a gap to fill later with a
    -- guess: the exponent that converts major units to minor belongs to the
    -- currency, and it is zero for JPY and three for KWD.
    price_currency char(3),
    -- Facebook's rendered string. "Free", "C$40" and "$20 - $40" are all real
    -- and all lose something in the parse, so the source value is kept beside
    -- the number rather than reconstructed from it.
    price_formatted text,
    previous_price_minor bigint,
    price_changed_at timestamptz,

    availability listing_availability NOT NULL DEFAULT 'unknown',
    -- The three source booleans, joined, exactly as Facebook published them.
    availability_raw text,

    -- Sold is an interval, not an instant. Facebook publishes no sale, close or
    -- updated timestamp anywhere — creation_time is the only time field on a
    -- sold card (docs/filter-parameters.md §10). So these bracket it: the last
    -- time we observed it not sold, and the first time we observed it sold.
    --
    -- The width of that bracket is a fact about our observation cadence and not
    -- about the listing, which is why there is no single availability_changed_at
    -- column to mistake for one.
    sold_not_before timestamptz,
    sold_not_after timestamptz,

    delivery_types text[],

    listing_location_text text,
    listing_city text,
    listing_region text,
    listing_country text,
    facebook_place_id text,
    -- Facebook's approximate point for the *listing*. Never read it as the
    -- seller's home or business location (docs/data-model.md §1).
    listing_approx_lat double precision,
    listing_approx_lon double precision,

    seller_id uuid REFERENCES sellers (id) ON DELETE SET NULL,

    listed_at timestamptz,
    listed_at_text text,
    listed_at_precision listed_at_precision,

    first_observed_at timestamptz,
    last_observed_at timestamptz,
    detail_observed_at timestamptz,

    moderation_state text,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- A Facebook observation is hard-excluded from a native row and the reverse.
    -- "Fill the nulls" is not protection against cross-origin corruption.
    CONSTRAINT listings_origin_shape CHECK (
        (origin = 'facebook' AND owner_id IS NULL
            AND (facebook_listing_id IS NOT NULL OR cover_photo_fbid IS NOT NULL))
        OR
        (origin = 'native' AND owner_id IS NOT NULL
            AND facebook_listing_id IS NULL AND cover_photo_fbid IS NULL)
    ),
    -- price_minor = 0 is a real free listing and is distinct from NULL, so the
    -- floor is zero rather than one.
    CONSTRAINT listings_price_nonnegative CHECK (price_minor IS NULL OR price_minor >= 0),
    CONSTRAINT listings_sold_bracket_ordered CHECK (
        sold_not_before IS NULL OR sold_not_after IS NULL OR sold_not_before <= sold_not_after
    )
);

-- Two aliases, two partial unique indexes. Neither is the primary key: a
-- desktop card gives the listing id cheaply, a mobile card may only give the
-- photo fbid, and a native listing has neither.
CREATE UNIQUE INDEX listings_facebook_id_key
    ON listings (facebook_listing_id)
    WHERE origin = 'facebook' AND facebook_listing_id IS NOT NULL;

CREATE UNIQUE INDEX listings_cover_photo_fbid_key
    ON listings (cover_photo_fbid)
    WHERE origin = 'facebook' AND cover_photo_fbid IS NOT NULL;

CREATE INDEX listings_seller_id_idx ON listings (seller_id) WHERE seller_id IS NOT NULL;
CREATE INDEX listings_last_observed_at_idx ON listings (last_observed_at DESC);
CREATE INDEX listings_owner_id_idx ON listings (owner_id) WHERE owner_id IS NOT NULL;

CREATE TABLE listing_media (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    listing_id uuid NOT NULL REFERENCES listings (id) ON DELETE CASCADE,

    facebook_photo_id text,
    storage_key text,
    kind text NOT NULL DEFAULT 'photo',
    position int,

    -- An fbcdn URL is an expiring locator, not identity. The same photo id with
    -- a new URL is expiry and refreshes this column; a new photo id is a new
    -- photo and inserts a row (docs/ingest-attribution.md §5.6).
    last_source_url text,
    last_source_url_at timestamptz,

    first_observed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_observed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT listing_media_has_identity CHECK (
        facebook_photo_id IS NOT NULL OR storage_key IS NOT NULL
    ),
    CONSTRAINT listing_media_position_nonnegative CHECK (position IS NULL OR position >= 0)
);

CREATE UNIQUE INDEX listing_media_facebook_photo_key
    ON listing_media (listing_id, facebook_photo_id)
    WHERE facebook_photo_id IS NOT NULL;

CREATE UNIQUE INDEX listing_media_storage_key
    ON listing_media (storage_key)
    WHERE storage_key IS NOT NULL;

-- +goose Down
DROP TABLE IF EXISTS listing_media;
DROP TABLE IF EXISTS listings;
DROP TABLE IF EXISTS sellers;
DROP TYPE IF EXISTS listed_at_precision;
DROP TYPE IF EXISTS listing_availability;
DROP TYPE IF EXISTS listing_origin;
