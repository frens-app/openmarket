# Capture archive

Screenshots of Facebook Marketplace, kept as evidence for the claims in
`apps/web/lib/guides.ts`. Every factual statement a guide makes about
Marketplace behaviour has to be sourced or come from our own dated testing
(`docs/content-standards.md` §1), and this is the "our own dated testing" half.
If a claim can't be traced to a row below, it can't be published.

Captures of our own app belong in `apps/web/public/screens/` instead.

## Before you add anything

**Redact first.** Seller names, profile photos, faces, addresses and any user
content come out before the file is committed. Git keeps deleted files forever,
so an unredacted capture that lands here is permanent.

`apps/web/captures/raw/` is gitignored. Stage originals there, redact, save the
result one level up, and the original never leaves your machine.

**A capture without its session row proves nothing.** Marketplace behaviour
varies by market, account history and app version, so a screenshot with no
recorded ZIP, version and date can't substantiate anything.

## Naming

```
YYYY-MM-DD-<surface>-<what-it-shows>-NN.png
2026-08-18-discover-shipped-badges-01.png
2026-08-18-filters-suggested-default-01.png
```

Date first so the directory sorts chronologically. Surface is where it was
taken — `discover`, `search`, `filters`, `item`. The rest describes the thing
the reader is meant to look at, not the thing that happens to be on screen.

## Size

Commit captures already sized down. Two reasons, and the second is the sharp one.

Git keeps every version of a binary forever, and deleting a file does not
reclaim it. Quarterly re-verification means new captures for as long as the
guides exist, so the weight only goes one way.

More immediately: the marketing pages import their screenshots through
`next/image`, which resizes and re-encodes them, so a heavy source file costs a
reader nothing. **Guide images do not go through it.** A guide's body is an HTML
string carrying plain `<img>` tags, so whatever byte size lands in
`apps/web/public/guides/` is exactly what every reader downloads. Five full-res
screenshots is a ten-megabyte article.

Measured on `apps/web/public/screens/home.png`, an untouched device capture:

| | Size |
|---|---|
| As captured | 2.3 MB |
| PNG, 1400px wide | 864 KB |
| JPEG q80, 1400px wide | 224 KB |

```bash
sips -s format jpeg -s formatOptions 80 -Z 1400 in.png --out out.jpg
```

Legibility is the floor, not the target size. A capture whose badge text or
distance label has gone soft substantiates nothing, so check the detail the
caption points at before accepting a conversion.

## Sessions

The setup facts that a guide's methodology section quotes. One row per capture
session; captures below point at a session id.

| Session | Date | App version | ZIP | Distance set | Search terms | Account |
|---|---|---|---|---|---|---|
| `S1` | 2026-08-18 | 574.0.0 | **unrecorded** | **unrecorded** | n/a — Explore, no search | **unrecorded** |
| `S2` | 2026-08-18 | 574.0.0 | **unrecorded** | **unrecorded** | n/a — Explore, no search | **unrecorded** |
| `S3` | 2026-08-18 | 574.0.0 | San Francisco, CA (city-level, as shown) | Suggested (default) | `anthurium` | **unrecorded** |
| `S4` | 2026-08-18 | 574.0.0 | San Francisco, CA (city-level, as shown) | **unrecorded** — chip reads "Distance" with no value | `fitbit air` | **unrecorded** |
| `S5` | 2026-08-18, 21:34 | 574.0.0 | San Francisco, CA (city-level, as shown) | Custom distance, 7 mi | `firbit air` | **unrecorded** |

## Captures

