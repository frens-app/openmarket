-- +goose Up
ALTER TABLE listing_alert_interactions
    DROP CONSTRAINT listing_alert_interactions_source_check,
    ADD CONSTRAINT listing_alert_interactions_source_check
        CHECK (source IN ('notification', 'alerts_tab', 'creation', 'search', 'search_history'));

-- +goose Down
UPDATE listing_alert_interactions SET source='alerts_tab' WHERE source IN ('search', 'search_history');
ALTER TABLE listing_alert_interactions
    DROP CONSTRAINT listing_alert_interactions_source_check,
    ADD CONSTRAINT listing_alert_interactions_source_check CHECK (source IN ('notification', 'alerts_tab', 'creation'));
