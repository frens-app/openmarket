-- +goose Up
ALTER TYPE llm_run_stage ADD VALUE IF NOT EXISTS 'RELEVANCE';

-- +goose Down
-- PostgreSQL enum values remain so recorded evaluations keep their stage.
SELECT 1;
