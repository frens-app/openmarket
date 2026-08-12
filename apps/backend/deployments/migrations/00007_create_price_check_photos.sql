-- +goose Up

-- The photo cap rose from one to three, and migration 00004 said what that
-- costs: "Raising that cap is the migration that replaces these four columns
-- with a `price_check_photos` child table keyed on (price_check_id, ordinal)."
-- This is that migration.
--
-- Still no image bytes anywhere. What is kept is the shape of each photo, which
-- is what tells "they sent three 4-megapixel photos" from "they sent three
-- thumbnails" when an identification comes back wrong — and the hash, which
-- notices the same image sent twice, now including twice within one request.
CREATE TABLE price_check_photos (
    price_check_id uuid NOT NULL REFERENCES price_checks (id) ON DELETE CASCADE,

    -- Position in the request, from zero. Part of the key because order is
    -- meaningful to the model: the first photo is the one the seller led with,
    -- and a set that identified badly is worth being able to reconstruct in the
    -- order it was seen.
    ordinal smallint NOT NULL,

    sha256 bytea NOT NULL,
    bytes integer NOT NULL,
    width integer NOT NULL,
    height integer NOT NULL,

    PRIMARY KEY (price_check_id, ordinal)
);

-- Backfills the single-photo rows, so "how many photos does a check usually
-- carry" is one query over one table rather than two with a union. Only rows
-- that actually had a photo: `photo_sha256` is null on a description-only run.
INSERT INTO price_check_photos (price_check_id, ordinal, sha256, bytes, width, height)
SELECT id, 0, photo_sha256, COALESCE(photo_bytes, 0), COALESCE(photo_width, 0), COALESCE(photo_height, 0)
FROM price_checks
WHERE photo_sha256 IS NOT NULL;

-- The old columns go, rather than being left as a first-photo shortcut. Two
-- places to write the same fact is two places to write it inconsistently, and
-- the shortcut would be wrong the first time somebody deletes a photo from a
-- set.
ALTER TABLE price_checks DROP COLUMN photo_sha256;
ALTER TABLE price_checks DROP COLUMN photo_bytes;
ALTER TABLE price_checks DROP COLUMN photo_width;
ALTER TABLE price_checks DROP COLUMN photo_height;

-- +goose Down
ALTER TABLE price_checks ADD COLUMN photo_sha256 bytea;
ALTER TABLE price_checks ADD COLUMN photo_bytes integer;
ALTER TABLE price_checks ADD COLUMN photo_width integer;
ALTER TABLE price_checks ADD COLUMN photo_height integer;

-- Lossy on the way back, and unavoidably so: four columns cannot hold three
-- photos. The first is restored and the rest are dropped.
UPDATE price_checks p
SET photo_sha256 = f.sha256,
    photo_bytes = f.bytes,
    photo_width = f.width,
    photo_height = f.height
FROM price_check_photos f
WHERE f.price_check_id = p.id AND f.ordinal = 0;

DROP TABLE IF EXISTS price_check_photos;
