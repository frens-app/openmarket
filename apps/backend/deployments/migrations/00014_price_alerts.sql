-- +goose Up
CREATE TABLE price_alerts (
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
CREATE INDEX price_alerts_due ON price_alerts(next_check_at, created_at) WHERE NOT paused;
CREATE INDEX price_alerts_user ON price_alerts(user_id);

CREATE TABLE price_alert_checks (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    alert_id uuid NOT NULL REFERENCES price_alerts(id) ON DELETE CASCADE,
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
CREATE INDEX price_alert_checks_dispatch ON price_alert_checks(next_push_at, created_at) WHERE completed_at IS NULL AND NOT scan_complete;
CREATE INDEX price_alert_checks_evaluation ON price_alert_checks(evaluation_after, created_at) WHERE completed_at IS NULL;
CREATE UNIQUE INDEX price_alert_checks_active ON price_alert_checks(alert_id) WHERE completed_at IS NULL;

CREATE TABLE price_alert_listings (
    alert_id uuid NOT NULL REFERENCES price_alerts(id) ON DELETE CASCADE,
    listing_id text NOT NULL,
    check_id uuid NOT NULL REFERENCES price_alert_checks(id) ON DELETE CASCADE,
    listing jsonb NOT NULL,
    checked_at timestamptz,
    matched boolean,
    probability double precision,
    matched_at timestamptz,
    viewed_at timestamptz,
    notification_sent_at timestamptz,
    PRIMARY KEY (alert_id, listing_id)
);
CREATE INDEX price_alert_listings_pending ON price_alert_listings(check_id) WHERE checked_at IS NULL;
CREATE INDEX price_alert_listings_matches ON price_alert_listings(alert_id, matched_at DESC) WHERE matched;

CREATE TABLE price_alert_notifications (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    alert_id uuid NOT NULL REFERENCES price_alerts(id) ON DELETE CASCADE,
    check_id uuid NOT NULL UNIQUE REFERENCES price_alert_checks(id) ON DELETE CASCADE,
    listing_ids text[] NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    attempts integer NOT NULL DEFAULT 0
);

CREATE INDEX price_alert_notifications_due ON price_alert_notifications(next_attempt_at, created_at) WHERE sent_at IS NULL;

CREATE TABLE price_alert_worker_clock (id integer PRIMARY KEY CHECK(id=1), next_dispatch_at timestamptz NOT NULL);
INSERT INTO price_alert_worker_clock VALUES (1,now());

-- +goose Down
DROP TABLE price_alert_worker_clock;
DROP TABLE price_alert_notifications;
DROP TABLE price_alert_listings;
DROP TABLE price_alert_checks;
DROP TABLE price_alerts;
