-- +goose Up
ALTER TYPE auth_service ADD VALUE IF NOT EXISTS 'APPLE';
ALTER TYPE auth_service ADD VALUE IF NOT EXISTS 'GOOGLE';

CREATE TABLE sign_in_challenges (
    nonce_hash text PRIMARY KEY,
    auth_service auth_service NOT NULL,
    install_id text NOT NULL,
    expires_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP + interval '5 minutes'
);
CREATE INDEX sign_in_challenges_expires_at_idx ON sign_in_challenges (expires_at);

-- +goose Down
DROP TABLE sign_in_challenges;
-- Provider enum values and accounts remain so rollback cannot delete user data.
