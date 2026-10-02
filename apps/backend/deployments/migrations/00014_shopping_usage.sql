-- +goose Up
ALTER TYPE llm_run_stage ADD VALUE IF NOT EXISTS 'SHOPPING';

-- +goose Down
-- PostgreSQL cannot remove an enum value without replacing its type.
SELECT 1;
