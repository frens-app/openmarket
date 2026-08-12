-- +goose Up

-- What the seller took away, beside what was generated for them.
--
-- The result screen became editable — a stepper on the price, text fields on
-- the title and the description — so each of those three now has two values,
-- and the existing columns only hold one of each. `recommended_price_minor`,
-- `listing_title` and `listing_description` stay exactly as they are: what we
-- produced. These are what was used.
--
-- **The pair is the point, and merging them would destroy it.** The obvious
-- design is one column per field, overwritten when the user edits — and it
-- answers no question at all, because "the title is X" cannot tell you whether
-- X was any good. Kept apart, one query says what fraction of sellers rewrite
-- the title, and another says which way they move the price. That is the only
-- measure of this feature's quality that comes from everybody rather than from
-- the few who stop to tap Yes or No.
--
-- All three nullable, and null means "never copied" rather than "unchanged" —
-- a copy sends the value whether it was edited or not, precisely so those two
-- stay distinguishable.
ALTER TABLE price_checks ADD COLUMN copied_price_minor bigint;
ALTER TABLE price_checks ADD COLUMN copied_listing_title text;
ALTER TABLE price_checks ADD COLUMN copied_listing_description text;

-- +goose Down
ALTER TABLE price_checks DROP COLUMN IF EXISTS copied_listing_description;
ALTER TABLE price_checks DROP COLUMN IF EXISTS copied_listing_title;
ALTER TABLE price_checks DROP COLUMN IF EXISTS copied_price_minor;
