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
-- **Measured, 2026-08-11, gemini-3.6-flash via the Gateway: output is
-- inclusive.** Two real calls returned completion 628 / reasoning 576 and
-- completion 815 / reasoning 772 — differences of 52 and 43 tokens, which is
-- the size of the JSON that came back. So cost is `output × rate`, and adding
-- thought to it double-counts. Note what that ratio says on its own: over 90%
-- of the output tokens on both calls were thinking nobody ever reads. That is
-- the number this column exists to make visible, and it is the first thing to
-- look at if the bill is ever surprising.
--
-- Measured on one model through one route, so it is not a law. Whoever writes
-- the rate table re-checks it per provider against a real invoice.
--
-- Not Gemini-specific: separately-reported reasoning tokens are the norm across
-- providers now, so this stays meaningful when the provider changes.
ALTER TABLE llm_runs ADD COLUMN thought_tokens integer;

-- +goose Down
ALTER TABLE llm_runs DROP COLUMN IF EXISTS thought_tokens;
