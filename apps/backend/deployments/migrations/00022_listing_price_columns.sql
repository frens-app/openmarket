-- +goose Up
ALTER TABLE listings
    ADD COLUMN price_amount numeric,
    ADD COLUMN price_currency_code text,
    ADD COLUMN original_price_amount numeric,
    ADD CONSTRAINT listings_price_amount_valid CHECK (
        price_amount >= 0 AND price_amount < 1000000000000000000 AND scale(price_amount) <= 2
    ),
    ADD CONSTRAINT listings_original_price_amount_valid CHECK (
        original_price_amount >= 0 AND original_price_amount < 1000000000000000000 AND scale(original_price_amount) <= 2
    ),
    ADD CONSTRAINT listings_price_currency_code_valid CHECK (price_currency_code ~ '^[A-Z]{3}$');

COMMENT ON COLUMN listings.price_amount IS 'Current asking price in exact major currency units; NULL means unknown.';
COMMENT ON COLUMN listings.original_price_amount IS 'Previous asking price shown crossed out by Facebook, not the first price we observed; NULL means unavailable.';
COMMENT ON COLUMN listings.price_currency_code IS 'Currency of the asking prices; NULL when the source is ambiguous.';

-- Backfill only explicit structured values, never infer units or currency from
-- formatted text. Unconstrained numeric plus checks rejects excess precision
-- rather than silently rounding it during assignment.
UPDATE listings SET
    price_amount = CASE
        WHEN jsonb_typeof(snapshot->'priceAmountDecimal') = 'string'
             AND snapshot->>'priceAmountDecimal' ~ '^(0|[1-9][0-9]{0,17})(\.[0-9]{1,2})?$'
        THEN (snapshot->>'priceAmountDecimal')::numeric END,
    price_currency_code = CASE
        WHEN jsonb_typeof(snapshot->'priceCurrencyCode') = 'string'
             AND snapshot->>'priceCurrencyCode' ~ '^[A-Z]{3}$'
        THEN snapshot->>'priceCurrencyCode' END,
    original_price_amount = CASE
        WHEN jsonb_typeof(snapshot->'originalPriceAmountDecimal') = 'string'
             AND snapshot->>'originalPriceAmountDecimal' ~ '^(0|[1-9][0-9]{0,17})(\.[0-9]{1,2})?$'
        THEN (snapshot->>'originalPriceAmountDecimal')::numeric END,
    snapshot = snapshot - 'priceAmountDecimal' - 'priceCurrencyCode' - 'originalPriceAmountDecimal'
WHERE snapshot ?| ARRAY['priceAmountDecimal', 'priceCurrencyCode', 'originalPriceAmountDecimal'];

-- +goose Down
UPDATE listings SET snapshot =
    (snapshot - 'priceAmountDecimal' - 'priceCurrencyCode' - 'originalPriceAmountDecimal')
    || jsonb_strip_nulls(jsonb_build_object(
        'priceAmountDecimal', price_amount::text,
        'priceCurrencyCode', price_currency_code,
        'originalPriceAmountDecimal', original_price_amount::text
    ))
WHERE price_amount IS NOT NULL OR price_currency_code IS NOT NULL OR original_price_amount IS NOT NULL;
ALTER TABLE listings DROP COLUMN price_amount, DROP COLUMN price_currency_code, DROP COLUMN original_price_amount;
