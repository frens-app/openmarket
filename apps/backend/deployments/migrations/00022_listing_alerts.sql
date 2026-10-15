-- +goose Up
CREATE TABLE user_listing_alerts (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES user_devices(id) ON DELETE CASCADE,
    query text NOT NULL CHECK (length(query) BETWEEN 1 AND 300),
    location jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    alert_hour smallint NOT NULL CHECK (alert_hour BETWEEN 0 AND 23),
    next_check_at timestamptz NOT NULL,
    last_checked_at timestamptz,
    paused boolean NOT NULL DEFAULT false
);
CREATE INDEX user_listing_alerts_due ON user_listing_alerts(next_check_at, created_at) WHERE NOT paused;
CREATE INDEX user_listing_alerts_user ON user_listing_alerts(user_id);

CREATE TABLE listing_alert_check_runs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    alert_id uuid NOT NULL REFERENCES user_listing_alerts(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    cursor text,
    facebook_actor text,
    page_number integer NOT NULL DEFAULT 0,
    scan_complete boolean NOT NULL DEFAULT false,
    completed_at timestamptz,
    next_push_at timestamptz NOT NULL DEFAULT now(),
    last_push_at timestamptz,
    push_attempts integer NOT NULL DEFAULT 0,
    evaluation_after timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX listing_alert_check_runs_dispatch ON listing_alert_check_runs(next_push_at, created_at) WHERE completed_at IS NULL AND NOT scan_complete;
CREATE INDEX listing_alert_check_runs_evaluation ON listing_alert_check_runs(evaluation_after, created_at) WHERE completed_at IS NULL;
CREATE UNIQUE INDEX listing_alert_check_runs_active ON listing_alert_check_runs(alert_id) WHERE completed_at IS NULL;

CREATE TABLE listing_alert_listings (
    alert_id uuid NOT NULL REFERENCES user_listing_alerts(id) ON DELETE CASCADE,
    listing_id text NOT NULL,
    check_id uuid NOT NULL REFERENCES listing_alert_check_runs(id) ON DELETE CASCADE,
    listing jsonb NOT NULL,
    checked_at timestamptz,
    matched boolean,
    probability double precision,
    matched_at timestamptz,
    viewed_at timestamptz,
    notification_sent_at timestamptz,
    PRIMARY KEY (alert_id, listing_id)
);
CREATE INDEX listing_alert_listings_pending ON listing_alert_listings(check_id) WHERE checked_at IS NULL;
CREATE INDEX listing_alert_listings_matches ON listing_alert_listings(alert_id, matched_at DESC) WHERE matched;

CREATE TABLE listing_alert_notification_outbox (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    alert_id uuid NOT NULL REFERENCES user_listing_alerts(id) ON DELETE CASCADE,
    check_id uuid NOT NULL UNIQUE REFERENCES listing_alert_check_runs(id) ON DELETE CASCADE,
    listing_ids text[] NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    attempts integer NOT NULL DEFAULT 0
);

CREATE INDEX listing_alert_notification_outbox_due ON listing_alert_notification_outbox(next_attempt_at, created_at) WHERE sent_at IS NULL;

CREATE TABLE listing_alert_worker_clock (id integer PRIMARY KEY CHECK(id=1), next_dispatch_at timestamptz NOT NULL);
INSERT INTO listing_alert_worker_clock VALUES (1,now());

-- +goose Down
DROP TABLE listing_alert_worker_clock;
DROP TABLE listing_alert_notification_outbox;
DROP TABLE listing_alert_listings;
DROP TABLE listing_alert_check_runs;
DROP TABLE user_listing_alerts;
