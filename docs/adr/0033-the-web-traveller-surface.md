# ADR-0033 — The web traveller surface is server-rendered, not a Flutter web build

**Status:** Accepted · **Date:** 2026-09-09 · **Depends on:** ADR-0009, ADR-0026 · **Related:** ADR-0002, ADR-0013, ADR-0014, ADR-0022

## Context

The traveller journey — search, results, seat map, hold, pay, ticket, change,
cancel — exists on Android and iOS and nowhere else. It has to exist in a
browser too, and the reason is not convenience:

> *"some phone in africa or india or poor country wont be able to install the
> app"*

That is the requirement, and it is worth restating in its own terms rather
than as "web parity". The person this surface is for has a phone that
**cannot or will not take a 15 MB install**: storage is full, the Play account
is somebody else's, the data bundle is 500 MB a month and an install is a
visible fraction of it, or the handset is one of the Android Go and
budget-KaiOS-adjacent devices this market is genuinely full of (ADR-0002).

For that person the browser is not a fallback. It is the product.

Three facts about this codebase shape the answer:

1. **We already render pages on the server, and the hardest one is done.**
   `services/api/lib/src/infrastructure/web/` is about 1,900 lines: the
   landing page, the storefront (`blt.cg/o/<code>`), the follower page, the
   e-mail shell, an SVG QR encoder, a PNG QR encoder, the accent hues, and
   **`boarding_pass_page.dart` — the ticket itself**, rendered whole, QR
   inline, with no JavaScript at all, because a browser with scripting off
   still has to board somebody at half past five in the morning.
2. **The design system is compiled into the API.** `bel_design`'s tokens,
   patterns and artwork are inlined by those pages already, so a
   server-rendered screen is not off-brand by construction.
3. **The API is the same API.** Nothing about a second presentation layer
   touches the domain, the use cases, the ledger, holds, pricing or
   ticketing. What would be written twice is markup for roughly seven screens.

## Decision

**The web traveller surface is server-rendered HTML, built by extending
`infrastructure/web/`. We do not add a `web/` target to `apps/traveller`.**

The journey is complete — search, results, seat map, hold, pay, ticket,
change, cancel — and not a reduced "sales-only" surface.

### Why not Flutter web, which is the obvious answer

It is the obvious answer and it fails on the one axis this surface exists for.

| | Flutter web (CanvasKit) | Server-rendered |
|---|---|---|
| **First load** | ~2 MB before our code — the WASM canvas engine and the framework | The follower page's budget is **50 KB**; the storefront and boarding pass are in the same range |
| **On a 2 GB Android in Chrome** | Everything is painted to a canvas. Scrolling a results list is visibly worse than HTML on exactly the device class this is for | The browser's own renderer, which those phones are built to run |
| **Organic search** | Renders nothing a crawler can read | Indexable. *"billet bus Brazzaville Pointe-Noire"* is the cheapest acquisition channel a marketplace has, and the storefront is already deliberately indexable |
| **Scripting off, old browser, text zoom, autofill, screen reader** | Degrades to a blank canvas | Degrades to a page |
| **Screens written twice** | None | ~7 |

The last row is the real cost and it is the only one in our favour. We are
paying it, because a 2 MB first load billed to a metered bundle is the
download the person on the other side of this decision cannot afford, and
because the whole argument for the surface collapses if it is slower on a
cheap phone than the app it exists to replace.

**This is the same trade ADR-0022 made in the other direction.** There we
refused to merge two apps because a camera pipeline is a permanent tax on
every traveller to serve under 1% of them. Here we refuse to share one
codebase because a canvas engine is a permanent tax on the users least able
to pay it. Both times the binary budget decides, and both times the answer is
one more surface rather than one cleverer one.

### Two things this forces, and both are improvements

**A real web session.** Known gap #4 says the web `SecureSessionStore` puts an
AES key in `localStorage` beside the value it encrypts, which is obfuscation
wearing the word *secure*, and names the honest alternative: **a same-site
cookie set by the server**. That was an optional slice while web was a
back-office-only concern. It is required now — and it fixes `apps/console` and
`apps/admin` at the same time, where a session still ends when the tab closes.

The refresh token stays on the server. The browser gets an `HttpOnly`,
`Secure`, `SameSite=Lax` cookie and never holds a bearer.

**Offline is a service worker, not nothing.** The ticket must render at a coach
door with no signal. On the web that is a service worker caching the boarding
pass, and it is the standard answer for this market rather than an
improvisation. It has two backstops that already exist: the same QR is in the
e-mail, and the ADR-0026 link resolves from any device.

### What is genuinely different, stated rather than blurred

**The rotating 30-second code.** The app draws a QR *and* a rotating HMAC code,
and the code is what proves live possession — a screenshot forwarded on
WhatsApp carries a valid QR and a dead code.

- **A signed-in web traveller gets it.** The server computes it and the page
  refreshes it. The HMAC secret never reaches the browser.
- **An anonymous ADR-0026 link does not**, and that is not a limitation to fix.
  A link is transferable *by design* — it exists so somebody can forward a
  ticket to the person who is actually travelling — so a possession proof on
  it would be proving the wrong thing.

Everything else on the journey is the same journey.

## Consequences

- `infrastructure/web/` grows from a handful of public pages into the second
  presentation layer of the product, and needs the structure to match: a
  shared shell, a layout vocabulary, and its own render tests.
- The seat map is the one screen that is genuinely interactive. It is emitted
  as SVG — we already emit SVG QR codes from Dart — with selection handled by
  a small amount of vanilla JavaScript. **The no-JavaScript rule relaxes for
  the seat map and stays absolute for the boarding pass**, which is looked at
  once, at the worst moment, where a second chance to fail is not acceptable.
- Two presentation layers drift. The guard is that they consume the same
  contracts and the same catalog, and that the funnel's smoke suite runs
  against both.
- Push notifications stay app-only. The web equivalents are e-mail and SMS,
  which are channels that already exist.
- If Flutter's web story changes such that a 50 KB first paint is achievable,
  this decision is worth revisiting. It is recorded as a budget, not as a
  dislike.