| File | Session | Shows | Supports | Redacted |
|---|---|---|---|---|
| `2026-08-18-explore-shipping-badges-all-cells-01.png` | `S1` | Marketplace Explore. Six full cells and two partial, every one carrying the shipping badge. Prices $28–$85, houseplant category | Shipping listings occupy the Explore grid. **Does not** support any distance claim — see below | Yes. No faces, seller names or addresses. Hands appear in three seller photos |
| `2026-08-18-filters-suggested-default-selected-01.png` | `S3` | The Distance sheet over a search for `anthurium`, location San Francisco, CA. **Suggested** is the selected radio. Presets are 20 / 40 / 60 / 100 miles; Custom distance carries its own slider, shown at 7 mi | The default distance is a named setting, not a mileage. Also: no preset below 20 miles | Yes. No faces, seller names or addresses |
| `2026-08-18-search-suggested-86mi-result-01.png` | `S3` | Results for `anthurium` from San Francisco, one minute after the sheet above and on the same battery reading. Rancho Cordova · 86 mi, Concord · 28 mi, San Francisco · 1 mi. The one shipped cell carries no location line at all | **Under the default, a San Francisco search returned a listing 86 miles out.** The guide's central claim, in a single session | Yes. Nav avatar masked on re-capture; clock and battery left legible so the pairing with the sheet above stays checkable |
| `2026-08-18-filters-custom-distance-set-01.png` | `S5` | The Distance sheet with **Custom distance** selected and its slider at 7 mi, presets unselected. Reset is active, unlike the untouched sheet in `S3` | The after-state of setting a radius. Also shows there is no preset below 20 miles | Yes |
| `2026-08-18-filters-delivery-local-01.png` | `S5` | The **Delivery** sheet: Local (selected), Shipped, All Marketplace | The control that excludes shipped listings. Note the option is "Local" under "Delivery" — not "Local pickup" | Yes |
| `2026-08-18-filters-location-picker-01.png` | `S5` | The **Location** sheet: a search field reading "San Francisco, California" over a map with a dropped pin and an Apply button | Where the measuring point is set. The picker takes a search term and a map pin, so a ZIP or neighbourhood is available but a city name is what it defaults to | Yes |
| `2026-08-18-search-ad-cells-in-grid-01.png` | `S4` | The same `fitbit air` search scrolled on, 10:49. RingConn and WHOOP occupy single grid cells marked "Ad", among listings at San Francisco &middot; 2 mi, 4 mi and Oakland &middot; 15 mi | Ads take listing-shaped cells, not only full rows. The label reads "Ad" — the guide says so rather than "Sponsored" | Yes. No faces, seller names or addresses |
| `2026-08-18-search-ad-unit-in-results-01.png` | `S4` | Search for `fitbit air` from San Francisco. Two organic results carrying real mileage — Oakland · 12 mi, San Jose · 47 mi — then an "Amazfit · Ad" unit with two cells occupying a full row | Paid units sit inside the results list, and carry no distance because they are not listings. Also the first frame with mileage on result cells | Yes. Nav avatar masked on re-capture |
| `2026-08-18-item-shipping-cost-on-55-plant-01.png` | `S1` | Item page for "Anthurium Zara F4 x Debile", $55, **"Ships for $20 + taxes"**, Buy now with Purchase Protection. Same clock and battery as the Explore frame, and the same listing as its top-left cell | Buyer-side shipping cost on a shipped listing — $20 on a $55 item. Ties the `S1` grid to a specific listing. **Not currently used by any guide** | Yes. Seller's hand and desk only, no face |
| `2026-08-18-explore-ebay-partner-cell-01.png` | `S2` | The Explore grid at 1:51, Raven Table Lamp at $36 in the top-left cell. Its corner badge is a different icon from the delivery truck on shipped cells | The partner listing as it appears in the feed, before it is opened. Pairs with the item page below, one minute later on the same battery reading | Yes. No faces, seller names or addresses |
| `2026-08-18-item-ebay-partner-listing-01.png` | `S2` | A Marketplace item page for an eBay product, 1:52 on the same battery reading as the Explore frame below. eBay badge, "Buy now on eBay", an eBay description block, and Facebook's own line: "Facebook may receive a commission on this sale." $35.95, free shipping, no location anywhere on the page | A class of listing that is not a local seller and not a sponsored ad — a retail product carrying no location at all. The commission line is first-party | Yes. No faces, seller names or addresses |
| `2026-08-18-explore-farther-away-badge-01.png` | `S2` | Marketplace Explore, mixed categories, no shipping badges. Top-left cell carries Facebook's own **"Farther away"** badge; a **"Nearby"** badge is partly visible at the bottom edge of the same grid | One Explore grid carrying both distance labels at once — Facebook's own UI stating the feed is not distance-bounded | Yes. No faces, seller names or addresses |

**`S1` cannot substantiate a distance claim.** The frame carries no distance
filter value and no location or city label on any card, so it shows that the
grid was full of shipped listings, not that those listings were far away. The
guide's Screenshot 1 caption claims listings "originating [DISTANCE] miles
outside the set radius"; this capture cannot carry that sentence.

Two more frames from the same session would close it: the filter panel with an
explicit mileage set, and one listing opened to its location. Capture them
together or the pairing can't be claimed.

Note also that this is the **Explore** tab. The guide's caption says Discover.
The caption names the surface the reader is looking at, so one of the two has to
change.

**`S2` is the strongest frame collected so far, and it needs no measurement of
ours.** Facebook labels one cell "Farther away" and another "Nearby" in the same
grid. That is first-party, quotable, and it cannot be argued with — a claim
sourced to the other company's own interface carries none of the substantiation
burden that our measurements do (`docs/content-standards.md` §1).

