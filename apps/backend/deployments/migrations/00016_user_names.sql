-- +goose Up
ALTER TABLE users
    ADD COLUMN first_name text,
    ADD COLUMN last_name text;

-- +goose Down
ALTER TABLE users
    DROP COLUMN last_name,
    DROP COLUMN first_name;
