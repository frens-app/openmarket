-- +goose Up
ALTER TABLE users ADD COLUMN email text;

-- +goose Down
ALTER TABLE users DROP COLUMN email;
