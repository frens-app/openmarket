# Search relevance research — 2026-10-14

## Search UI experiment withdrawn — 2026-10-15

The live **Filter with AI** search toggle was tried and removed after the user
reported that it felt clunky and ran too many live filtering passes. The app's
Search screen now uses its ordinary search path, without the AI toggle, hidden
result review UI, AI removal counter, or automatic calls to `FilterListings`.
The direct Jev backend endpoint, generated protocol bindings, provider tests,
research scripts, and local benchmark captures remain available for experiments.

### What the implementation established

- The authenticated `SearchService.FilterListings` endpoint accepts up to 20
  cards per call: query, listing ID, title, and headline photo URL. It fetches no
  listing detail pages and calls pinned `jev-1.14.0` directly with multipart images.
- Image preparation uses four workers, a two-second image budget, bounded image
  decoding, Facebook CDN host restrictions, public-IP validation, and JPEG
  resizing/padding. The overall run has a five-second deadline and no retries.
  Existing per-user model limits and usage accounting apply.
- The prototype kept `match` and `unknown`, hid only `mismatch`, retained cards
  on unreadable images or failed requests, and preserved originals for review.
  Ads and distance filtering preceded AI requests. Removal counters deduplicated
  listing IDs across launches and assigned one reason, in ad → distance → AI order.
- One Go-provider smoke run on the saved 14-card `black standing desk` page took
  **479 ms including image download/preparation**, used all 14 images and 15,224
  input tokens, and had an estimated **$0.000639408** inference cost. It returned
  12 mismatches and two matches; one retained converter was a false positive under
  the exploratory labels. This was one server-side run, not mobile end-to-end
  latency or a production percentile. The broader benchmark and limitations follow.
- Before removal, the iOS build and 28 focused tests passed, covering batching,
  cache reuse, pagination, stale responses, failures, toggle races, and exclusive
  removal totals. Backend build, vet, and tests passed as well. Those checks
  established correctness of the implemented behavior, not a satisfactory UX.

### Why live request volume could grow

Code inspection identified several sources of repeated work. Decisions were
cached only for unchanged card content within one search. Rerunning a search,
changing the browser session, or switching AI off and back on reset that cache;
restoring a cached result page could therefore require another live evaluation.
Larger candidate sets were divided into sequential batches of 20.

AI filtering also participated in the existing pagination fill loop. Initial
loading could fetch up to six source pages looking for a visible result, while
a pagination top-up could fetch up to six pages aiming for six visible cards,
subject to the existing time budget. Each new eligible batch required another
evaluation before publication. Strong filtering could therefore increase both
source fetches and Jev calls from a single search or scroll action. The UI waited
for these decisions before displaying cards. These are code-level explanations
consistent with the user's report; no live-session request trace or production
latency distribution was collected to quantify each cause.

If this is revisited, first test an explicit, one-shot action over a fixed set of
already loaded cards, with a per-action request budget and reusable decisions
keyed by query, card content, model version, and policy. Measure calls per user
action and time to usable results alongside accuracy and cost. Keep automatic
pagination outside that experiment. No replacement UI is implemented here.

### Recoverable implementation

[`search-ui-prototype.patch`](search-ui-prototype.patch) preserves the removed
11-file iOS integration, tests, and counter documentation. Its tracked-file base
is commit `1c30433e83b34cb271d922b0c95e41baf5a7a972`; the retained backend and
generated bindings are prerequisites. Reapplication was verified after removal
with `git apply --check tools/probe/jev_filter/search-ui-prototype.patch`.
The patch contains source code only; raw captures and credentials are excluded.

After removal, the iOS build and 15 existing Search pagination/counter tests
passed, along with backend build, vet, and tests. Source inspection confirmed
that the iOS app has no remaining caller of `FilterListings`.

## AI Search integration — 2026-10-15

