-- +goose Up

-- A device install, which turns out to be a different thing from a session and
-- from a user, and the Facebook connection is what makes that concrete.
--
-- "Connect with Facebook" in this app is a WKWebView cookie jar, not an OAuth
-- grant (backend-platform.md, constraint 2). A cookie jar lives in one app
-- container on one phone: it does not travel to a second device, it does not
-- survive a reinstall, and no amount of signing into our account elsewhere
-- reproduces it. So "has connected Facebook" is only ever true *of an install*,
-- and storing it on users would assert something false the moment someone picks
-- up a second phone.
--
-- Push tokens live here for the same reason at one remove: a token is opaque per
-- app install, so an install is its grain. On user_sessions it would be dropped
-- every time somebody signed out and back in on the same phone.
CREATE TYPE notification_permission_status AS ENUM ('UNKNOWN', 'ENABLED', 'DISABLED');

CREATE TABLE user_devices (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    -- Client-generated, stable for the life of an install. The iOS client keeps
    -- it in the keychain beside the session tokens, which makes the lifetimes
    -- line up exactly: if a reinstall loses the id, it has also lost the cookie
    -- jar, so a fresh row starting at facebook_connected = false is the correct
    -- answer rather than a lost one.
    --
    -- Not identifierForVendor: that is device-scoped rather than install-scoped,
    -- and reading it commits us to a value Apple controls.
    install_id text NOT NULL,
    platform device_platform NOT NULL,

    -- Current state, plus when it last changed in each direction. The boolean is
    -- what the API returns; deriving it from the two timestamps instead would
    -- mean every reader re-implementing the same comparison, and one of them
    -- getting it backwards.
    facebook_connected boolean NOT NULL DEFAULT false,
    facebook_connected_at timestamptz,
    facebook_disconnected_at timestamptz,

    -- The token and nothing else.
    --
    -- The two obvious companions — the APNs topic and the sandbox/production
    -- environment — are deliberately absent. Both are constants of a deployment
    -- rather than facts about a row: this service serves one bundle id, and it
    -- serves builds from one APNs environment, so storing either per device is
    -- storing the same value a few hundred thousand times. They belong in the
    -- sender's config, and the sender does not exist yet.
    --
    -- The case that would bring the environment back is a staging backend
    -- serving TestFlight builds (production tokens) and Xcode builds (sandbox
    -- tokens) at once. If that ever happens, add the column then — a device
    -- re-registers its token on launch, so there is no history to reconstruct.
    push_token text,
    push_token_updated_at timestamptz,
    notification_permission_status notification_permission_status NOT NULL DEFAULT 'UNKNOWN',

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Per user, not global. Two people signing into the same phone get two rows,
    -- so one of them cannot learn that the other connected Facebook here.
    UNIQUE (user_id, install_id)
);

CREATE INDEX user_devices_user_id_idx ON user_devices (user_id);

-- APNs issues one token per (app, install, environment), and this deployment is
-- a single app and a single environment — so within it the token alone is the
-- identity. Partial, so the index only covers rows that are actually pushable.
CREATE UNIQUE INDEX user_devices_push_token_idx
    ON user_devices (push_token)
    WHERE push_token IS NOT NULL;

ALTER TABLE user_sessions
    ADD COLUMN device_id uuid REFERENCES user_devices (id) ON DELETE SET NULL;

CREATE INDEX user_sessions_device_id_idx ON user_sessions (device_id);

-- +goose Down
DROP INDEX IF EXISTS user_sessions_device_id_idx;
ALTER TABLE user_sessions DROP COLUMN IF EXISTS device_id;
DROP TABLE IF EXISTS user_devices;
DROP TYPE IF EXISTS notification_permission_status;
