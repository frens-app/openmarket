-- Every mutation below matches on `user_id` as well as `id`, and returns the
-- row. That is the authorization check, not a belt-and-braces addition to one:
-- a caller who names someone else's price check gets no rows back, which the
-- handler turns into NotFound. Doing it as a separate SELECT first would be two
-- queries and a race.

-- name: CreatePriceCheck :one
-- Written before the model is called, so a run that fails at the first call is
-- still a row. The identify call is the expensive part and the part most likely
-- to break; a table that only records successes cannot show that.
INSERT INTO price_checks (
    user_id,
    device_id,
    description,
    photo_sha256,
    photo_bytes,
    photo_width,
    photo_height
)
VALUES (
    sqlc.arg('user_id'),
    sqlc.narg('device_id'),
    sqlc.arg('description'),
    sqlc.narg('photo_sha256'),
    sqlc.narg('photo_bytes'),
    sqlc.narg('photo_width'),
    sqlc.narg('photo_height')
)
RETURNING *;

-- name: SetPriceCheckIdentification :one
-- What the model made of the photo, and what it wants searched. Stored even
-- though the queries are about to be handed straight back to the client: this is
-- the column that answers "we searched for the wrong thing" months later, and
-- the client's own copy is gone the moment the app is backgrounded.
UPDATE price_checks
SET identified_name = sqlc.arg('identified_name')::text,
    search_queries = sqlc.arg('search_queries')::text[]
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: CompletePriceCheck :one
-- The end of a successful run. `completed_at` is set here and nowhere else, so
-- "finished" is a single fact rather than something inferred from whichever
-- column happens to be non-null.
UPDATE price_checks
SET search_query_used = sqlc.arg('search_query_used')::text,
    comps_found = sqlc.arg('comps_found')::int,
    sold_found = sqlc.arg('sold_found')::int,
    recommended_price_minor = sqlc.narg('recommended_price_minor'),
    median_price_minor = sqlc.narg('median_price_minor'),
    currency_symbol = sqlc.narg('currency_symbol'),
    completed_at = CURRENT_TIMESTAMP
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: SetPriceCheckHelpful :one
-- Overwrites, so changing the answer works — someone who taps "No" and then
-- reconsiders should not be stuck with the first tap, and the alternative is a
-- dead control that silently ignores them.
--
-- `helpful_at` follows the current answer rather than recording the first, since
-- the question it supports is "how long after the run did they judge it", and
-- the judgement that counts is the one they left.
UPDATE price_checks
SET helpful = sqlc.arg('helpful'),
    helpful_at = CURRENT_TIMESTAMP
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: MarkPriceCheckPriceCopied :one
-- Idempotent, and the **first** copy keeps the timestamp — unlike the feedback
-- above, because the question here is "how long did it take them to act on it",
-- and someone copying the same number a second time an hour later has not
-- changed their mind about anything.
UPDATE price_checks
SET price_copied = true,
    price_copied_at = COALESCE(price_copied_at, CURRENT_TIMESTAMP)
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: GetPriceCheck :one
SELECT *
FROM price_checks
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id');

-- name: RecordLLMRun :one
-- One row per call, including the ones that failed. Recorded after the call
-- returns rather than around it: a row here is a statement that a request was
-- served or refused, and a call that never left the process is a log line.
INSERT INTO llm_runs (
    price_check_id,
    user_id,
    stage,
    attempt,
    provider,
    model,
    input_tokens,
    output_tokens,
    cached_input_tokens,
    latency_ms,
    status,
    error_code
)
VALUES (
    sqlc.narg('price_check_id'),
    sqlc.arg('user_id'),
    sqlc.arg('stage'),
    sqlc.arg('attempt'),
    sqlc.arg('provider'),
    sqlc.arg('model'),
    sqlc.narg('input_tokens'),
    sqlc.narg('output_tokens'),
    sqlc.narg('cached_input_tokens'),
    sqlc.arg('latency_ms'),
    sqlc.arg('status'),
    sqlc.narg('error_code')
)
RETURNING *;

-- name: CountLLMRunsForUser :one
-- The ceiling. Counts calls rather than money, because there is no rate table
-- yet — and calls are the right unit for the failure this actually guards
-- against early on, which is a client stuck in a retry loop rather than a large
-- bill. It becomes a cost ceiling later without moving the call site.
--
-- Failed attempts count. A provider erroring after it has read the request has
-- usually still charged for it, and a loop that only fails is the exact case
-- this exists to stop.
SELECT count(*)
FROM llm_runs
WHERE user_id = sqlc.arg('user_id')
  AND created_at > CURRENT_TIMESTAMP - sqlc.arg('window')::interval;

-- name: SumLLMTokensForUser :one
-- Same window, by tokens. Not wired to anything yet — it is here because it is
-- the query the ceiling turns into once a rate table exists, and writing it
-- beside the count is how the two stay honest about counting the same rows.
SELECT
    coalesce(sum(input_tokens), 0)::bigint AS input_tokens,
    coalesce(sum(output_tokens), 0)::bigint AS output_tokens,
    coalesce(sum(cached_input_tokens), 0)::bigint AS cached_input_tokens
FROM llm_runs
WHERE user_id = sqlc.arg('user_id')
  AND created_at > CURRENT_TIMESTAMP - sqlc.arg('window')::interval;
