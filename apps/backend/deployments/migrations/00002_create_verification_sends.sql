-- +goose Up

-- A ceiling on what verification can cost, and nothing else.
--
-- Prelude already limits verification requests per number over a configurable
-- window, limits code checks per window, and scores every request against an
-- anti-fraud model with cross-customer traffic signal this service could never
-- see. All of that is better than anything that could be written here, so none
-- of it is reimplemented. An earlier version of this table did reimplement it,
-- and per-IP limiting on top.
--
-- What none of that caps is **total spend**, because every one of those limits
-- is per entity. Somebody cycling a thousand ordinary US mobile numbers trips no
-- per-number limit and looks nothing like pumping — no premium prefix, nobody
-- profiting — so it reads as griefing rather than fraud, and the first
-- indication is the invoice. The provider's own spend controls are account-level
-- and after the fact.
--
-- So this is a circuit breaker and not a fairness mechanism: one row per send,
-- counted over a window, refused past a ceiling.
--
-- Deliberately no phone number, IP or country column. Counting is the entire
-- job, and the provider's own dashboard is already the per-number audit
-- trail — storing the numbers of people who never finished signing up would mean
-- holding data we don't need in order to duplicate a record we don't own.
CREATE TABLE verification_sends (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- The only query is "how many since T". Rows past the window are pruned on a
-- timer; nothing reads them afterwards.
CREATE INDEX verification_sends_created_at_idx ON verification_sends (created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS verification_sends;
