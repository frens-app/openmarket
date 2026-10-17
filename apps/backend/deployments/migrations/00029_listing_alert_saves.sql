-- +goose Up
ALTER TABLE listing_alert_listings ADD COLUMN saved_at timestamptz;
ALTER TABLE listing_alert_interactions
    DROP CONSTRAINT listing_alert_interactions_kind_check,
    DROP CONSTRAINT listing_alert_interactions_check,
    ADD CONSTRAINT listing_alert_interactions_kind_check CHECK (kind IN ('alert_opened', 'listing_opened', 'listing_saved')),
    ADD CONSTRAINT listing_alert_interactions_check CHECK ((kind IN ('listing_opened', 'listing_saved')) = (listing_id IS NOT NULL));

-- +goose Down
DELETE FROM listing_alert_interactions WHERE kind='listing_saved';
ALTER TABLE listing_alert_interactions
    DROP CONSTRAINT listing_alert_interactions_kind_check,
    DROP CONSTRAINT listing_alert_interactions_check,
    ADD CONSTRAINT listing_alert_interactions_kind_check CHECK (kind IN ('alert_opened', 'listing_opened')),
    ADD CONSTRAINT listing_alert_interactions_check CHECK ((kind = 'listing_opened') = (listing_id IS NOT NULL));
ALTER TABLE listing_alert_listings DROP COLUMN saved_at;
