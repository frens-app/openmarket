# AI Search product spec

**Status:** First implementation on `codex/ai-search`; live Marketplace and provider validation still required.
**Updated:** 2026-10-01.
**Surface:** New AI Search tab in the native iOS app.

AI Search is a shopping assistant for a user signed in to both Openmarket and Facebook. A user describes what they want in one message; the assistant searches Marketplace, inspects promising listings, and presents product cards with reasons and caveats. Follow-up messages refine the same conversation.

The backend supplies the model's shopping instructions and tools. The model chooses actions, the API returns them to the app, and the app fetches Marketplace information using its existing session and engines. The app sends observations back to the backend, which filters search cards through Jev before continuing the model. The assistant repeats this loop until it can answer or needs clarification.

The first version needs no database storage for conversations or tool execution. Use temporary sessions to prove the search and inspection experience before adding saved history.

## Confirmed design decisions

- Require both Openmarket and Facebook sign-in for assistant work.
- Fetch product details in the background and show inspection status in chat.
- Search with a broad `query` and individually typed filter fields. There is no separate semantic description or nested filter object.
- Jev makes a binary match or non-match decision against the search query alone. It does not decide whether a listing satisfies the full shopping request or needs inspection.
- The assistant chooses which retained listings to inspect and does most nuanced filtering after fetching details.
- Inspection returns the same parsed listing information as tapping a listing in the app.
- Support pagination wherever the existing search path can supply another page.
- Use the device's configured search location and radius. Location is not a model-controlled tool argument.
- Defer database-backed chat history, cross-device conversations, and durable run recovery.

Proposed defaults still to settle are discovery-only scope, concise tool status, and asking clarifying questions only when missing information materially changes the search. Select the conversation model and per-user usage allowance during implementation; this spec makes no provider capability or cost claim.

## First version experience

The tab is labeled **AI Search** and sits alongside Browse and Tools. A signed-out user can see the introduction and draft a request; sending requires both sign-ins. Preserve the draft if sign-in is canceled. Reuse the existing two-step account gate behavior with AI Search copy.

An empty chat shows a composer, the device's current search area, and sample requests. For example: “Find a solid wood desk under $150, at least 48 inches wide.” A user message starts a run: the model and tool calls needed to answer that message. Follow-ups keep context within the temporary session. **New chat** clears the current conversation; there is no history list or cross-device sync in v1.

Show concise progress such as “Searching for desks,” “Filtering results,” and “Checking dimensions,” plus a Stop control. The UI receives structured tool actions and useful status text, not private model reasoning. `display_products` renders one or more native product cards inline. Cards use observed title, price, currency display, image, location, availability when known, and a supported recommendation reason. Important unknowns remain visible. Tapping a card opens the existing detail screen without losing the chat position.

The assistant can finish with a shortlist, ask a question, or explain that it found no suitable options in the results checked. It must not claim a limited search is exhaustive. Plausible products with unresolved details can be shown as possibilities, with the missing facts clearly stated.

Allow one active run per session. A new user message stops the previous run before starting the next. Switching tabs or opening details preserves the session while the app remains alive. Backgrounding pauses frontend work; resumption is best effort while temporary state survives. If the app process or backend session is lost, explain that the session ended and offer to start again.

Assistant-driven purchases, payments, seller messages, offers, saving, background monitoring, and other marketplaces are out of scope for the proposed first version. Existing manual save and Facebook handoff actions remain available from product details. User photo uploads and model analysis of listing photos are deferred; photos still render in the app.

## Search strategy and assistant context

Every model call includes server-owned shopping instructions and tool definitions, the temporary conversation, the full user request, observed tool results, effective search-area context, supported capabilities, and remaining run limits.

The assistant should search for the core product rather than turning the user's entire request into a keyword string. For “a solid wood desk under $150, at least 48 inches wide, with drawers,” start with `desk` and `max_price: 150`. Do not start with `solid wood desk 48 inch drawers under 150`. A distinctive model name can be appropriate for an exact-product request; broad does not mean discarding the product's identity.

