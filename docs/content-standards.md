# Openmarket Content Standards

Working reference for anyone writing for the Openmarket blog — staff or freelance. Covers how we write, how we stay out of trouble, and how we get found.

Not legal advice. When a piece makes an unusually strong claim about a competitor, route it past counsel before publishing.

---

## 1. Core principles

**We are a competitor writing about competitors.** That means our comparative claims are commercial speech and we carry the burden of substantiating them. Every factual statement about another product must be something we can prove on demand.

**Facts get sourced. Opinions get labeled.** Body text carries verifiable, sourced claims. Interpretation lives in clearly marked sections — "Our take," "Why we think this happens" — with hedged language.

**Date everything.** Product behavior changes. A dated observation stays true forever; an undated absolute claim becomes false the moment the other company ships a fix.

**Never assert intent.** We do not know why any company made a decision, and claims about corporate motive are unverifiable and legally exposed. Stack the verifiable facts and let the reader draw the conclusion.

**Product behavior, not people.** No naming executives. No characterizing individuals' motives.

**Be genuinely useful.** Thin competitor-bashing ranks briefly and converts badly. Every piece should be worth reading by someone who will never install our app.

---

## 2. Phrasings to avoid, and what to write instead

| Don't write | Write instead |
|---|---|
| "Meta deliberately buries local listings to make money" | "Meta charges 10% on shipped orders [source]. Shipped listings appear regardless of radius [observed, dated]." |
| "The distance filter never works" | "In our sample of N searches on [date], X% of results fell outside the set radius." |
| "Marketplace is full of scams" | "ProPublica documented [specific findings] in its [year] investigation [link]." |
| "Up to a fifth of listings are ads" | "In N screens captured [date], sponsored units occupied X of Y grid positions." |
| "They don't care about users" | Cut entirely, or move to a labeled opinion section as a hedged inference. |
| "Marketplace is broken" | "This behavior has been reported consistently since [date] across [sources]." |

Banned quantifiers in factual claims: *always, never, all, every, none, completely*. Replace with measured findings.

---

## 3. Risk checklist — run before every publish

- [ ] Every factual claim about a competitor is sourced or from our own dated testing
- [ ] No claims about anyone's intent, motive, or state of mind stated as fact
- [ ] No absolute quantifiers in factual claims
- [ ] Opinion sections visibly labeled and hedged
- [ ] "Last verified" date at the top
- [ ] Methodology section if the piece contains original testing (sample size, dates, app versions, locations, search terms)
- [ ] Screenshots redacted: seller names, profile photos, user content, faces, addresses
- [ ] Every screenshot logged in `apps/web/captures/README.md` with its session metadata
- [ ] No competitor logos, brand colors, or lifted design assets in headers/OG images
- [ ] Non-affiliation disclaimer in footer
- [ ] Correction log present (even if empty)

**Trademark hygiene.** Competitor names in headlines and body text is nominative fair use — fine. Competitor names in our domain, product name, app store listing, or social handles is not. Never "Openmarket for Facebook."

**Standard footer disclaimer:**
> Openmarket is not affiliated with, endorsed by, or sponsored by Meta Platforms, Inc. Facebook and Facebook Marketplace are trademarks of Meta Platforms, Inc., used here for identification and commentary only.

**Positioning note.** Articles carry competitor keywords; the brand does not. Homepage, app store copy, and investor materials describe Openmarket on its own terms. We are "the local marketplace that respects your radius," not "the Facebook Marketplace fix." That's portable; the other isn't.

---

## 4. Article structure

Every piece follows roughly this shape:

1. **H1** — the question as a searcher would type it
2. **Last verified line** — date, app version, test location
3. **Direct answer in the first two sentences.** Non-negotiable. This is the block that gets extracted into AI answers and featured snippets.
4. **Quick reference table** — scannable summary
5. **Body** — H2s phrased as literal questions, one idea each
6. **Practical/workaround section** — this is what earns links
7. **Structural close** — why the problem persists; positioning without pitching
8. **FAQ** — 4–6 questions, each answered in 1–3 sentences
9. **Methodology + correction log + disclaimer**

---

## 5. SEO / GEO

Same content serves both, but the emphases differ.

**For search engines:**
- One primary query per piece; don't cannibalize across articles
- H2s as literal search questions
- Internal links between related pieces (pillar → supporting)
- Descriptive alt text on every screenshot
- Title tag under ~60 chars — often shorter than the H1

**For AI answer engines (the higher-leverage half right now):**
- **Answer in the first 40 words.** Extraction happens at the top.
- **Publish original numbers.** Restating what others said gets you nothing in a generated answer. Original research is the single strongest GEO asset we have.
- **Coin terminology.** Named concepts get attributed, and attribution is a citation. "Radius leakage" is ours — use it consistently.
- **Tables and lists.** Structured data extracts cleanly; prose walls don't.
- **Methodology sections double as substantiation and as citation-worthiness.** Same artifact, both jobs.
- **Be evenhanded in comparisons.** Say where we're worse. Honest tables get cited; promotional ones get skipped.

**Off-site.** Participate in relevant communities as real people, not as drive-by promotion. Reddit especially will notice and punish the latter.

---

## 6. Article backlog

Ordered roughly by priority.

**Flagship / pillar**
1. Why Facebook Marketplace Shows You Items Outside Your Distance Filter *(drafted)*
2. Why Facebook Marketplace Search Is So Bad — broad pillar, links to all supporting pieces

**Original research — highest GEO leverage**
3. We Ran 500 Marketplace Searches in 25 Cities: How Often the Radius Fails — publish methodology + downloadable dataset
4. How Much of the Marketplace Grid Is Actually Local? — sponsored/shipped/local composition study

**Supporting explainers**
5. Facebook Marketplace Filters Reset When You Change the Price — And 6 Other Search Behaviors That Waste Your Time
6. Why the Same Marketplace Listings Keep Reappearing — the delete-and-relist cycle, explained from the buyer's side
7. Facebook Marketplace Isn't Local Anymore — Here's the Math — the 70/30 split and the 10% shipping fee
8. Why Marketplace Is Full of Dropshippers Now — Temu/Amazon-refugee angle, very current, no good coverage exists

**Product-adjacent / high intent**
9. How to Tell If a Facebook Marketplace Price Is Fair (When There's No Sold-Price History) — include category depreciation tables
10. How to See Only Local Listings on Facebook Marketplace — practical, links from #1

**Comparison**
11. Facebook Marketplace Alternatives That Are Actually Local — evenhanded table, state where we're weaker

**Notes on the backlog.** Items 3 and 4 have the longest half-life; the explainers age fast as Meta ships changes, so they need quarterly re-verification. Item 11 is the highest-converting page and also the one most likely to draw scrutiny — hold it to the strictest reading of Section 3.

---

## 7. Maintenance

Re-verify every competitor-behavior article quarterly. Update the "last verified" date, log any behavior changes in the correction log, and re-capture screenshots if the interface has changed. An article claiming a bug that no longer exists is both a credibility problem and a substantiation problem.