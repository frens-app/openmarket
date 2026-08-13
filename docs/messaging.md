# Product messaging — the language we use everywhere

**Date:** 2026-08-13
**Applies to:** the website (`apps/web/`), `llms.txt`, App Store copy, guides,
and any future announcement. `docs/website-strategy.md` covers where messages
go (SEO, page structure); this doc covers the words themselves.

## 1. The three things we brag about

Two taglines, each with its place:

- **"Local listings, with superpowers."** — the descriptive brand line; site
  H1 and OG image.
- **"A better way to marketplace."** — the positioning line; hero lead,
  footer, and the App Store subtitle (27 characters, fits the 30 limit).
  It uses "marketplace" as a verb on purpose — it names the activity, not
  Meta's product, which is also what keeps it clean legally.

Every surface leads with the same three pillars, in the same words. They name
what we introduced or made better — the new things — not the category basics.

| Pillar | The phrase | What's underneath |
|---|---|---|
| 1 | **Filters that work** | Place and radius set together and enforced on-device; sort by newest, nearest, price; the "Only new listings" toggle |
| 2 | **Actually local listings** | Distance enforced against real coordinates; city and distance on every card; walking / driving / transit time per listing |
| 3 | **Price comparisons** | Price Check: what similar items are listed for *and* what recently sold nearby, from a photo or a sentence |

Supporting brags, used after the pillars, never instead of them: no sponsored
posts, saves and recently viewed, native-app speed.

**Not value propositions** (Brian's call, 2026-08-13): storage and privacy
mechanics — "saves load instantly", "works offline", "stays on-device",
"nothing to leak, nothing to sell". These are implementation facts, not
reasons to download. They may appear as plain factual answers where a user
asks (the privacy page, App Store disclosure), never as marketing copy. Saves
and recently-viewed are sold on their utility — a shortlist, a way back to a
listing — not on where the bytes live or how fast they load.

The pillar phrases are stable on purpose — repeated consistent phrasing is
what search engines and LLMs index as "what this product is". Variations are
fine mid-sentence ("location filters that actually work"), but the three
canonical phrases should each appear verbatim on every major surface.

## 2. How we talk about Facebook Marketplace: observation, then improvement

We never attack Marketplace. We state a fact any user has experienced —
neutrally, no adjectives — and then say what we do about it. The pattern:

> **[Observable fact about Marketplace.] [What we do, concretely.]**

The canonical example (use verbatim or near-verbatim):

> Facebook Marketplace frequently shows listings that are in different
> cities. We filter them down to the ones you can actually reach.

The approved observation bank — every fact here is measured and documented in
this repo, which is what keeps the observations safe to publish:

| Observation (the fact) | Our improvement | Evidence |
|---|---|---|
| Facebook Marketplace frequently shows listings that are in different cities. | We filter them down to the ones you can actually reach. | `docs/filter-parameters.md` — the radius parameter changes nothing server-side |
| The distance setting doesn't limit results — a search set to 5 miles can return listings 60 miles away. | Distance is enforced on your device, and every card shows its city and real distance from you. | same |
| Listings show a city, not what it takes to get there. | Walking, driving, and transit time on every listing. | app feature, `README.md` |
| The same listings come back scroll after scroll, visit after visit. | One toggle hides everything you've already opened. | `docs/filter-parameters.md` §8 |
| Sponsored posts are mixed into the feed with the listings. | We filter them out of every feed. | app feature |
| Nothing tells a seller what similar items actually sell for. | Price Check reads nearby listed and recently-sold prices and shows its work. | `docs/status.md`, Seller tab |

Rules for using the bank:

- **State the fact, skip the verdict.** "Frequently shows listings in
  different cities" — yes. "Broken", "useless", "a mess" — never. The reader
  supplies the frustration; we supply the fix.
- **Never speculate about intent.** Not "Facebook wants you to scroll", not
  "designed to waste your time". We describe behavior, not motive.
- **The improvement is concrete and in "we" voice.** "We filter them down",
  "one toggle hides", "distance is enforced on your device" — a verb and a
  mechanism, not "a better experience".
- **Improvement framing, not replacement framing.** We make the marketplace
  people already use work better; we are not a rival marketplace. "Superpowers
  on top of", "adds what's missing" — never "ditch Marketplace",
  "Marketplace killer", or "the ads-free Marketplace".

## 3. Where the Facebook name may appear

(Unchanged from `docs/website-strategy.md` §1; restated here because it
interacts with the observation pattern.)

- **Headlines and H1s never contain "Facebook".** Observations live in body
  copy, feature descriptions, FAQs, and guides.
- Body copy may say "Marketplace" or "Facebook Marketplace" descriptively.
  First mention on a page can be the full "Facebook Marketplace"; after
  that, "Marketplace" reads better.
- Guides are where the sharpest observations go — naming the concrete user
  pain is the point there, and the mark is nominative and fair.
- The standing footer disclaimer stays on every page.

## 4. Words we use, words we don't

| Use | Instead of |
|---|---|
| filters that work | filters that aren't broken |
| actually local listings | no more junk from other cities |
| price comparisons / what actually sold | beat Facebook's prices |
| we filter them down / one toggle hides | Facebook fails to / Facebook won't let you |
| the marketplace your neighborhood already uses | Facebook's platform (as a target) |
| independent app | alternative to Facebook, Marketplace replacement |
| superpowers, adds what's missing | fixes what's broken (outside guides) |

Tone: confident and specific, never sarcastic. Every claim maps to a shipped,
verified feature — the copy's numbers come from measurements in `docs/`, and a
claim that can't cite one doesn't ship.