Use exposed filters for criteria they directly support. Keep requirements such as material, dimensions, layout, style, and included accessories in conversation context. Inspect promising listings to check those requirements against the full description and parsed attributes. The assistant can use card evidence to prioritize inspection or skip an obvious poor fit, but a short card that omits a requirement is not evidence that the product fails it.

Try alternate broad terms or another page when useful. Avoid piling on adjectives to compensate for incomplete cards. Ask for clarification when needed, and never silently relax a required constraint. Unknown facts remain unknown after inspection if the listing still does not supply them. Seller statements are listing evidence, not independently verified facts.

Treat all listing and seller text as untrusted data. Recommendations must reference observed listing IDs and supported facts. Tool failures cannot become invented successful results, and images the model has not received cannot support visual claims.

## Tool contract

Names and wire types are proposed. Define typed protobuf messages and generate Go and Swift clients using the repository's normal workflow. Model arguments use explicit fields, not arbitrary JSON blobs.

| Tool | Inputs | Frontend action | Backend result to the assistant |
|---|---|---|---|
| `search` | `query`, individual optional fields below, optional `cursor` | Fetch one page using the existing search path, apply supported filters and device search area, and upload card observations. | Run binary Jev filtering against `query`; return matching cards, counts, applied settings, and pagination metadata. |
| `inspect_product` | Known `listing_id` | Run the same detail loading and parsing path used when the user taps that listing, in the background. | Return the parsed details and their observation time to the assistant for assessment against the full request. |
| `display_products` | Ordered known listing IDs, reasons, caveats, optional group title | Render native cards from observed listing data and acknowledge the rendered IDs. | Return a display acknowledgement so the assistant can continue or finish. |

Clarifications and final answers are normal assistant messages. A display acknowledgement means cards were rendered, not that the user saw or accepted them. Inspection and display only accept listing IDs already observed in this session; navigation uses app-resolved listing URLs.

### Individual search fields

These proposed fields map to the existing `SearchQuery` capabilities. Defaults are AI Search defaults, except location and radius, which always come from device settings.

| Field | Type and behavior |
|---|---|
| `query` | Required short keyword string describing the core product. This exact query is also Jev's target. |
| `min_price` | Optional nonnegative integer in the market's major currency units, matching the current search adapter. |
| `max_price` | Optional nonnegative integer in the same units; must be at least `min_price` when both are present. |
| `sort` | Optional enum: `best_match` (default), `newest`, `nearest`, `price_lowest`, `price_highest`. Adapter maps these to existing source values. |
| `delivery` | Optional enum: `any` (default), `local_pickup`, `shipping`. |
| `conditions` | Optional list: `new`, `used_like_new`, `used_good`, `used_fair`; omitted or empty means no condition filter. |
| `listed_within_days` | Optional enum-like integer: 0 (any time, default), 1, 7, or 30. |
| `availability` | Optional enum: `available` (default), `any`, `unavailable`. Unavailable includes pending and sold; neither can be recommended as currently available. |
| `cursor` | Optional opaque handle returned by an earlier search result; omitted for the first page. |

There is no `description`, `filters`, `location`, `city`, coordinate, or radius argument. Product descriptions remain part of inspection results.

The frontend snapshots the user's configured location and radius when a run begins and applies them to every search in that run. Show the area in chat and include a readable summary in model context; this is execution context, not a model-selected location override. If the user requests another area, direct them to existing location settings. If settings change during a run, stop that run and start a new one using the updated area; do not mix pages from different locations. If no location is configured, prompt for it through the existing location flow before searching.

Return the actual applied settings and any unsupported filter behavior. Keep existing client-side radius enforcement. Approximate city-based distance is not a precise product location, and unknown currency or an unparseable price cannot establish that a strict budget is met. Search arguments must not mutate the user's Browse preferences.

### Pagination

The authenticated feed already accepts cursors. Use that capability, with browser fallback pagination only where the existing engine supports it. One `search` call returns one source page; further pages require another model-selected call with the returned cursor and the same query and filter values.

