# Listing data model — proposal v0.4

**Status:** proposal; no listing persistence or ingest RPC is built.
**Updated:** 2026-08-12.
**Related:** `embedded-payload.md`, `logged-in-findings.md`,
`backend-platform.md` §4–§5, and
`protos/openmarket/api/v1/listing.proto`.

This version replaces v0.2's assumption that every listing is one of two
shapes, "search sighting" or "detail open". What the app receives is determined
by four independent facts:

1. Facebook web variant — desktop or mobile;
2. Facebook page route — search/discover, item, or seller profile;
3. extraction method — embedded structured payload or rendered DOM; and
4. Facebook authentication state — signed in or signed out.

Those are capture context, not listing properties. They belong on observations
and cache keys. The canonical listing is the best non-regressing merge of those
observations.

---

## 1. Verified desktop source matrix

Search and pagination were measured again on 2026-08-12 against a live desktop
search and the signed-in iPhone 17 Pro simulator. The signed-out item row was
also re-checked live; the signed-in item row carries forward the focused
2026-08-05/09 measurements in `logged-in-findings.md`:

| source | observed depth | reliable fields | fields not supplied |
|---|---:|---|---|
| Search, embedded `MarketplaceSearch` payload | first **15** cards (`payload 15/15`) | Facebook listing id, exact `creation_time`, untruncated title, decimal/formatted price, previous price, cover photo, city/place id, delivery tokens, category, sold/live/pending flags | description, item coordinates, seller identity |
| Search, rendered desktop DOM | every currently rendered card; must harvest while scrolling because the feed virtualises | listing id from `href`, rendered title/price/location, cover image URL/filename id | exact listing time, structured delivery/status/category; late signed-in cards also lose `aria-label` and fall back to rendered lines |
| Item page, signed in | one opened listing | description, condition, photos, coarse listed-age text, approximate listing coordinate, delivery/status, seller name/join year/rating/count/badge, stable seller id from `/marketplace/profile/<id>` | no separately verified seller location |
| Item page, signed out | one opened listing | title, price, category, description, condition, photos, coarse listed-age text, approximate listing location/coordinate, delivery/status | seller section and seller id |

The live signed-out search contained 15 rendered cards, 15
`MarketplaceSearchFeedStoriesEdge` objects, and 16 raw `creation_time` mentions.
The extra raw occurrence is why extraction must anchor on feed edges instead of
counting keys globally. In the signed-in app, scrolling moved the grid from 39
to 49 items while the only structured-payload log remained `15/15`: the tail is
DOM data, not another embedded payload.

Mobile remains a separate matrix. Do not infer mobile capabilities from the
desktop rows above. Historical mobile findings are useful inputs, but they have
not all been re-run under the current signed-in product flow.

### The seller-location correction

The item page publishes a city and an approximate coordinate for the
**listing**. That is not evidence of the seller's home or business location.
Store it as `listing_location`. A `seller_location` may be populated only from
text explicitly associated with the seller block or from a seller profile page.
That distinct field is in the observation protobuf, but it is not yet a
verified desktop-item-page capability.

---

## 2. Separate observations from the canonical row

The wire types describe observations:

- `FacebookMarketplaceSearchListingObservation`
- `FacebookMarketplaceListingDetailObservation`
- `FacebookMarketplaceListingObservation` as their `oneof` envelope
- `FacebookMarketplaceObservationContext` carrying the Facebook web variant,
  page route, extraction method, Facebook authentication state, `observed_at`,
  observer device id, and observer app version/build

Do not create four nearly duplicate listing messages for the four rows in the
matrix. The combinations will grow when mobile is re-surveyed, and optional
fields without capture context cannot distinguish "not supplied by this
surface" from "Facebook explicitly supplied an empty value."

Each observation is an immutable snapshot of what one device could see at one
time. The canonical row is a materialized merge for serving product reads. It
must not be treated as a lossless record of what a particular page returned.

The server reconciles snapshots from different routes, extraction methods,
authentication states, devices, and builds. That produces the best **observed
history**, not omniscient Facebook history: seeing `sold = true` at 14:00 proves
the listing was sold by 14:00, but does not establish the exact sale time when
Facebook publishes no sale timestamp.