AI Search now reuses the direct Jev image-filter runner for model-requested search
pages. It supplies the existing card title and thumbnail URL in batches of 20,
keeps match/unknown decisions, and gives the conversation model per-card verdicts
and image-use flags. Failed evaluations withhold the entire source page. The
existing two-source-page budget and duplicate-result protection remain in force;
there is no automatic pagination loop driven by the filter. The ordinary Search
screen remains disconnected from image filtering. See [the AI Search spec](../../../docs/ai-search.md).

## Direct TypeSafe follow-up

The user supplied `JEV_API_KEY` in the backend environment after the Gateway
research. Direct calls to `https://api.typesafe.ai/v1/systemone` successfully
processed images with `TypeSafe-Danger-Zone-Images: true`. Five synthetic controls
passed, including red/blue/green recognition and two independent question-local
photos. Every response returned the requested pinned model version.

The fixed benchmark made 63 further requests: seven method/version combinations,
three saved pages, three repeats. The same 43 titles, JPEGs and frozen labels
were used. Photos were sent by multipart, once in each candidate's question;
the shared state contained only the search query. No long-context flag, listing
detail retrieval, prompt tuning after results, or production change was made.

| Method | Median API ms | USD per 14–15-card page | Precision | Recall |
| --- | ---: | ---: | ---: | ---: |
| Jev 1.14, current text policy | 137 | 0.0000829 | 67.9% | 100% |
| Jev 1.14, descriptor text, 0.8 cutoff | 217 | 0.0001557 | 66.7% | 94.7% |
| Jev 1.14, photos, 0.8 cutoff | 427 | 0.0006253 | 100% | 89.5% |
| Jev 1.14, three-way text, keep unknown | 217 | 0.0001844 | 61.3% | 100% |
| Jev 1.14, three-way photos, keep unknown | 459 | 0.0006539 | 95% | 100% |
| Jev 1.13, descriptor text, 0.8 cutoff | 201 | 0.0001557 | 91.7% | 57.9% |
| Jev 1.13, photos, 0.8 cutoff | 343 | 0.0006253 | 100% | 89.5% |

Precision is the fraction of retained, definitely labeled listings that match;
recall is the fraction of all definitely labeled matches retained. The one
uncertain label is excluded from those rates and tracked separately. Quality
above uses majority decisions, but both Jev 1.14 image methods made identical
keep/hide decisions across all three repeats, so their single-run quality matched.

Policy selected for the withdrawn prototype: Jev 1.14 three-way image decisions,
keeping match and unknown.
It retained all 19 known matches and the uncertain card, removed 22 of 23 known
mismatches, and retained one converter whose title was just "Standing desk".
For the 29 black-standing-desk cards it retained all seven known matches and the
uncertain card, and removed 20 of 21 mismatches, including all six wrong-color
desks. It retained all 12 matching dressers and rejected both nonmatching ones.
The stricter 0.8 image cutoff hid two valid off-white/whitewashed dressers and
the uncertain desk. Keep the threshold/policy separate from the model version:
1.13 and 1.14 text decisions differed materially on this sample.

Adding images to the same three-way 1.14 policy increased median API time from
217 to 459 ms (+242 ms, 2.12×), and estimated cost from $0.0001844 to $0.0006539
(3.55×). That is about $0.65 per 1,000 filtered result pages, with $0.47 of it
incremental image cost. API times include HTTPS upload from this Mac, but not
photo retrieval. The previously measured 272–626 ms image download/preparation
times imply about 0.70–1.14 seconds for that preparation plus direct inference
on these pages; this sum is an estimate, not a measured production latency.

The earlier Gemini photo benchmark had a 3,241 ms median and $0.005583 uncached
page cost: approximately 7× the latency and 8.5× the cost of the three-way Jev
image method. Gemini's cached-repeat mean was $0.00328884, approximately 5×.
The comparison is across different runs/providers and decision interfaces, not
a controlled intrinsic model-speed comparison. On the same labels, Gemini had
100% precision and 94.7% recall; Jev traded one extra mismatch for retaining the
matching dresser Gemini missed.

