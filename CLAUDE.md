# Working in this repo

## Comments

This codebase drives an undocumented third-party surface — Facebook Marketplace,
through a hidden `WKWebView`. A lot of what the code does is unguessable without
knowing what was measured, so comments here carry real weight. That is exactly
why they need a budget: when everything is commented, the load-bearing notes are
buried in the ones that aren't.

**Default to no comment.** A good name and a type say it better and never go
stale. Write one when a reader who understands Swift or Go would still be
surprised by what the code does.

### Write a comment for

- **A measured fact about Facebook's behaviour.** Not re-derivable without
  driving the live site, so it belongs next to the code it constrains. State the
  number.
  ```swift
  // Anonymous is one page. Scrolling it was measured at five screens that
  // advanced 0→2410px of a 3188px container with the card count stuck at
  // 20 the whole way — six seconds spent on nothing.
  ```
- **A non-obvious ordering or concurrency requirement**, where moving the line
  would break something silently.
  ```swift
  // Before the guard: an injected engine can start out of step with this
  // object, and the call that would correct it is the one returning early.
  ```
- **A deliberate choice against the obvious alternative**, when the alternative
  looks correct.
  ```swift
  // `object(forKey:)`, not `bool(forKey:)`: the latter returns false for a
  // key that was never written, silently shipping history recording off
  // for every existing install.
  ```
- **An API or framework trap** — a SwiftUI or WebKit behaviour that isn't in the
  docs and cost real debugging time.

### Do not write

- **History.** No "used to", "is gone", "was removed", "the old version". Git
  has it, and `git log -S` finds it. This is the single biggest source of comment
  bloat here — an audit found 119 instances.
  - No tombstones for deleted code. If `reset()` is gone, its comment goes too.
  - Describe what the code **does now** and why. If the discarded alternative is
    genuinely instructive, state it as a constraint ("A pacer per engine defeats
    all three mechanisms below…"), not as a story about a past commit.
- **What the code already says.** `/// Whether onboarding still has something to
  do` over `var needsOnboarding: Bool` earns nothing.
- **The argument for a decision, at length.** State the reason once. Two
  sentences, not five paragraphs. A comment that persuades is a design doc in the
  wrong file — put it in `docs/`.
- **Restatements of `docs/`.** Cite the file and section instead:
  `(docs/filter-parameters.md §3)`. One source of truth.
- **Bare `§` references.** `§3.1`, `§7.3` and friends pointed at a numbered spec
  that isn't in this repo — 36 dead pointers, now removed. Always name the
  document.
- **Rhetorical emphasis.** Sparing `**bold**` on a genuine gotcha is fine. Every
  paragraph opening with one is not.

### Length

Roughly: an inline comment is 1–3 lines. A doc comment on a type or a subtle
method is up to ~10, and only the app's handful of genuinely complex types
(`DiscoverFeed`, `DesktopFeedEngine`, `PlaceChooser`) should reach that. Anything
longer belongs in `docs/`.

Prefer a cross-reference to a repeat. `See DiscoverFeed.scrolledSinceLastTopUp —
same gate, same reasoning.` beats explaining the gate twice.

### Before committing

Ask of each comment you added: *would a competent reader be surprised without
this?* If not, delete it. Re-read comments near code you changed — a stale
comment is worse than none.

## Writing for the site

Anything published under `apps/web` — a guide, landing copy, an FAQ answer —
follows `docs/content-standards.md`. Read it before writing, and run its
Section 3 risk checklist before committing. The constraints there are not
stylistic: we are a competitor writing about a competitor, so every factual
claim about Facebook Marketplace has to be sourced or come from our own dated
testing, and claims about Meta's intent are out entirely.

Guides live in `apps/web/lib/guides.ts`, one object per article. The screenshots
behind their claims live in `apps/web/captures/`, indexed by its README.

## Verifying a change

```bash
cd apps/backend && go build ./... && go vet ./... && go test ./...
```

```bash
cd apps/ios && xcodegen generate && xcodebuild -project OpenMarket.xcodeproj -scheme OpenMarket -destination 'generic/platform=iOS Simulator' build
```

`xcodegen` writes `OpenMarket.xcodeproj` from `project.yml`, which is the source
of truth — never edit the project in Xcode. A stale `Marketplace.xcodeproj` is
also checked in and references files that do not exist on this branch; it is not
the project to build.

The preview daemon cannot start servers from a git worktree, so verify `apps/web`
through build output rather than a running server.
