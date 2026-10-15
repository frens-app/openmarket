-- +goose Up
ALTER TABLE listings
    ADD COLUMN last_viewed_at timestamptz,
    ADD COLUMN last_viewed_by uuid REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN last_view_received_at timestamptz,
    ADD COLUMN last_detail_observed_at timestamptz,
    ADD COLUMN last_detail_source text,
    ADD COLUMN last_detail_updated_by uuid REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN last_detail_received_at timestamptz;

-- +goose Down
ALTER TABLE listings DROP COLUMN last_viewed_at, DROP COLUMN last_viewed_by,
    DROP COLUMN last_view_received_at, DROP COLUMN last_detail_observed_at,
    DROP COLUMN last_detail_source, DROP COLUMN last_detail_updated_by,
    DROP COLUMN last_detail_received_at;