Total estimated direct inference cost: **$0.0226002 for 68 calls** (63 benchmark
plus five controls), calculated from returned input tokens at the documented
$0.042/M rate; output is free. This is not an invoice. Source pricing and image
contracts: https://docs.typesafe.ai/models and https://docs.typesafe.ai/images.

This is promising evidence for an optional search filter, not proof of broad
production accuracy. Labels remain assistant-authored on a small, reused sample.
Price-comparison pair matching and purchase-advice quality were not tested.
Preserve original results and offer Show hidden; keep results on image/API errors.

Run `python3 -B tools/probe/jev_filter/direct.py controls`, then
`python3 -B tools/probe/jev_filter/direct.py benchmark`, then
`python3 -B tools/probe/jev_filter/analyze_direct.py`. Existing controls are never
overwritten; benchmark resumes only with matching frozen inputs and script.
Raw results, hashed manifest, per-repeat quality and combined review data are
under ignored `build/jev-research/direct-jev/`. No credentials are persisted.

## Original Gateway experiment

Opt-in, billed research harness; not application code. Requests public search
cards without cookies and never opens a listing detail page. Raw cards, image
URLs, photos, model responses and the review output stay under the ignored
`build/jev-research/` directory. Do not commit those raw captures.

The experiment used 43 first-page cards: `black standing desk` in Toronto and
San Francisco and `white dresser` in Toronto, all with a 25 km radius and local
pickup. These are anonymous search samples, not a signed-in production sample.

Labels were assigned by the assistant from titles and photos before listing-level
model outputs. Forty-two labels are definite and one uncertain. Standing desks
mean complete freestanding desks with black work surfaces; converters and
frame-only listings are excluded. Those product-policy assumptions are reviewable,
not objective purchase suitability. The 43 cards are the quality sample size;
repeat calls are not additional independent quality examples.

## Measured findings

- Current Jev text: 291 ms median endpoint time, $0.0000829 per 14–15-card page;
  66.7% precision and 94.7% recall on definite labels.
- Descriptor-aware Jev with the existing 0.8 cutoff: 294 ms, $0.0001557;
  91.7% precision but only 57.9% recall. It hides too many valid cards.
- Exploratory three-way Jev (keep match/unknown): 339 ms, $0.0001844;
  63.3% precision and 100% recall. Color remains unknown without photos.
- Gemini 3.5 Flash Lite text: 1,265 ms, $0.0008628; 67.9% precision,
  100% recall.
- Same Gemini policy plus headline photos: 3,241 ms, $0.005583 per uncached
  page; 100% precision and 94.7% recall. Mean observed cost across cached repeats
  was $0.00328884. This is not a Jev image measurement.
- Original results: 45.2% precision, 100% recall.

Jev's Gateway image paths could not be validly benchmarked. Red, blue, green and
absent-image controls produced identical answers and 371 input tokens. Both
`/v1/evaluate` and `/typesafe/v1/systemone` accepted malformed image assets with
HTTP 200 instead of rejecting them. This supports image assets being ignored on
these routes, not a claim about the underlying Jev model's visual ability.
A direct TypeSafe credential or a verified image-capable Gateway route is needed.
Do not send a Gateway credential to TypeSafe's direct endpoint.

### Gateway follow-up — October 14, 2026, 23:40 America/Toronto

Current upstream SDK source changes the diagnosis from an undocumented image
route to a deployed-provider support gap:

- `@ai-sdk/gateway` 4.0.110 added image file parts on October 8/9:
  https://github.com/vercel/ai/commit/e280aa19ae13cc37b88bd16e516dc8ca15f229be
- `@ai-sdk/typesafe-ai` 3.0.19 added native image support and the required header.
  It was published October 14 at 22:24 Toronto time (October 15, 02:24 UTC):
  https://github.com/vercel/ai/commit/cd724ba012363a8ad6b7d3214a21c2f831bec7ad
- The current TypeSafe provider docs describe image file parts and multipart:
  https://ai-sdk.dev/providers/ai-sdk-providers/typesafe-ai#image-input
