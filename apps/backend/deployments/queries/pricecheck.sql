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
    description
)
VALUES (
    sqlc.arg('user_id'),
    sqlc.narg('device_id'),
    sqlc.arg('description')
)
RETURNING *;

-- name: AddPriceCheckPhoto :exec
-- One row per photo, shape only — see migration 00007. Called in a loop rather
-- than as a batch because there are at most three of them, and a failure to
-- record photo metadata must not lose the price check it belongs to.
INSERT INTO price_check_photos (
    price_check_id,
    ordinal,
    sha256,
    bytes,
    width,
    height
)
VALUES (
    sqlc.arg('price_check_id'),
    sqlc.arg('ordinal'),
    sqlc.arg('sha256'),
    sqlc.arg('bytes'),
    sqlc.arg('width'),
    sqlc.arg('height')
);

-- name: SetPriceCheckIdentification :one
-- Everything the model produced, written where it is produced.
--
-- Stored even though all of it is about to be handed straight back to the
-- client: these are the columns that answer "we searched for the wrong thing"
-- and "what did it actually write" months later, and the client's own copy is
-- gone the moment the app is backgrounded.
--
-- The listing lands here rather than at completion because this is the call
-- that made it. A run that identifies an item and then finds no market still
-- wrote a title and a description, and losing them because the search came back
-- empty would be discarding the half that worked.
UPDATE price_checks
SET identified_name = sqlc.arg('identified_name')::text,
    search_queries = sqlc.arg('search_queries')::text[],
    listing_title = sqlc.arg('listing_title')::text,
    listing_description = sqlc.arg('listing_description')::text
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: CompletePriceCheck :one
-- The end of a successful run: what the market held, and what the device
-- therefore recommended. `completed_at` is set here and nowhere else, so
-- "finished" is a single fact rather than something inferred from whichever
-- column happens to be non-null.
--
-- Every number here is the client's word. The search runs in a WKWebView
-- against the user's own Facebook session, so the server cannot check a single
-- one of them — which was already true of the counts and is now true of the
-- price as well, since the device computes it.
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

-- name: RecordPriceCheckCopy :one
-- One copy, of whatever was copied.
--
-- Three rules in six lines, and each is deliberate:
--
-- `price_copied` only goes true when a price came with the call. The flag has
-- always meant "took the number", and a title copy is not that — letting it be
-- set by any copy would quietly redefine every chart built on it.
--
-- `price_copied_at` keeps the **first** value, because the question it answers
-- is how long somebody took to act, and copying the same number again an hour
-- later has not changed that.
--
-- The three value columns take the **latest**, because somebody who copies,
-- rewrites the title and copies again has changed their mind about exactly
-- what these measure. COALESCE on the argument rather than the column, so a
-- call carrying one field leaves the other two alone instead of blanking them.
--
-- The `::bigint` casts are load-bearing rather than decoration. The first time
-- this argument appears it is inside `IS NOT NULL`, which is a boolean context,
-- and sqlc types the parameter from that first sighting — generating a `*bool`
-- for a column holding money. Naming the type on every use pins it.
UPDATE price_checks
SET price_copied = price_copied OR sqlc.narg('copied_price_minor')::bigint IS NOT NULL,
    price_copied_at = CASE
        WHEN sqlc.narg('copied_price_minor')::bigint IS NOT NULL
        THEN COALESCE(price_copied_at, CURRENT_TIMESTAMP)
        ELSE price_copied_at
    END,
    copied_price_minor = COALESCE(sqlc.narg('copied_price_minor')::bigint, copied_price_minor),
    copied_listing_title = COALESCE(sqlc.narg('copied_listing_title'), copied_listing_title),
    copied_listing_description = COALESCE(sqlc.narg('copied_listing_description'), copied_listing_description)
WHERE id = sqlc.arg('id')
  AND user_id = sqlc.arg('user_id')
RETURNING *;

-- name: ListPriceChecks :many
-- Recent runs for one user, newest first.
--
-- Served entirely by `price_checks_user_id_idx (user_id, created_at DESC)`,
-- which is why the ordering here is `created_at` and not `id` — the ids are
-- uuidv7 and would sort the same way, but only one of the two is indexed.
--
-- `identified_name IS NOT NULL` is the whole filter, and it is about what a
-- person can recognise rather than about success. A row without one died in the
-- model call, so it holds a description and nothing else; a row with one has a
-- name, and usually a listing, even when the market came back empty. The
-- unnamed ones are still in the table and still counted — they are just not
-- something to hand back as "you checked this".
SELECT *
FROM price_checks
WHERE user_id = sqlc.arg('user_id')
  AND identified_name IS NOT NULL
ORDER BY created_at DESC
LIMIT sqlc.arg('limit');

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
    thought_tokens,
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
    sqlc.narg('thought_tokens'),
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
    coalesce(sum(thought_tokens), 0)::bigint AS thought_tokens,
    coalesce(sum(cached_input_tokens), 0)::bigint AS cached_input_tokens
FROM llm_runs
WHERE user_id = sqlc.arg('user_id')
  AND created_at > CURRENT_TIMESTAMP - sqlc.arg('window')::interval;
