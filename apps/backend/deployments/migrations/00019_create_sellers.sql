-- +goose Up
-- Client-observed public profile data. Facebook login is not required and
-- partial observations must not erase fields unavailable to guest browsing.
CREATE TABLE facebook_sellers (
    id text PRIMARY KEY CHECK (id ~ '^[0-9]{1,64}$'),
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 512),
    photo_url text,
    joined_text text,
    rating double precision CHECK (rating >= 0 AND rating <= 5),
    rating_count integer CHECK (rating_count >= 0),
    is_highly_rated boolean,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE seller_follows (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    seller_id text NOT NULL REFERENCES facebook_sellers(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, seller_id)
);
CREATE INDEX seller_follows_seller_id_idx ON seller_follows(seller_id);

-- +goose Down
DROP TABLE seller_follows;
DROP TABLE facebook_sellers;
