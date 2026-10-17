-- +goose Up
ALTER TABLE user_listing_alerts
    ADD COLUMN alert_minute smallint NOT NULL DEFAULT 0 CHECK (alert_minute BETWEEN 0 AND 59),
    ADD COLUMN time_zone text NOT NULL DEFAULT 'UTC';

-- +goose StatementBegin
CREATE FUNCTION next_listing_alert_check_time(after_time timestamptz, check_hour integer, check_minute integer, zone_name text)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT min(candidate)
    FROM (
        SELECT (date_trunc('day', after_time AT TIME ZONE zone_name)
                + n * interval '1 day'
                + make_interval(hours => check_hour, mins => check_minute)) AT TIME ZONE zone_name AS candidate
        FROM generate_series(0, 2) AS n
    ) times
    WHERE candidate > after_time;
$$;
-- +goose StatementEnd

-- +goose Down
-- Preserve the next scheduled instant's UTC hour for the older scheduler.
UPDATE user_listing_alerts SET alert_hour=extract(hour FROM next_check_at AT TIME ZONE 'UTC');
DROP FUNCTION next_listing_alert_check_time(timestamptz, integer, integer, text);
ALTER TABLE user_listing_alerts DROP COLUMN alert_minute, DROP COLUMN time_zone;
