-- +goose Up
ALTER TABLE sign_in_challenges ADD COLUMN linking_session_id uuid
    REFERENCES user_sessions (id) ON DELETE CASCADE;

-- +goose Down
ALTER TABLE sign_in_challenges DROP COLUMN linking_session_id;
