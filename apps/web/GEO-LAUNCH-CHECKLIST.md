# GEO / SEO / AEO launch checklist

State of play: the on-site work is done (llms.txt, sitemap, robots, JSON-LD, FAQ schema,
niche-question guides, and a three-way comparison article). Every item below needs an
action outside this repo. Sourced from the Gamma GEO playbook, minus the plays that
don't apply to a consumer iOS app (B2B/Copilot, X) and minus the deceptive ones
(fake agent-only discounts).

## Deploy blockers

- [ ] Attach `openmarket.io` to the Vercel project. Every canonical URL, the sitemap,
      and llms.txt point at this domain. Nothing can be indexed until it serves.
- [ ] Replace the TestFlight URL in `lib/site.ts` with the real
      `https://apps.apple.com/...` link once the App Store listing is approved.

## At deploy

- [ ] Register the site in Bing Webmaster Tools and submit the sitemap.
      ChatGPT search runs on Bing, so Bing indexing is the direct path into ChatGPT answers.
- [ ] Register the site in Google Search Console and submit the sitemap.
- [ ] Confirm `https://openmarket.io/llms.txt`, `/robots.txt`, and `/sitemap.xml` serve
      correctly on the live domain.

## First month after launch

- [ ] Post answers to the niche questions the guides cover in mid-size subreddits
      (r/FacebookMarketplace, r/Flipping, city subreddits). Only ChatGPT reads Reddit,
      and niche answers can get cited within days. Small subreddits produce nothing —
      pick ones with real traffic.
- [ ] Add a "Where did you find us?" question to app onboarding. ChatGPT referrals
      don't show in click analytics; self-reported attribution is the only measure.
- [ ] Start a citation-tracking spreadsheet: for each target phrase ("marketplace
      location filter not working", "openmarket vs offerup", ...) record whether
      ChatGPT / Google AI / Perplexity cite us, and the date checked.

## Recurring (quarterly)

- [ ] Re-check every tracked citation. Citations decay in ~3 months; re-win lost
      phrases with a content refresh or a new Reddit post.
- [ ] Re-verify factual claims in the guides: OfferUp's fees (12.9% / $1.99 min as of
      Aug 2026), Marketplace feature-absence claims ("no only-new filter"), and the
      observed location-filter behavior. Stale claims are both an accuracy risk and
      a legal risk.
- [ ] Watch for copycat sites/ads on the "Openmarket" name once the app has traction.

## Later bets

- [ ] YouTube: short demo videos with titles written the way people type prompts
      ("how to search facebook marketplace by distance"). Views don't matter; titles do.
- [ ] A Claude app / MCP connector for Price Check or listing search — the strongest
      play for Claude, which rarely cites web content.
- [ ] Instagram/LinkedIn presence as those channels start feeding LLM answers.
