# openmarket.so — positioning, messaging, and search strategy

**Date:** 2026-08-12
**Code:** `apps/web/` (Next.js 15, App Router, Tailwind 4, fully static build)
**Live preview:** `npm run dev` in `apps/web`, or `make` nothing — it's standalone.

## 1. Positioning: superpowers on Marketplace, not a Marketplace attack

The decision (Brian's call, 2026-08-12): mention Facebook softly — "the fastest
way to browse local listings on Marketplace", "location filters that actually
work" — never as an attack. The site frames Openmarket as **superpowers for
buyers and sellers** on top of the marketplace their neighborhood already uses.

Why not "Facebook Marketplace without the ads" as the headline:

- **Legal surface.** Nominative fair use protects truthful references to
  Facebook Marketplace ("works with", "browse listings on"). It protects far
  less well a brand identity *built on* Meta's mark — headline-level comparative
  branding is what draws a trademark C&D, and the app's architecture (reading
  Marketplace through an embedded browser) means the goal is to not invite
  Meta's lawyers to look at all.
- **App Store surface.** Review looks harder at apps that market themselves as
  wrappers of another service. "Independent local-listings browser with its own
  tools" is also simply the truer description — Price Check, travel times, the
  only-new filter, and the on-device profile store are original work.
- **The comparison keywords are still captured** — in the guides, where
  mentioning Facebook Marketplace by name is editorial and nominative (see §3).

House rules for copy, applied across the site (the full language guide —
pillars, taglines, the approved observation bank — is **`docs/messaging.md`**;
that doc is canonical for wording, this one for where wording goes):

- Headlines and H1s never contain "Facebook". Body copy may say "Marketplace"
  or "Facebook Marketplace" descriptively ("browse Marketplace listings",
  "message in the Facebook app").
