-- +goose Up

-- uuidv7() is a Postgres 18 builtin. Time-ordered ids keep the primary key
-- index append-only, which matters more for the tables that come later
-- (sightings, listings) than it does for these, but there is no reason to start
-- with random v4 and migrate later.

CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT uuidv7(),

    -- Nullable throughout: an account exists the moment a phone number is
    -- verified, and nothing else has been asked for yet. The onboarding screens
    -- fill these in afterwards, or don't.
    display_name text,
    time_zone text,

    -- Set by UpdateViewer once the client has walked the place + interests
    -- screens. A timestamp rather than a boolean so we can tell "finished
    -- today" from "finished at install", which is the question that gets asked
    -- of this column later.
    onboarding_completed_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- DeleteAccount soft-deletes so an in-flight session can't resurrect the
    -- row by racing the delete. A hard purge job is a separate, later problem.
    deleted_at timestamptz
);

-- Phone is the only login today. Modeled as a table of methods rather than a
-- column on users so adding Apple or Google later is an INSERT, not a
-- migration on a live users table.
CREATE TYPE auth_service AS ENUM ('PHONE');

CREATE TABLE user_auth_methods (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    auth_service auth_service NOT NULL,

    -- The unique identifier of the user within that method:
    --   PHONE -> the E.164 number, normalised, with the leading '+'.
    subject text NOT NULL,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_used_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (auth_service, subject)
);

CREATE INDEX user_auth_methods_user_id_idx ON user_auth_methods (user_id);

CREATE TYPE device_platform AS ENUM ('IOS', 'ANDROID', 'WEB');

CREATE TABLE user_sessions (
    -- Carried in the JWT as `sid`, so revoking a session invalidates its access
    -- tokens without waiting for them to expire.
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    -- Only the HMAC of the refresh token is stored. A database dump is
    -- therefore not a set of usable credentials, and the HMAC key lives in the
    -- service config rather than the row.
    refresh_token_hash text NOT NULL UNIQUE,
    refresh_token_expires_at timestamptz NOT NULL,

    device_platform device_platform NOT NULL,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_used_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at timestamptz
);

-- Partial: the only query that reads by user wants live sessions, and revoked
-- rows accumulate forever.
CREATE INDEX user_sessions_user_id_idx ON user_sessions (user_id) WHERE revoked_at IS NULL;

-- Push tokens are deliberately not here. A token is opaque per app install, and
-- an install outlives any one sign-in — so it belongs on `user_devices` (00003),
-- not on a row that is replaced every time somebody signs out and back in.

-- +goose Down
DROP TABLE IF EXISTS user_sessions;
DROP TYPE IF EXISTS device_platform;
DROP TABLE IF EXISTS user_auth_methods;
DROP TYPE IF EXISTS auth_service;
DROP TABLE IF EXISTS users;
