-- +goose Up

-- The listing the model wrote: the title and the body.
--
-- These were returned to the phone and then dropped. Everything else about a
-- check survives — what was typed, what it was identified as, what it was
-- priced at, whether it helped — but the two things the user actually walks
-- away with existed only in a response.
--
-- That gap is the one with a deadline. A missing column can be added whenever
-- somebody wants it; a listing that was written, shown once and never written
-- down is gone the moment the app closes, and no later migration recovers it.
-- So these land now, before the screen that reads them exists.
--
-- Nullable, because a check that fails at identify never reaches the call that
-- writes them, and because every row already in the table predates this.
ALTER TABLE price_checks ADD COLUMN listing_title text;
ALTER TABLE price_checks ADD COLUMN listing_description text;

-- What is still **not** here, deliberately: the comparables themselves. Those
-- are dozens of listings per check, they belong to Facebook rather than to us,
-- and they rot — a card that was live during the run is a 404 a week later. A
-- history built on them would show a market that no longer exists. The
-- aggregates in `comps_found`, `sold_found` and `median_price_minor` are what
-- stays true, which is why they are the columns and the cards are not.

-- +goose Down
ALTER TABLE price_checks DROP COLUMN IF EXISTS listing_description;
ALTER TABLE price_checks DROP COLUMN IF EXISTS listing_title;