Its limit: "Farther away" is a relative label with no mileage attached, and the
frame shows no distance filter value. It proves the grid mixes distances. It
does not prove any listing fell outside a set radius.

**`S3` is the pair the guide is built on.** Two frames a minute apart, same
search, same location, same battery reading: the Distance sheet with Suggested
selected, then results running to Rancho Cordova · 86 mi. Neither frame proves
it alone, and nothing about the pairing has to be inferred.

Capture the two halves together every time this is re-verified. A results frame
whose filter state was set in some earlier session proves nothing, however
obvious the reading feels.

`S4` reads the same way but cannot be claimed: its chip also shows no mileage
and its results reach San Jose · 47 mi, but its filter state was never opened,
so "Suggested was set" is inference there. Use it for the ad unit, not for
distance.

## Source records — `reddit/`

Screenshots of third-party posts the guides cite. A different kind of artifact
from everything above: not our observation of Marketplace, just proof that a
source said what we say it said, on the day we read it.

Dates, authors and scores below are read from each post's own
`created-timestamp`, not from the "3y ago" string in the screenshot. Verify that
way — the relative string cannot distinguish June 2023 from May 2024.

A public post under a pseudonymous handle can be shown with its username, and
the crop we publish keeps the attribution visible. Crop to the post itself: the
full frame carries a login sidebar, a related-posts rail, and whichever ad
Reddit served that second.

Keep both files even when a guide cites only one — a source read and set aside
is still part of how the claim was reached.

| File | Thread | Says | Cited in |
|---|---|---|---|
| `2026-08-18-feed-far-items-thread-01.png` | [`14j95p4`](https://www.reddit.com/r/FacebookMarketplace/comments/14j95p4/why_does_marketplace_keep_showing_me_items_that/), u/charcoalritual, **26 Jun 2023**, 18 points, 17 comments | The browse feed showing far-away items with a 20 km radius set, while searches for a specific product behave. Comments name radii from 10 to 209 miles with results outside them | **Published** as a cropped figure in the distance-filter guide |
| `2026-08-18-distance-filter-thread-01.png` | [`1hizqw1`](https://www.reddit.com/r/FacebookMarketplace/comments/1hizqw1/the_distance_filter_doesnt_work_at_all_anymore/), u/42tooth_sprocket, **21 Dec 2024**, 36 points, 27 comments | A filter set to 1 km still returning listings 200 km out, in a city dense enough to fill the page locally | **Not currently cited.** Kept as a second source for the same behaviour — see below |

**`1hizqw1` is cited but not shown, and that is deliberate.** Its post and much
of its comment thread assert why Meta supposedly does this. Running it as a
figure would put an intent claim on our page in someone else's voice, which
`docs/content-standards.md` §1 rules out however it is attributed. Its
observation — 1 km set, 200 km returned — is fine to cite, and the guide does.
`14j95p4` makes the same observation without the motive, which is why it is the
one on the page.

## Wanted

The five the distance-filter guide is blocked on. It ships as a draft until
these exist — see `apps/web/lib/guides.ts`.

| Want | Surface | Must show | Status |
|---|---|---|---|
| The "Suggested" default | `filters` | The distance filter showing its default state | **Have it** — `S3` |
| Shipping listings in the grid | `explore` | Shipping badges on the cells | **Have it** — `S1`, though it proves the badges, not the distance |
| The grid mixes distances | `explore` | Facebook's own distance labels | **Have it** — `S2`, "Farther away" and "Nearby" in one grid |
| Distances under "Suggested" | `search` | Result cells with city or distance labels, in a session where Suggested is confirmed set | **Have it** — `S3`, both halves on disk, one minute apart |
| Sponsored density | `search` | Sponsored cells and banner units across a defined run of consecutive screens. Count them; do not estimate | **Missing** |
| Radius vs drive time | graphic | A straight-line circle over a metro, with the area actually reachable shaded inside it. Not a screenshot | **Missing** |
| The filter panel, after | `filters` | The distance field once it is changed off "Suggested" | **Have it** — `S5`, Custom distance at 7 mi |

## Publishing a capture

Redacted captures here are the archive. A guide loads its own copy from
`apps/web/public/guides/<slug>/`, cropped and named for the article. Copy the
file across rather than pointing the site at this directory — the archive keeps
the full frame that substantiates the claim, and the article wants the crop.

## Re-verification

`docs/content-standards.md` §7 puts every competitor-behaviour article on a
quarterly re-check. A re-check that finds changed behaviour gets a new session
row and new captures; the old rows stay. The point of a dated archive is that
the claim was true on its date, not that it is true now.