`observer_device_id` refers to Open Market's `user_devices.id` and is
server-authoritative from the authenticated session. `observer_app_version`
and `observer_app_build` record `CFBundleShortVersionString` and
`CFBundleVersion`; they make parser regressions attributable to a shipped
build. Debug currently pins build `1`, so a later implementation may also want
an explicit parser revision or source revision for local-development captures.

Two timestamps must never share a name:

- `listed_at` — Facebook's exact `creation_time`, when the embedded payload
  supplies it;
- `created_at` — when our database row was created.

Use `observed_at` for the capture time and `updated_at` for our row mutation.
`posted_at` is avoided because it is easily confused with an HTTP post or a
native listing publication event.

---

## 3. Identity

### Internal identity

Every canonical listing gets our UUIDv7 `id`. External identifiers are unique
aliases, never the primary key.

### Observed Facebook listings

Desktop cards expose `facebook_listing_id` in every item `href`, including the
DOM-only tail. Use it whenever present.

`cover_photo_fbid` remains an important cross-surface alias because a mobile
card can have it before the card is opened and before a Facebook listing id is
known. It is parsed from the fbcdn filename and is **not**
`primary_listing_photo.id`; those values differ in measured samples.

The old v0.2 claim that `cover_photo_fbid` must be the sole natural key is no
longer defensible:

- desktop gives the actual listing id cheaply;
- a native listing has no Facebook photo at all; and
- whether a cover photo is always item-page photo zero is still not proven.

Use partial unique indexes instead:

```sql
CREATE UNIQUE INDEX listings_facebook_id_key
  ON listings (facebook_listing_id)
  WHERE origin = 'facebook' AND facebook_listing_id IS NOT NULL;

CREATE UNIQUE INDEX listings_cover_photo_fbid_key
  ON listings (cover_photo_fbid)
  WHERE origin = 'facebook' AND cover_photo_fbid IS NOT NULL;
```

When an observation joins by one alias and supplies the other, attach the new
alias to the existing row. A disagreement is a quarantine/log event, not a
last-writer-wins update.

### Native listings

Native listings are owned by an Open Market user and have neither Facebook key.
They share the canonical read shape but not the ingestion authority.

```sql
origin text NOT NULL,              -- 'facebook' | 'native'
owner_id uuid REFERENCES users(id),
facebook_listing_id text,
cover_photo_fbid text,
CHECK (
  (origin = 'facebook' AND owner_id IS NULL AND
    (facebook_listing_id IS NOT NULL OR cover_photo_fbid IS NOT NULL))
  OR
  (origin = 'native' AND owner_id IS NOT NULL AND
    facebook_listing_id IS NULL AND cover_photo_fbid IS NULL)
)
```

A Facebook observation must be hard-excluded from native rows. "Fill nulls"
is not sufficient protection against cross-origin corruption.

---

## 4. Persistence tables

The DDL below is intentionally directional rather than migration-ready. It
settles names, ownership, presence semantics, and keys before implementation.

### `listings`

```sql
CREATE TABLE listings (
  id                         uuid PRIMARY KEY,       -- UUIDv7
  origin                     text NOT NULL,          -- facebook | native
  owner_id                   uuid REFERENCES users(id),

  facebook_listing_id        text,
  cover_photo_fbid           text,

  title                      text,
  description                text,
  condition                  text,
  dimensions                 text,
  category_path              text[],
  facebook_category_id       text,

  price_minor                bigint,
  price_currency             char(3),
  previous_price_minor       bigint,
  price_changed_at           timestamptz,

  availability              text NOT NULL DEFAULT 'unknown',
  availability_raw           text,
  availability_changed_at    timestamptz,
  delivery_types             text[],

  listing_location_text      text,
  listing_city               text,
  listing_region             text,
  listing_country            text,
  facebook_place_id          text,
  listing_approx_lat         double precision,
  listing_approx_lon         double precision,

  seller_id                  uuid REFERENCES sellers(id),

  listed_at                  timestamptz,
  listed_at_text             text,
  listed_at_precision        text,                  -- exact | day | week | month

  first_observed_at          timestamptz,
  last_observed_at           timestamptz,
  detail_observed_at         timestamptz,

  moderation_state           text,                  -- native only
  deleted_at                 timestamptz,            -- native owner deletion
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now()
);
```

