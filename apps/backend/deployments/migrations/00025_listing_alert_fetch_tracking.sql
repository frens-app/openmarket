-- +goose Up
CREATE TABLE listing_alert_background_fetch_attempts (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    check_id uuid NOT NULL REFERENCES listing_alert_check_runs(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES user_devices(id) ON DELETE CASCADE,
    trigger text NOT NULL CHECK (trigger IN ('background_push', 'foreground')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    send_started_at timestamptz,
    send_finished_at timestamptz,
    apns_accepted_at timestamptz,
    send_error text,
    acknowledged_at timestamptz,
    work_requested_at timestamptz,
    search_started_at timestamptz,
    search_request jsonb,
    upload_received_at timestamptz,
    returned_listings jsonb,
    failure_at timestamptz,
    failure_stage text,
    failure_code text
);
CREATE INDEX listing_alert_background_fetch_attempts_check ON listing_alert_background_fetch_attempts(check_id, created_at);

ALTER TABLE listing_alert_check_runs
    ADD COLUMN evaluation_started_at timestamptz,
    ADD COLUMN evaluation_error_at timestamptz,
    ADD COLUMN evaluation_error_code text;

ALTER TABLE listing_alert_notification_outbox
    ADD COLUMN send_started_at timestamptz,
    ADD COLUMN send_finished_at timestamptz,
    ADD COLUMN send_error text;
UPDATE listing_alert_notification_outbox
SET send_started_at=COALESCE(sent_at,created_at), send_finished_at=sent_at,
    send_error=CASE WHEN sent_at IS NULL THEN 'legacy_outcome_unknown' END
WHERE attempts>0 OR sent_at IS NOT NULL;
DROP INDEX listing_alert_notification_outbox_due;
ALTER TABLE listing_alert_notification_outbox DROP COLUMN next_attempt_at, DROP COLUMN attempts;
CREATE INDEX listing_alert_notification_outbox_due ON listing_alert_notification_outbox(created_at) WHERE send_started_at IS NULL;

-- +goose Down
DROP INDEX listing_alert_notification_outbox_due;
ALTER TABLE listing_alert_notification_outbox
    ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN attempts integer NOT NULL DEFAULT 0;
UPDATE listing_alert_notification_outbox SET attempts=1 WHERE send_started_at IS NOT NULL;
ALTER TABLE listing_alert_notification_outbox DROP COLUMN send_started_at, DROP COLUMN send_finished_at, DROP COLUMN send_error;
CREATE INDEX listing_alert_notification_outbox_due ON listing_alert_notification_outbox(next_attempt_at, created_at) WHERE sent_at IS NULL;
ALTER TABLE listing_alert_check_runs DROP COLUMN evaluation_started_at, DROP COLUMN evaluation_error_at, DROP COLUMN evaluation_error_code;
DROP TABLE listing_alert_background_fetch_attempts;