- A live request matching Gateway 4.0.114's wire format to
  `/v4/ai/decision-model`, with `stateParts` and the required protocol/model
  headers, returned HTTP 200 for the no-image control (390 ms, 349 input tokens).
  Adding a valid 560×560 PNG returned HTTP 400 (152 ms):
  `'TypeSafe AI decision file input' functionality not supported.`
  Routing metadata records the same rejection on TypeSafe and DigitalOcean.
  This is an adapter rejection, not a visual-model accuracy result.
- Multipart requests to `/typesafe/v1/systemone` returned HTTP 400
  `Invalid JSON in request body`, with and without an image (95–117 ms).
- The previous JSON `assets` tests were accepted but ignored. Switching request
  shape alone is therefore insufficient on the live routes tested.

Reproduce the native Gateway control with
`python3 -B tools/probe/jev_filter/gateway_images.py`.
Raw results: `gateway-v4-image-controls.json` and
`gateway-multipart-controls.json` in the ignored output directory. These four
additional requests are separate from the original benchmark totals above.
Only the successful text control reported a charge ($0.000014658); failed
requests supplied no usage, so their billable cost is not asserted.

Vercel needs to deploy the new TypeSafe image adapter (or equivalent support).
A client SDK update alone cannot fix the live server rejection. Until that is
available, the documented route is TypeSafe's direct API with a separate TypeSafe
credential, PNG/JPEG bytes and `TypeSafe-Danger-Zone-Images: true`; this direct
route was not live-tested here. Our Go application can implement either HTTP
contract without introducing the JavaScript SDK. Underlying Jev version behind
Gateway's `typesafe-ai/jev` alias remains unverified. TypeSafe says images are
supported on both 1.13 and 1.14, so selecting 1.14 alone does not fix this gap.

Endpoint timings are Mac-to-Gateway HTTPS wall time, including request upload,
not pure inference and not mobile end-to-end latency. The three searches took
668–920 ms. Downloading/preparing images at concurrency four took 272–626 ms
per page. There were 18 calls per primary Jev text arm, 9 per Gemini arm and
9 exploratory three-way calls; 63 batches plus 8 capability controls total.
The provider-reported total inference charge was $0.04343481. Gemini uses BYOK:
a zero Gateway charge is not a zero provider charge; analysis includes market
cost. Repeated Gemini image calls received implicit cache discounts.

No independent human annotation, held-out test set, production p95, or general
accuracy claim follows from this small exploratory sample. The descriptor policy
was specified after inspecting cards but before model outputs; the three-way
and Gemini-text arms were added as exploratory follow-ups. Main quality summaries
use per-card majority decisions. Gemini vision varied on two cards across repeats,
Gemini text on nine, and Jev three-way on one. The two boolean Jev arms were stable.

## Reproduction

Requires Python 3, Pillow, network access, and the existing Vercel key from
`apps/backend/.env.local`. It never prints or persists that key.

1. `python3 -B tools/probe/jev_filter/research.py collect`
2. `python3 -B tools/probe/jev_filter/research.py images`
3. Independently label every card in `build/jev-research/labels.json` before
   running model comparisons. Do not reuse labels after recollecting cards.
4. `python3 -B tools/probe/jev_filter/research.py smoke`
5. `python3 -B tools/probe/jev_filter/benchmark.py`
6. `python3 -B tools/probe/jev_filter/followup.py`
7. `python3 -B tools/probe/jev_filter/analyze.py`
8. `python3 -B tools/probe/jev_filter/build_visual.py`

Do not rerun acquisition over an existing labeled dataset. Preserve the whole
output directory under a new name first. Benchmark files skip completed tasks.
The original request/response JSON and labels are retained locally in the ignored
output directory. The exact-color and malformed-image controls are also there.
All calls stop on failure rather than retrying into a source block. The main
benchmark has a $1 reported market-cost ceiling; the follow-up is a fixed 18 calls.