`price_minor = 0` is a real free listing and is distinct from `NULL`. Every
nullable protobuf scalar therefore uses proto3 `optional` presence.

`availability` is preferred over `status`: "status" otherwise has to describe
sold/pending/live, moderation, deletion, and ingestion health at once.

### `sellers`

```sql
CREATE TABLE sellers (
  id                         uuid PRIMARY KEY,
  facebook_profile_id        text UNIQUE,
  display_name               text,
  joined_text                text,
  joined_year                int,
  rating                     real,
  rating_count               int,
  highly_rated               bool,
  seller_location_text       text,
  seller_approx_lat          double precision,
  seller_approx_lon          double precision,
  first_observed_at          timestamptz NOT NULL,
  last_observed_at           timestamptz NOT NULL
);
```

The v0.2 statement "there is no stable seller ID" is obsolete. Signed-in
desktop item pages contain repeated `/marketplace/profile/<id>` links for the
listing's seller. Deduplicate those links and accept the id only when exactly
one unique profile id is associated with the seller section.

Rows observed without that id may be kept as unresolved seller observations,
but must not be permanently clustered on `(name, listing coordinate)`. A
listing's coordinate is not a seller coordinate, and names are not identities.

### `listing_media`

```sql
CREATE TABLE listing_media (
  id                         uuid PRIMARY KEY,
  listing_id                 uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  facebook_photo_id          text,
  storage_key                text,
  kind                       text NOT NULL DEFAULT 'photo',
  position                   int,
  last_source_url            text,
  last_source_url_at         timestamptz,
  first_observed_at          timestamptz NOT NULL,
  last_observed_at           timestamptz NOT NULL,
  CHECK (facebook_photo_id IS NOT NULL OR storage_key IS NOT NULL)
);

CREATE UNIQUE INDEX listing_media_facebook_photo_key
  ON listing_media (listing_id, facebook_photo_id)
  WHERE facebook_photo_id IS NOT NULL;

CREATE UNIQUE INDEX listing_media_storage_key
  ON listing_media (storage_key)
  WHERE storage_key IS NOT NULL;
```

fbcdn URLs are expiring locators, not media identity. Native media uses
`storage_key`; Facebook media can later acquire one if images are cached.

### `listing_observations`

Persist the received snapshots separately from both the current row and its
derived change history. This is the evidence the reconciler consumed and the
place to diagnose a parser/build regression.

```sql
CREATE TABLE listing_observations (
  id                            uuid PRIMARY KEY,
  listing_id                    uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  observed_at                   timestamptz NOT NULL,
  received_at                   timestamptz NOT NULL DEFAULT now(),
  observer_device_id            uuid REFERENCES user_devices(id) ON DELETE SET NULL,
  observer_app_version          text,
  observer_app_build            text,
  facebook_web_variant          text NOT NULL,
  facebook_page_route           text NOT NULL,
  extraction_method             text NOT NULL,
  facebook_authentication_state text NOT NULL,
  payload                       jsonb NOT NULL
);

CREATE INDEX listing_observations_listing_time_idx
  ON listing_observations (listing_id, observed_at);
```

`payload` is the protobuf observation's JSON form and retains field presence.
If raw-observation retention is bounded, `listing_changes` remains the durable
history of accepted price and availability transitions.

### `listing_changes`

Keep the narrow price/availability series from v0.2. It is the reconciled audit
trail for the two volatile fields and avoids pretending that observation time
is an exact Facebook transition time.

```sql
CREATE TABLE listing_changes (
  id                            uuid PRIMARY KEY,
  listing_id                    uuid NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  observed_at                   timestamptz NOT NULL,
  recorded_at                   timestamptz NOT NULL DEFAULT now(),
  price_minor                   bigint,
  price_currency                char(3),
  availability                  text NOT NULL,
  availability_raw              text,
  changed                       text[] NOT NULL,
  facebook_web_variant          text NOT NULL,
  facebook_page_route           text NOT NULL,
  extraction_method             text NOT NULL,
  facebook_authentication_state text NOT NULL,
  observer_device_id            uuid,
  observer_app_version          text,
  observer_app_build            text
);
```

