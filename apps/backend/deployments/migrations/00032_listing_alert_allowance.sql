-- +goose Up
ALTER TABLE users ADD COLUMN listing_alert_bonus_slots integer NOT NULL DEFAULT 0
    CHECK (listing_alert_bonus_slots >= 0);

-- +goose Down
ALTER TABLE users DROP COLUMN listing_alert_bonus_slots;
