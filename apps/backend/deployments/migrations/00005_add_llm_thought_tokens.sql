-- +goose Up

-- Reasoning tokens, reported separately from output and billed as output.
--
-- Gemini returns `total_thought_tokens` alongside `total_output_tokens`, and
-- the pricing page says thinking tokens are charged at the output rate — but
-- **it does not say whether `total_output_tokens` already includes them**. That
-- ambiguity is worth a column rather than a guess: if output is inclusive this
-- records how much of it was reasoning, which is a useful thing to know on its
-- own; if it is exclusive, cost is (output + thought) × rate and stays
-- computable. Storing only output risks undercounting by whatever fraction of a
-- thinking model's work is thinking, which can be most of it.
--
-- Whoever writes the rate table resolves this against a real invoice — one
-- month of rows and one statement settles it — and until then nothing is lost.
--
-- Not Gemini-specific: separately-reported reasoning tokens are the norm across
-- providers now, so this stays meaningful when the provider changes.
ALTER TABLE llm_runs ADD COLUMN thought_tokens integer;

-- +goose Down
ALTER TABLE llm_runs DROP COLUMN IF EXISTS thought_tokens;
