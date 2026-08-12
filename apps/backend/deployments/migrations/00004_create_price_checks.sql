-- +goose Up

-- One row per price check, and one row per model call underneath it.
--
-- The split is not tidiness. A check makes one model call and, under retry,
-- more — and every attempt is charged. Folding them into columns on
-- `price_checks` would mean either losing the retries or inventing
-- `input_tokens_2`, and the retries are exactly the rows worth seeing when a
-- bill or a latency graph moves.
--
-- It was two calls when this table was written, which is where the `stage`
-- column comes from. The pricing call has since been removed — the price is a
-- median, computed on the device — so `stage` is IDENTIFY on everything new and
-- PRICE only on history. The table did not need changing for that, which is the
-- argument for having built it this way.

CREATE TABLE price_checks (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    -- Which install ran it. Nullable and SET NULL rather than CASCADE: a device
    -- row can go away (reinstall, sign-out elsewhere) long after the check, and
    -- losing the whole check because we no longer know which phone it came from
    -- would be deleting the answer to keep the footnote.
    device_id uuid REFERENCES user_devices (id) ON DELETE SET NULL,

    -- What the seller typed. Kept verbatim, because when someone answers "not
    -- helpful" this is the first thing anyone will want to read, and a
    -- normalised or truncated copy answers a different question.
    description text NOT NULL,

    -- The photo's shape, not the photo.
    --
    -- Nothing here stores image bytes: the photo rides one RPC, goes to the
    -- model, and is gone. What is left is enough to tell "they sent a 4-megapixel
    -- photo" from "they sent a thumbnail" when an identification comes back
    -- wrong, and enough to notice the same image run twice.
    --
    -- Singular, and correct today rather than a compromise: the request caps
    -- `photos` at one item, so the server cannot receive a second. Raising that
    -- cap is the migration that replaces these four columns with a
    -- `price_check_photos` child table keyed on (price_check_id, ordinal).
    photo_sha256 bytea,
    photo_bytes integer,
    photo_width integer,
    photo_height integer,

    -- Filled by the identify call. Null on a check that never got past it.
    identified_name text,
    search_queries text[],

    -- Which of those the phone actually searched. Stored beside the full list
    -- rather than instead of it, because the pair is what separates the two
    -- ways this feature goes wrong: a bad identification (the queries were
    -- never going to work) from a bad market (the query was right and the city
    -- had nothing). One column cannot tell those apart.
    search_query_used text,

    -- Filled once the phone reports back what the market gave it. These are the
    -- only numbers here the server does not compute and cannot check — the
    -- search runs in a WKWebView on the device, against the user's own Facebook
    -- session, so the counts are the client's word.
    comps_found integer,
    sold_found integer,

    -- The answer, when there was one.
    --
    -- Minor units, per docs/data-model.md, even though every price the app can
    -- currently read is a whole unit off a rendered card. Storing 8000 for a
    -- displayed "$80" is lossless and leaves the column able to hold a price
    -- with cents; storing 80 would mean a migration the first time one appears.
    recommended_price_minor bigint,
    median_price_minor bigint,

    -- The **symbol** the comparables were written in — "$", "CA$", "£" — not an
    -- ISO 4217 code. That distinction is the honest one: `PriceGuide` derives
    -- this by voting on the prefix of the cards themselves and never learns the
    -- currency's name, so a column called `currency` would promise a fact we do
    -- not have. A Toronto check stores "CA$".
    currency_symbol text,

    -- Two signals about whether this was any use, and they are not redundant.
    --
    -- `helpful` is the asked question: three states, so it is nullable rather
    -- than a boolean defaulting to false — "they said no" and "they never
    -- answered" are different findings, and a NOT NULL DEFAULT false column
    -- collapses them into the same value. Same reasoning the proto messages give
    -- for marking every nullable field `optional`.
    --
    -- `price_copied` is the unasked one, and the better of the two: copying the
    -- number to the pasteboard is what someone does immediately before pasting
    -- it into Facebook's price box. It is captured on nearly every successful
    -- run, where a prompt is answered by the minority who feel strongly — which
    -- skews negative.
    helpful boolean,
    helpful_at timestamptz,
    price_copied boolean NOT NULL DEFAULT false,
    price_copied_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Null until the run produced a price. A row that stops before this is not a
    -- gap in the data — "the model identified a bread maker and the market had
    -- nothing to compare it to" is one of the more useful things in the table,
    -- and it is invisible if partial runs are never written.
    completed_at timestamptz
);

CREATE INDEX price_checks_user_id_idx ON price_checks (user_id, created_at DESC);

-- The review queue: runs somebody marked unhelpful, newest first. Partial,
-- because the answered rows will always be the small minority.
CREATE INDEX price_checks_helpful_idx
    ON price_checks (created_at DESC)
    WHERE helpful IS NOT NULL;

CREATE TYPE llm_run_stage AS ENUM ('IDENTIFY', 'PRICE');
CREATE TYPE llm_run_status AS ENUM ('OK', 'ERROR');

CREATE TABLE llm_runs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),

    -- Nullable, and SET NULL rather than CASCADE, for two reasons at once: this
    -- table is going to serve the next feature that calls a model as well as
    -- this one, and a spend record should outlive the thing it was spent on.
    price_check_id uuid REFERENCES price_checks (id) ON DELETE SET NULL,

    -- Denormalised so the per-user ceiling is one indexed read rather than a
    -- join through a row that may since have been detached above.
    --
    -- CASCADE: deleting a user takes their model-call history with them. That
    -- loses spend history, which is the cost of it being the privacy-correct
    -- default — and `users` soft-deletes, so this fires only on a hard purge,
    -- which does not exist yet.
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    stage llm_run_stage NOT NULL,

    -- 1 for the first try. Retries are rows, not an overwrite: two attempts at
    -- the identify call cost twice, and a table that hides that reports a number
    -- lower than the invoice.
    attempt integer NOT NULL DEFAULT 1,

    -- The literal strings sent on the wire, not our internal names for them.
    -- These are what makes cost reconstructible later: token counts alone are
    -- meaningless without knowing which model's rate card to apply, and a
    -- friendly alias drifts from the thing that was actually billed.
    provider text NOT NULL,
    model text NOT NULL,

    -- Nullable because a call that failed before it was served has none.
    --
    -- No cost column, deliberately. Cost is a pure function of these three
    -- numbers and `model`, so it can be computed retroactively over rows written
    -- long before a rate table exists — and computing it at write time would
    -- freeze a number that a provider reprice makes wrong. What cannot be
    -- recovered later is a token count that was never written down, which is why
    -- these are here from the first migration and the money is not.
    input_tokens integer,
    output_tokens integer,
    cached_input_tokens integer,

    -- Wall clock for the call itself, recorded on failures too — a provider
    -- getting slow shows up here before it shows up as an error.
    latency_ms integer NOT NULL,

    status llm_run_status NOT NULL,
    -- Our classification, not the provider's prose: "timeout", "rate_limited",
    -- "invalid_output". Prose belongs in the logs, where it is already.
    error_code text,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX llm_runs_price_check_id_idx ON llm_runs (price_check_id);

-- The ceiling query — "how many calls has this user made since T" — and the
-- per-user cost rollup, which is the same shape.
CREATE INDEX llm_runs_user_id_created_at_idx ON llm_runs (user_id, created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS llm_runs;
DROP TYPE IF EXISTS llm_run_status;
DROP TYPE IF EXISTS llm_run_stage;
DROP TABLE IF EXISTS price_checks;