- Never disparage; the framing is "adds what's missing", not "fixes what's
  broken" — except in guides, where naming a concrete user pain is the point.
  Where a pain is named outside guides, it is stated as a neutral observation
  followed by our improvement ("Facebook Marketplace frequently shows
  listings that are in different cities. We filter them down to the ones you
  can actually reach.") — pattern and approved facts in `docs/messaging.md` §2.
- The footer carries a standing disclaimer (independent app, trademarks belong
  to Meta, browsing uses your own account) on every page.
- Every feature claim on the site maps to something verified in the app. The
  copy's specific numbers (quarter-second launch, instant re-opens) come from
  measurements in `docs/status.md`.

## 2. Message architecture

**Brand line:** *Local listings, with superpowers.*
**Positioning line:** *A better way to marketplace.* (hero lead, footer, App
Store subtitle — see `docs/messaging.md` §1)

**Message pillars**, verbatim on every major surface: **filters that work**,
**actually local listings**, **price comparisons**.

**One-paragraph description** (kept consistent across the site, llms.txt, and
the App Store copy in `docs/app-store.md` — consistency is what LLMs and
knowledge panels index):

> Openmarket is a free iOS app — a better way to browse local Marketplace
> listings. Buyers get filters that work and actually local listings:
> distance and travel time on every card, saves and recently-viewed, and a
> filter that hides everything they've already seen — with sponsored posts
> filtered out. Sellers get price comparisons via Price Check: an
> asking price backed by what's listed and what's sold nearby, from a photo
> or a sentence.

**Buyer superpowers** (order matters; strongest differentiators first):

| Superpower | Feature underneath |
|---|---|
| Location filters that actually work | place + radius set together, city & real distance per card |
| Know before you go | walking / driving / transit time per listing, honest approximate-area map |
| Only new listings | on-device view-history filter — no marketplace has this |
| Saves that are really yours | on-device profile store, instant offline home screen |
| Recently viewed | listing profiles cached on device, 1-tap return |
| No sponsored posts | sponsored cards filtered from every feed |

**Seller superpowers:** Price Check — photo or sentence in, price out, backed
by nearby listed + sold comps, with ready-to-paste title/description.

**Trust story** (the "how it works" section): your own account, messaging
happens in the Facebook app. This is the honest description and the legal
positioning — it is deliberately *not* a privacy pitch: privacy and storage
mechanics are not the value proposition and stay out of marketing copy
(`docs/messaging.md` §1).

## 3. Search strategy: Google, DuckDuckGo, and LLMs

Three audiences, two indexes: Google has its own; DuckDuckGo and ChatGPT both
lean on **Bing**. So Bing Webmaster Tools is not optional — it is how DDG and
ChatGPT learn the site exists.

### The keyword ladder

1. **Brand** (wins immediately): "openmarket app", "openmarket ios",
   "open market app" (the two-word spelling people will still type).
2. **Category** (site pages): "local marketplace app iOS", "app to browse
   local listings", "price used items app". Landing, /buyers, /sellers carry
   these.
3. **Pain-point** (guides — the growth engine): searches by people angry at a
   concrete problem the app solves:
   - "facebook marketplace location filter not working" → guide, ships
   - "facebook marketplace shows same listings" → guide, ships
   - "how to price used items" / "what to sell used furniture for" → guide, ships
   - "facebook marketplace safe meeting spot" → guide, ships
   Each guide genuinely answers the query first, then lands the product as the
   real fix. This is the nominative home for "Facebook Marketplace" keywords —
   editorial content about the platform, where the mark is unavoidable and fair.

### Why the site is built the way it is

- **Fully static output** — every page prerenders (verified: `next build` shows
  ○/● on all routes). Fast LCP, no JS required to read content; crawlers and
  LLM scrapers get complete HTML.
- **Structured data:** SoftwareApplication + FAQPage on the landing page,
  FAQPage on /sellers, Article + BreadcrumbList on every guide. FAQ answers are
  written as self-contained statements because they get quoted verbatim by
  answer engines.
- **`llms.txt`** at the root: a compact, definitive statement of what Open
  Market is, for LLM crawlers that fetch it (and it costs nothing where they
  don't).
- **The one-paragraph description repeats** across page metas in varied but
  consistent form — repeated consistent phrasing is what makes a model "know"
  what a product is.
- **sitemap.xml + robots.ts** generated from the route table, so new guides
  index without manual steps.

### Launch checklist (manual, post-deploy)

1. Deploy to Vercel, point `openmarket.so` (A/CNAME per Vercel dashboard).
2. **Google Search Console**: verify domain, submit sitemap.
3. **Bing Webmaster Tools**: verify (can import from GSC), submit sitemap —
   this is the DDG + ChatGPT path. Consider IndexNow (Bing's instant-index
   API; a static key file, five minutes of work).
4. Swap `SITE.testflightUrl` in `apps/web/lib/site.ts` for the real TestFlight
   public link.
5. When the App Store release lands: replace TestFlight CTAs with the App
   Store badge + link, and add the App Store URL to the SoftwareApplication
   schema (`installUrl` / `downloadUrl`).
6. Set up `hello@openmarket.so` (referenced from /privacy and /terms).

### Content roadmap (after launch, in priority order)

- "Is Facebook Marketplace down?" — high-volume, recurring, easy to rank.
- Per-category pricing guides ("used couch prices", "used desk prices") seeded
  from Price Check's method — each one both ranks and demonstrates the tool.
- "Best time to post on Marketplace", "why is my listing not selling" —
  seller pain-points feeding /sellers.
- Later, if worth it: per-city pages ("browse listings in Oakland") — only
  once there's real content per city; thin programmatic pages hurt more than
  help now.

## 4. Deploy

Vercel is the primary target (Next.js's native host; zero config). The config
also supports Railway: `next.config.ts` switches to `standalone` output when
`RAILWAY_ENVIRONMENT` is set, so a Railway service with `npm run build` /
`npm start` works without edits.

## 5. Before the site goes public — screenshot pass

Current screenshots in `apps/web/public/screens/` are real captures from the
simulator and contain **real third-party listings** (photos, titles, cities).
The seller-identity shot was cropped to exclude the seller's name
(`travel-time.png`), and no shot shows a personal name or face. Before launch,
decide: either keep real listings (common practice, some risk of a seller
recognizing their couch), or re-stage with own-household items listed by a
test account. The capture path is repeatable: build the app, stage the screen,
`xcrun simctl io <udid> screenshot`.
