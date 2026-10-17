-- +goose Up
ALTER TABLE user_listing_alerts
    ADD COLUMN min_price integer CHECK (min_price >= 0),
    ADD COLUMN max_price integer CHECK (max_price >= 0),
    ADD CONSTRAINT listing_alert_price_range CHECK (min_price <= max_price);

-- +goose Down
ALTER TABLE user_listing_alerts
    DROP CONSTRAINT listing_alert_price_range,
    DROP COLUMN min_price,
    DROP COLUMN max_price;
