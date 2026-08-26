-- +goose Up

-- Store Facebook's seller identifier directly. Existing cluster keys cannot be
-- reversed, so migrated rows start unresolved and acquire an id the next time
-- one of their listings is observed on a surface that publishes it.
ALTER TABLE sellers
    ADD COLUMN facebook_profile_id text;

ALTER TABLE sellers
    ADD CONSTRAINT sellers_facebook_profile_id_format CHECK (
        facebook_profile_id IS NULL OR facebook_profile_id ~ '^[0-9]{8,}$'
    );

CREATE UNIQUE INDEX sellers_facebook_profile_id_key
    ON sellers (facebook_profile_id)
    WHERE facebook_profile_id IS NOT NULL;

ALTER TABLE sellers
    DROP COLUMN seller_cluster_key;

-- +goose Down
ALTER TABLE sellers
    ADD COLUMN seller_cluster_key bytea UNIQUE;

DROP INDEX sellers_facebook_profile_id_key;

ALTER TABLE sellers
    DROP CONSTRAINT sellers_facebook_profile_id_format,
    DROP COLUMN facebook_profile_id;