Return `has_more`, `next_cursor` when available, and a pagination status that distinguishes more pages, exhausted results, unsupported pagination, and a stopped or failed fetch. A cursor is an opaque frontend handle bound to the query, normalized filters, device-area snapshot, and Facebook session. Source cursors and authentication material remain on the device. A changed query, filter, location, or Facebook session invalidates continuation; restart at page one.

Deduplicate by listing ID across pages and queries while preserving newer observations. Reuse a Jev decision only for unchanged candidate content and the same query. An all-rejected page or a page containing only duplicates does not imply the source is exhausted: retain `has_more` when the source supports continuation. The model may request another page within its run budget. Repeated cursors and repeated pages without progress must stop rather than loop.

Each retained card includes observed fields, stable listing ID, capture context, and observation time. Return fetched, duplicate, matched, and rejected counts for the page. Split a source page exceeding the Jev batch limit into bounded evaluation batches; do not silently drop its remaining cards. Only expose a successfully evaluated page as filtered. If evaluation fails, return a filtering error rather than a misleading empty page.

### Binary Jev filtering

For every candidate, Jev answers: “Does this listing offer the product described by this search query?” Its target is only the exact `query`, not the full user message, a generated description, or the filter fields. It can read the candidate's available card text; it does not fetch detail pages.

The output is match or non-match. Match means relevant to the broad query, not confirmed to satisfy the shopper's request. Reject clearly unrelated products and accessory-only offers when the query requests the main product. Do not reject a plausible desk merely because its card lacks material or dimensions. For query `desk`, both solid wood and particleboard desks may pass; the assistant checks material after inspection.

Reuse the existing Jev transport, boolean probability handling, response validation, and accounting with query-specific criteria. There is no three-state classifier, inspection-status label, attribute evidence schema, or second Jev pass on details in v1. The current comparable threshold of 0.8 is a starting candidate to evaluate, not a proven shopping threshold.

Rejected card bodies stay out of the conversation model's context. Raw bounded batches necessarily reach the backend for Jev evaluation. Invalid or incomplete evaluations fail explicitly and may retry within budget; never silently supply unfiltered cards to the assistant.

### Inspection parity with tapping a listing

`inspect_product` uses the same loader, parser, and resulting listing data as opening the product manually. It must not introduce a separate reduced scraper or require attributes-to-check arguments. Return everything that path actually parsed: description, condition, price, availability, dimensions or other attributes when present, location, posted information, photo references, and available seller information. Missing data remains missing; this contract does not promise fields the current parser cannot extract.

Respect the existing cache and freshness behavior and include observation time. The assistant receives structured/text details, not raw HTML or browser credentials. Photo references support rendering but do not mean the model has viewed the images. Payload truncation must be explicit. The assistant compares these details with the original request, chooses further inspections or searches, and decides what to display with appropriate caveats.

## Temporary execution without chat database storage

Use a bounded, account-owned in-memory backend session for transcript, run state, pending calls, and accepted observations. Keep UI messages, cards, and frontend cursor handles in app memory. A proposed inactivity timeout is 30 minutes; enforce per-session memory and context limits and remove expired sessions. Start with one temporary conversation per app session.

The backend supplies system instructions and retains the authoritative temporary transcript. Client submissions contain user messages or results for issued tool calls; they cannot replace system messages. The API supports starting a session, submitting a user message, reading active status, submitting a tool result, and stopping or clearing the session. It does not need database CRUD for conversations, a history API, migrations for chat tables, or cross-device execution leases.

1. The app starts an authenticated session and submits a message with supported tool versions and the device-area snapshot.
2. The backend calls the model with conversation context and validates its selected actions.
3. The API returns assistant text and typed tool calls with stable session, run, and call IDs. The run waits for the client.
4. The client shows status, executes the actions, and submits observations or typed errors. Search observations pass through backend Jev filtering.
5. Once all calls in the current batch finish or fail, the backend supplies their results to the model and returns its next response.
6. Repeat until an answer, a clarification, cancellation, failure, or a limit. Follow-up user messages start new runs within the surviving session.

Use status reads to show planning, searching, filtering, inspecting, or displaying progress during work. Streaming is optional. Multiple independent calls may be returned together, but source work executes serially through the shared request pacer. Dependent actions wait for a later model step. Coordinate engine ownership so background inspection does not interrupt manual browsing or Price Check.

