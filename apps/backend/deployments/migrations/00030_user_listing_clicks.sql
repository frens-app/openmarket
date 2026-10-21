-- +goose Up
CREATE TABLE user_listing_clicks (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    listing_id uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
    first_clicked_at timestamptz NOT NULL,
    first_clicked_from text NOT NULL,
    last_clicked_at timestamptz NOT NULL,
    last_clicked_from text NOT NULL,
    click_count bigint NOT NULL CHECK (click_count > 0),
    PRIMARY KEY (user_id, listing_id),
    CHECK (first_clicked_at <= last_clicked_at)
);
CREATE INDEX user_listing_clicks_listing_id_idx ON user_listing_clicks(listing_id);

-- +goose Down
DROP TABLE user_listing_clicks;
