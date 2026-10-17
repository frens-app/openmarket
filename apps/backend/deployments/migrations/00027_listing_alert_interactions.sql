-- +goose Up
CREATE TABLE listing_alert_interactions (
    id uuid PRIMARY KEY,
    alert_id uuid NOT NULL REFERENCES user_listing_alerts(id) ON DELETE CASCADE,
    notification_id uuid REFERENCES listing_alert_notification_outbox(id) ON DELETE SET NULL,
    listing_id text,
    kind text NOT NULL CHECK (kind IN ('alert_opened', 'listing_opened')),
    source text NOT NULL CHECK (source IN ('notification', 'alerts_tab', 'creation')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((kind = 'listing_opened') = (listing_id IS NOT NULL)),
    FOREIGN KEY (alert_id, listing_id) REFERENCES listing_alert_listings(alert_id, listing_id) ON DELETE CASCADE
);
CREATE INDEX listing_alert_interactions_alert ON listing_alert_interactions(alert_id, created_at);
CREATE INDEX listing_alert_interactions_notification ON listing_alert_interactions(notification_id) WHERE notification_id IS NOT NULL;

-- +goose Down
DROP TABLE listing_alert_interactions;