Facebook's raw `is_sold`, `is_pending`, and `is_live` values are stored as one
availability observation. Reconcile `is_sold` and `is_pending` into canonical
`availability` as follows:

| `sold` | `pending` | canonical availability |
|---|---|---|
| `false` | `false` | `available` |
| `false` | `true` | `pending` |
| `true` | `false` | `sold` |
| absent/ambiguous | absent/ambiguous | `unknown` |
| `true` | `true` | invalid observation; log/quarantine |

Do not derive availability from `is_live`: available and sold cards have both
been observed with `is_live = true`.

`highly_rated` records Facebook's rendered “Highly rated on Marketplace”
designation. It is nullable because a capture may not expose the seller
section. It must not be recomputed from `rating` and `rating_count`: Facebook
does not publish the threshold behind its designation.

---

## 5. Merge rules

The governing rule remains:

> A partial Facebook observation can add knowledge or refresh a volatile fact;
> it cannot erase a richer fact.

Apply it per field group:

| field group | merge rule |
|---|---|
| external aliases | attach when absent; quarantine conflicts |
| price and availability | overwrite from a valid newer observation; append a change row when different |
| exact `listed_at` | write from embedded payload; never replace with a coarse rendered estimate |
| title, condition, description | fill gaps; replace only when source policy says the new value is at least as rich |
| seller | attach by `facebook_profile_id`; signed-out absence never clears it |
| listing location | merge as listing data only; never copy into seller location |
| media | upsert by `(listing_id, facebook_photo_id)` or native `storage_key` |
| native owner fields | owner-authoritative; Facebook ingest cannot touch the row |

Authentication belongs in search-result cache keys because it changes the
result set, not just field availability. It also belongs on detail observations
because a missing seller section signed out means unavailable, while the same
result after a fully settled signed-in read is an extraction gap worth logging.

---

## 6. Write paths

Three paths now exist:

1. **Search/discover observation** — batched, partial, high volume. Structured
   first-page observations and rendered tail observations use the same ingest
   endpoint but retain different capture context.
2. **Item detail observation** — one user-opened listing, richer, allowed to
   attach seller and media records.
3. **Native owner write** — authoritative CRUD on `origin = 'native'`; never an
   observation upsert.

The protobuf file defines the first two observation shapes now. Do not define a
Connect service until the persistence transaction and its authorization rules
are implemented; otherwise the IDL would pretend an ingest contract exists
before its semantics do.

---

## 7. Open verification work

1. Re-run the same matrix on mobile, signed in and signed out. Treat it as a new
   Facebook web variant, not a responsive variant of desktop.
2. Verify whether any desktop seller block or seller profile explicitly exposes
   seller location. Until then, `seller_location` stays unset.
3. Verify a card cover-photo filename FBID against item-page photo position 0
   over a meaningful sample before using the alias as anything stronger than a
   join key.
4. Verify conflict behavior: a reused photo alias or parser error must quarantine
   rather than merge two Facebook listing ids.
5. Decide retention for raw observations. The canonical model does not require
   keeping them forever, but a short retention window would make extractor
   regressions diagnosable.

---

## 8. Naming summary

| avoid | use | reason |
|---|---|---|
| `created_at` for Facebook's timestamp | `listed_at` | reserves `created_at` for our row |
| `fb_*` in new schema | `facebook_*` | readable across SQL, Go, Swift, and protobuf |
| `source_page` / `page_kind` | `facebook_page_route` | it describes the parsed URL family, not a generic page class |
| `source_surface` / `surface` | `facebook_web_variant` | names desktop/mobile Facebook markup without implying observer hardware |
| `status` | `availability` | avoids collision with moderation/deletion/ingest state |
| `city` / `latitude` | `listing_city` / `listing_approx_lat` | prevents accidental seller-location inference |
| `seller_id` for Facebook's id | `facebook_profile_id` | `seller_id` remains our foreign key |
| `detail_fetched_at` | `detail_observed_at` | the app observes a page; it does not own Facebook's fact |