Cache request IDs and completed call outcomes in session memory to avoid duplicate execution or cards on ordinary retries. Reject unknown calls, other users' sessions, and results from stopped runs. If a response is lost, check session status before repeating a costly operation. Cancellation stops queued work and attempts to cancel in-flight requests; already-completed provider work may incur cost.

These guarantees last only while the session survives. A backend restart, deployment, eviction, or app termination may end the conversation. Do not promise exactly-once billing or durable recovery across those events. Use one backend process for the initial rollout, or route a session to the owning process if replicas are required; do not assume arbitrary replicas share memory. A missing session returns an explicit session-ended error and requires a fresh start.

Existing account storage and model-usage accounting remain useful and stay in place. “No chat database” does not remove authentication, usage limits, or `llm_runs` accounting. Consider durable chat storage later if users need saved history, cross-device access, or reliable recovery; none is necessary to validate the first shopping loop.

## Limits and failure handling

Proposed initial limits per user message are 8 model planning calls plus one tool-free closing response, 6 source page fetches across queries, 8 detail fetches, and 6 cards per displayed group. Jev batches contain at most 30 candidates. Allow one retry for a transient failure, counting it against applicable limits. Cap active run time at 120 seconds, excluding paused time. These are starting values to measure, not performance promises.

Apply the existing model usage ceiling to conversation and Jev calls. Enforce run limits in the backend and source limits in the client. At a limit, return useful partial results and explain what remains unchecked. Reserve capacity for a closing response; if it fails, keep existing cards and show a deterministic stop reason.

| Condition | Behavior |
|---|---|
| Either sign-in expires or Facebook presents a challenge | Pause and offer the existing sign-in flow. Do not silently use anonymous search or report no matches. |
| A page has no Jev matches | Preserve pagination metadata; consider another page or broad query within budget. |
| Details cannot be loaded or omit a needed fact | Keep that limitation explicit and inspect other candidates when useful. |
| Jev or the conversation model fails | Return a recoverable service error and preserve existing cards in memory. |
| The app backgrounds or temporarily disconnects | Pause; resume only if app and server session state survive. |
| The temporary session is lost | Explain that it ended and offer a new chat; do not claim it can be recovered. |
| Arguments or cursors are invalid or unsupported | Return a typed error for bounded replanning. |
| The user stops or clears the chat | Invalidate pending actions so late responses cannot restart the run or recreate cards. |

Keep credentials and raw authenticated requests on the device. Bound payload sizes and avoid logging full chats or listing descriptions. Explain that user messages and fetched product information are processed by AI services even though chat history is not stored in the app database. Clear in-memory account content on sign-out and expired sessions. Operational metrics record counts, duration, failures, model identity, and token usage; document new events in [analytics.md](analytics.md).

## Existing foundations

| Area | Existing code | Work needed |
|---|---|---|
| Navigation and sign-in | [`OpenMarketApp.swift`](../apps/ios/Sources/UI/OpenMarketApp.swift), [`AccountGateView.swift`](../apps/ios/Sources/UI/AccountGateView.swift) | Chat tab and state; feature-specific gate copy. |
| Search and pagination | [`SearchQuery.swift`](../apps/ios/Sources/Engine/SearchQuery.swift), [`AuthenticatedFeedClient.swift`](../apps/ios/Sources/Engine/AuthenticatedFeedClient.swift), [`GraphQLFeed.swift`](../apps/ios/Sources/Engine/GraphQLFeed.swift) | Individual tool-field adapter, device-area snapshot, cursor handles, and card uploads. |
| Detail loading | [`DetailEngine.swift`](../apps/ios/Sources/Engine/DetailEngine.swift) and existing listing/detail parsing | Background adapter returning the same parsed data as a manual open. |
| Source pacing | [`RequestPacer.swift`](../apps/ios/Sources/Engine/RequestPacer.swift) | Share pacing and coordinate engine ownership. |
| Jev | [`relevance.go`](../apps/backend/pkg/llm/relevance.go) | Binary candidate-versus-query policy. |
| Model integration | [`pkg/llm`](../apps/backend/pkg/llm) | Conversation/tool continuation interface and usage accounting. |
| API and observations | [`listing.proto`](../protos/openmarket/api/v1/listing.proto), existing authenticated Connect service | Typed assistant operations and temporary session management; review capture-context enums before reusing observation messages. |

