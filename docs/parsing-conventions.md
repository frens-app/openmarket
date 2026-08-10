# Parsing conventions

Rules that hold everywhere this project reads Facebook. They exist because every
extractor here is parsing imprecise information off a surface nobody controls,
which fails in ways ordinary parsing does not: not with an exception, but with a
plausible answer.

---

## 1. An unrecognised value is logged, never dropped

**Rule.** When a parser meets a value it does not know how to handle — an
unknown enum token, an unexpected shape, a field that is present but does not
match anything we model — it must say so in the log. Silently skipping it is not
allowed, even where skipping is the right *behaviour*.

Dropping and logging are not alternatives. Drop the value if that is the safe
thing to render; log it regardless. The rule is about what we can find out
later, not about what the user sees now.

**Why this rule exists, concretely.** `delivery_types` was surveyed once and
found to carry four tokens: `SHIPPING_ONSITE`, `IN_PERSON`, `DOOR_PICKUP`,
`PUBLIC_MEETUP`. `Fulfillment(tokens:)` was written to match those four with a
`default: continue` for anything else.

There is a fifth. `DOOR_DROPOFF` appears on roughly one listing in fifteen, and
it is the only token in the vocabulary that means *delivery without shipping* —
the seller brings the item to the buyer, the exact reverse of `DOOR_PICKUP`. The
`default: continue` swallowed it. Nothing failed, no test would have caught it,
and the screen rendered a confident, wrong answer for those listings. It was
found by reading a raw log line and noticing a token that should not have been
there.

That is the failure mode this rule is aimed at. A scraper's unknowns are not
edge cases to be tidied away — they are the only early warning that the site has
changed, and a `default:` that says nothing throws it away.

**What it looks like.**

```swift
default:
    Logger.parse.error("unknown delivery_type: \(token, privacy: .public)")
    continue        // still dropped — but now it is on the record
```

Where the value is a whole array or blob rather than one token, log the raw
input alongside the parsed result, so an unknown is legible even when the parse
"succeeded":

```swift
Logger.detail.info("delivery=\(raw.deliveryTypes?.joined(separator: "+") ?? "nil")")
```

**`.error`, not `.info`.** These are logged at error level even though the app
recovers, because the level is the search filter: `.info` is where the routine
traffic is, and an unknown token has to be findable in a log that already runs
to thousands of lines a session. It is an error about our model of the site,
which is exactly the thing worth being loud about.

**Where this applies.** Every extractor boundary — `DetailExtraction`,
`DesktopPayload`, `CardParser`, `DesktopCardParser`, `CardLabel`, and the JS in
`DesktopScripts` / `WebLiteScripts` that feeds them.

---

## 2. Absent and empty are different, and both are different from a default

`nil` means *this surface did not tell us*. `[]` or `false` means *it told us,
and the answer is nothing*. Never collapse the first into the second, and never
substitute the common case for either.

The delivery badge renders nothing at all when `fulfillment` is nil. The
tempting shortcut was to show "Local pickup", because that is true of most
listings — but a buyer reads a badge as a fact about *this* listing, and being
right on average is not the same as being right. Compare `RawDetail.isSold`,
which is `Bool?` for the same reason: a page that never said is not a page that
said no.

---

## 3. A value found near the right place is not the right value

Item pages carry ~20 *other* listings' payload objects in the "Today's picks"
rail. Reading the first match in the document, or the nearest one, attributes a
neighbour's data to the listing on screen. This has happened with coordinates,
condition, sold state and photos, each found and fixed separately.

Anchor on a discriminator that identifies the page's own listing —
`"location_text"` is the one in use — and take the value from inside a bounded
window around it. Then **measure that the window contains exactly one match**,
rather than assuming the pattern transfers from the field it was borrowed for.
For `delivery_types`: 21 arrays on the page, `location_text` occurring once, one
array inside the window.