## Example shopping flow

1. User: “Find a solid wood desk under $150, at least 48 inches wide, with drawers.” The chat displays the device's configured search area.
2. The assistant calls `search(query: "desk", max_price: 150)`. Location and radius come from device settings.
3. The phone fetches one page. Jev compares each card to `desk`, excludes unrelated chairs and accessories, and returns matching desk cards plus a next-page cursor.
4. The assistant selects promising IDs and calls `inspect_product`. The phone returns the same parsed details the user would see after opening each listing.
5. The assistant finds one desk is particleboard, one is only 42 inches wide, and another description states solid oak, 54 inches wide, and drawers. It excludes the first two from the shortlist and retains the third based on listing evidence.
6. If it needs more choices, it calls `search` again with the same query and price field plus the returned cursor. Each new page receives the same binary Jev filtering.
7. The assistant calls `display_products` and explains why the shortlist fits, labeling any missing information. A follow-up such as “Anything darker?” continues within the temporary session.

## Acceptance criteria and evaluation

- A user with both sign-ins can complete search → Jev → inspect → display → answer, including a follow-up, without chat database storage.
- Marketplace searches and detail loads execute on the frontend. Without frontend results, the backend cannot advance a dependent action.
- The search schema has individually typed fields, no semantic description or nested filters, and no model-controlled location or radius.
- For detailed requests, the assistant starts with a broad core-product query and checks nuanced requirements using detail observations. It does not treat a Jev match as proof that all requirements are satisfied.
- Jev evaluates only relevance to the query and returns binary decisions. A relevant short card survives despite missing dimensions or material; irrelevant card bodies do not enter the assistant context.
- Background inspection returns the same parsed fields as a manual listing open, preserves missing values, and leaves navigation in chat.
- Another page can be requested without changing query, filters, or device area. Empty filtered pages retain valid continuation; invalid and repeated cursors stop safely.
- Ordinary retries within a live session do not duplicate cards or model continuation. Cancellation makes late results inert; state loss is reported as an ended session.
- Account isolation, existing Browse and Tools behavior, shared pacing, and manual product navigation continue working.

Begin with a scripted model and fixture-backed tools to verify ordering, pagination, retry behavior, session expiry, and cancellation. Then integrate the existing search/detail engines and real models. Evaluate broad-versus-overly-specific query behavior, accessory rejection, incomplete cards, nuanced detail constraints, no-match pages with more results, location changes, and instructions embedded in listing text.

Measure time to first useful card, product opens, relevant candidates retained by Jev, unsuitable products excluded after inspection, per-run cost and source request counts, and failure causes. A product open is not evidence of a purchase. Use the baseline to choose launch thresholds and tune limits before broader rollout.

## Implementation notes

The first implementation uses `ShoppingService` in Connect, a bounded in-memory
backend session, native Gateway tool calls, and the iOS AI Search tab. Configure
`AI_GATEWAY_API_KEY` and optionally `SHOPPING_MODEL`; the Vercel Price Check key
is also accepted. The only migration adds `SHOPPING` to existing model usage
accounting. Deployment should use one backend replica or session affinity.

Search cursors stay on the phone. Each active query has its own browser host,
and background inspection has a separate detail engine using the normal parser.
The current parser's `ListingDetail` does not provide separate dimension fields;
those facts reach the assistant when present in the parsed description. Missing
fields remain absent in the API observation. Oversized detail payloads return an
explicit tool error rather than silently truncating evidence.

Validation includes a full scripted search/filter/inspect/display conversation,
Gateway tool response parsing, query-only Jev targeting, cancellation, session
expiry, ownership, cursor binding, Swift filter mapping, and parsed-detail parity.
Live relevance quality and production latency still need evaluation with actual
shopping requests; automated tests do not establish those properties.
