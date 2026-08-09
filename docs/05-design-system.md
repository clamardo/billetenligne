# Kilo — the BilletEnLigne Design System

**Status:** Draft v1 · **Date:** 2026-08-09 · **Implements:** ADR-0010 · **Constrained by:** ADR-0009 (device targets), ADR-0008 (bilingual)

*Kilo* — from *kilomètre*. Distance covered, journeys made.

---

## 1. Design principles

Five, in priority order. When two conflict, the higher one wins.

**1 · Legible in sunlight, on a cracked screen, at arm's length.**
The reference viewing condition is not a design studio. It is 11:00 at a gare routière, direct equatorial sun, a 720p LCD with a scratched protector. High contrast is not an accessibility checkbox here — it is the primary functional requirement.

**2 · Every state is designed, especially the slow ones.**
On 2G, *loading* is the common state and *offline* is a normal state. A screen with a beautiful success state and a spinner for everything else is one-fifth designed.

**3 · Money is always unambiguous.**
Amounts get their own type treatment, tabular figures, and never share a line with anything that could be mistaken for a price. Every total is broken down before it is charged.

**4 · Beauty from type, colour, space and shape — not from assets.**
The asset budget forbids photography, gradients and animation libraries. That constraint produces a cleaner, faster-ageing system than a generous one would. Lean into it.

**5 · Confidence over decoration.**
This app asks people with little margin for error to send real money to strangers. It should feel like a bank that likes you, not a startup that wants your attention.

---

## 2. Colour

### 2.1 The palette

Congo's landscape and light, not Congo's flag. Deep forest green for trust and go-forward; laterite ochre for warmth, energy and the roads themselves. Neutrals are warm-tinted — a cold grey ramp reads clinical and cheap on low-gamut screens.

**Brand**

| Token | Light | Dark | Use |
|---|---|---|---|
| `brand.primary` | `#0A6B4F` | `#3FBF8F` | Primary actions, active states, brand surfaces |
| `brand.primaryStrong` | `#075440` | `#2FA87A` | Pressed, emphasis |
| `brand.primarySoft` | `#E4F1EB` | `#0E241C` | Tinted backgrounds, selected rows |
| `brand.onPrimary` | `#FFFFFF` | `#04241A` | Content on primary |
| `brand.accent` | `#D9772F` | `#F0A05C` | Highlights, badges, scarcity, ticket band |
| `brand.accentSoft` | `#FBEEE2` | `#2A1A0E` | Accent backgrounds |

**Semantic state**

| Token | Light | Dark | Use |
|---|---|---|---|
| `state.success` | `#0F7350` | `#3FBF8F` | Paid, valid, boarded |
| `state.successSoft` | `#E2F3EC` | `#0C2620` | |
| `state.warning` | `#8F5800` | `#E8A93C` | Pending, expiring, stale data |
| `state.warningSoft` | `#FDF1DC` | `#2A2008` | |
| `state.danger` | `#B3332B` | `#F0655A` | Failure, cancel, already boarded |
| `state.dangerSoft` | `#FBE9E7` | `#2E1210` | |
| `state.info` | `#1F5FA8` | `#6BA6E8` | Neutral information |

**Neutrals — warm ramp**

| Token | Light | Dark |
|---|---|---|
| `surface.base` | `#FCFAF7` | `#0D110F` |
| `surface.raised` | `#FFFFFF` | `#161B18` |
| `surface.sunken` | `#F2EEE8` | `#090C0A` |
| `surface.overlay` | `rgba(13,17,15,.55)` | `rgba(0,0,0,.65)` |
| `border.subtle` | `#E8E2D9` | `#242B27` |
| `border.strong` | `#CFC7BA` | `#38423C` |
| `content.primary` | `#141A17` | `#F2F5F3` |
| `content.secondary` | `#4C5651` | `#A8B3AD` |
| `content.muted` | `#7A857F` | `#78837D` |
| `content.inverse` | `#FCFAF7` | `#0D110F` |

### 2.2 Rules

- **Semantic names only in application code.** `content.muted`, never `#7A857F`, never `grey500`. Lint-enforced (ADR-0010).
- **Contrast gates, verified automatically:** body text ≥ 4.5:1, large text and interactive boundaries ≥ 3:1. A token pair that fails fails the build.
- **Colour is never the only signal.** Occupied seats carry a pattern *and* a shape difference; state pills carry an icon *and* a word. Colour-blind users, and cheap panels with poor colour separation, are the same design problem.
- **Operator brand colour is contained**, never global — a single accent band on the trip card and the ticket. Fourteen operators cannot each recolour the app.
- **Dark mode is a token swap**, not a per-widget audit. Genuinely useful here: OLED battery saving and night departures at 04:00.

### 2.3 Plein soleil (high-contrast mode)

A third theme, not just a dark/light pair. Toggled manually, and **on by default in conductor mode**: pure `#000` on `#FFF` content, borders at full strength, shadows removed, type weight bumped one step, verdict screens at maximum saturation. It exists because a conductor validating 60 tickets in direct sun is our least forgiving user and the one whose failure is most visible.

---

## 3. Typography

**One family: Inter.** Bundled, subset to Latin + French diacritics (~120 KB across three weights). Never fetched at runtime — a font that arrives over 2G is a font the user watches arrive.

Chosen for: excellent small-size legibility on low-DPI screens, a true **tabular figures** feature, and a large x-height that survives French accents without crowding.

**Tabular figures are mandatory** for every price, time, seat number, countdown and reference code. Amounts that shift width as digits change look untrustworthy, and this app is entirely made of numbers people care about.

### 3.1 Scale

| Token | Size / line | Weight | Use |
|---|---|---|---|
| `display` | 32 / 38 | 700 | Verdict screens, payment result |
| `h1` | 26 / 32 | 700 | Screen titles |
| `h2` | 21 / 28 | 600 | Section headers |
| `h3` | 18 / 24 | 600 | Card titles |
| `bodyLg` | 17 / 26 | 400 | Primary reading text |
| `body` | 15 / 22 | 400 | Default |
| `bodySm` | 13 / 18 | 400 | Secondary |
| `label` | 13 / 16 | 600 | Field labels, eyebrows (+0.4 tracking, caps) |
| `caption` | 12 / 16 | 400 | Legal, timestamps |
| `amountHero` | 30 / 34 | 700 · tnum | The amount being paid |
| `amount` | 17 / 22 | 600 · tnum | Prices in lists |
| `amountSm` | 14 / 18 | 500 · tnum | Breakdown rows |
| `code` | 16 / 20 | 600 · tnum, +2 tracking | Booking refs, OTP, rotating code |

### 3.2 Rules

- **Design against the French string.** French runs 15–25% longer (ADR-0008). No fixed-width buttons; goldens run `fr` and `en` at 0.85× / 1.0× / 1.3×.
- Max line length ~66 characters. Body text never full-bleed on a tablet or console.
- **Never centre more than two lines** of body text.
- Sentence case everywhere except `label`. French title case is not English title case, and getting it wrong reads as a translation.

---

## 4. Space, shape, elevation

**Space — a 4 pt scale.** `space.1`=4 · `2`=8 · `3`=12 · `4`=16 · `5`=20 · `6`=24 · `8`=32 · `10`=40 · `12`=48 · `16`=64. No `EdgeInsets.all(13)`. Screen gutter is `space.4` (16) on mobile, `space.6` on tablet.

**Radius.** `sm` 8 · `md` 12 · `lg` 16 · `xl` 24 · `pill` 999 · `notch` 12 (the ticket cut-out). Default for cards is `lg`; inputs and buttons `md`.

**Elevation — three levels, and borders do most of the work.** Soft shadows render poorly and cost fill-rate on cheap GPUs, so every raised surface pairs a 1 px `border.subtle` with a minimal shadow, and reads correctly even if the shadow is imperceptible.

| Level | Use | Light |
|---|---|---|
| `flat` | Page content | border only |
| `raised` | Cards, sheets | `0 1 2 rgba(20,26,23,.06)` + border |
| `floating` | Modals, dialogs, sticky bars | `0 8 24 rgba(20,26,23,.14)` + border |

---

## 5. Motion

Ceiling **300 ms**, and most things are 160 ms. Every animation respects `MediaQuery.disableAnimations`; `Plein soleil` disables non-essential motion entirely.

| Token | Duration | Curve | Use |
|---|---|---|---|
| `micro` | 120 ms | `easeOut` | Press, toggle, seat select |
| `standard` | 200 ms | `easeOutCubic` | Sheets, expand/collapse |
| `emphasis` | 300 ms | `easeOutCubic` | Screen transitions, verdicts |

**Banned:** looping animation, parallax, decorative particles, spinner-only loading states. Motion exists to explain a change of state, never to entertain. On a 2 GB device it is also a battery tax paid by the poorest user.

**Skeletons, not spinners.** A skeleton that matches the shape of the content arriving is faster-feeling and, unlike a spinner, tells the user what to expect.

---

## 6. Iconography & illustration

- **Icons:** one outline set, 2 px stroke on a 24 px grid, bundled vector, no icon font. A single filled variant for selected states.
- **Illustration:** flat geometric, **two colours maximum**, no gradients, no shadows, SVG, ≤ 4 KB each. Used sparingly — onboarding cards, empty states, verdicts. A coach, a road, a QR, a seat. Nothing that has to be redrawn per locale.
- **No photography** anywhere except the operator's own coach photo, which is user content, capped at 20 KB, and always optional.
- **Operator logos** are bundled vector where we have them, and a generated monogram tile in the operator's accent colour where we do not. This is the difference between a directory that looks maintained and one that looks abandoned.

---

## 7. Components

### 7.1 Foundations

| Component | Variants | Notes |
|---|---|---|
| `KButton` | primary · secondary · tertiary · danger · sizes sm/md/lg | **Every variant has a loading state.** Min height 48 dp, min width never fixed. |
| `KTextField` | text · number · code | Label above, never placeholder-as-label. Error text reserves its line so layout does not jump. |
| `KPhoneField` | — | `+242` prefix, pair grouping, **live operator chip** (*"Airtel détecté"*). The single most important input in the app. |
| `KMoney` | hero · normal · small | Renders `Money` only. Tabular. Never accepts a raw number — this is how we guarantee §1 principle 3. |
| `KStatusPill` | success · warning · danger · info · neutral | Icon + word. Never colour alone. |
| `KStepper` `KDateStrip` `KQuantity` | | 48 dp targets throughout |

### 7.2 Domain components — the ones that carry the product

**`KTripCard`** — the search-result row. Everything in one glance: times, duration, operator with accent band, price, seats left, reliability. Amenity icons truncate gracefully. Sold-out and low-availability are distinct visual states, and *"3 places restantes"* renders only when true.

**`KSeatMap` / `KSeat`** — states: available · selected · occupied · held · blocked · vip. Occupied uses a fill *and* a diagonal hatch. Selected uses `brand.primary` fill *and* a check. Minimum 44 dp effective target at default zoom, pinch to zoom, legend always visible. **The same widget renders in the console designer preview** (`06-fleet-and-routes.md` §3.2) — same code, no surprises.

**`KPriceBreakdown`** — line items, rule, total. The total is `amountHero`. Non-refundable items carry an inline ⓘ. Appears before every commitment, never only at checkout.

**`KCountdownBar`** — the hold timer. Persistent, calm at first, `state.warning` under 2 minutes. Never red until it is genuinely urgent; crying wolf on a countdown teaches people to ignore it.

**`KPaymentMethodTile`** — logo, name, last-used badge, availability with a *reason* when disabled (*"Momentanément indisponible"*, not a grey box). Server-driven list (ADR-0006).

**`KPaymentWaiting`** — the three-step progress rail (*Envoyé → En attente → Confirmé*), operator lockup, countdown, USSD fallback string, and **a sentence attached to every second**. The most important screen in the app (`01-feature-spec.md` §6.2), and it gets its own golden test per rail per locale.

**`KTicket`** — the hero object. A real ticket silhouette: notch cut-outs on both edges, a dashed perforation line, and the operator's accent as a top band. QR panel, rotating 6-digit code below it, and a `voided` overlay treatment. Auto-maxes screen brightness when opened. Renders identically to the PDF (`01-feature-spec.md` §7.2).

**`KVerdict`** — the conductor's full-screen result. One word, `display` type, full-bleed colour, icon, haptic. Readable at arm's length in sun. Five variants: VALIDE · DÉJÀ EMBARQUÉ · MAUVAIS DÉPART · INVALIDE · CODE PÉRIMÉ.

**`KDisruptionBanner`** — persistent, high-contrast, always states *what has already been done for you* before offering choices (`08-disruption.md` §3.2).

### 7.3 Console components

**`KDataTable`** — compact density, sticky header, column sort, inline actions, virtualised. Numeric columns right-aligned and tabular, always.

**`KWizard`** — save-on-every-field, resumable, honest progress. Used by operator onboarding, coach setup, and the refund policy wizard.

**`KTierTimeline`** — the draggable refund-policy editor (`04-payments.md` §7.1) with a live bilingual preview of the sentence the traveller will read. The single best demo asset we have.

**`KSeatMapEditor`** — tap-to-cycle, drag-to-paint, live capacity count, traveller preview.

### 7.4 States — the contract

Every screen defines **five** states, and a screen missing any of them is not done:

| State | Rule |
|---|---|
| **Loading** | Skeleton matching the arriving content. Never a bare spinner. |
| **Empty** | Explains why, and offers the next useful action. Never a shrug. |
| **Error** | Says what happened, whether it is our fault, and what to do. Retry is always one tap. |
| **Offline** | A slim persistent banner, *not* a blocking dialog. Cached content stays usable and is labelled stale. |
| **Success** | Unambiguous, and never auto-dismissed for anything involving money. |

---

## 8. Layout

- Mobile-first, single column. Minimum supported width **320 dp**.
- Content gutter 16 dp; cards 12 dp internal.
- **The primary action is always reachable by thumb** — bottom-anchored, above the safe area, with content padded to clear it.
- Bottom navigation only where there are 3–5 destinations (traveller: Rechercher · Mes billets · Compte).
- Tablet and console: 12-column grid, 1280 dp max content width, `compact` density.
- **Same components, two densities** (ADR-0010 rule 10). Never a parallel component set.

---

## 9. Accessibility — build gates, not review comments

| Gate | Rule |
|---|---|
| Contrast | ≥ 4.5:1 body, ≥ 3:1 large and interactive. Automated token-pair check. |
| Touch target | ≥ 48 × 48 dp, **no exceptions**. Gloves, cracked digitisers, moving buses. |
| Colour independence | Every state carries a second signal. |
| Text scale | Correct at 0.85× to 1.3×, verified by golden. |
| Screen readers | Every interactive element labelled, in both languages. Seat map exposes a semantic grid (`Siège 12A, disponible, 9 000 francs`). |
| Focus | Visible 2 px `brand.primary` ring on every focusable element — essential for console keyboard users. |
| Motion | `disableAnimations` respected everywhere. |

---

## 10. Operator theming — a bounded surface

Operators customise their storefront (`03-operator-lifecycle.md` §2.4). The system has to allow that without letting fourteen brands recolour one application.

**The contract:** an operator supplies a `BrandProfile`, and it can only reach five places.

```dart
final class BrandProfile {
  final Uri? logo;              // ≤ 40 KB, SVG or transparent PNG
  final String monogram;        // generated fallback — never an empty logo slot
  final AccentHue accent;       // ONE OF EIGHT. Not a free colour.
  final HeaderPattern pattern;  // flat | diagonal | waves — generated vector, ~1 KB
  final LocalizedText title;    // fr + en, ≤ 30 chars
  final LocalizedText tagline;  // fr + en, ≤ 60 chars
  final Uri? cover;             // optional, ≤ 120 KB, 16:9
}
```

| Allowed | Forbidden |
|---|---|
| Storefront hero | Buttons, navigation, tab bars |
| 4 px accent band on `KTripCard` | Any semantic state colour |
| Ticket top band + PDF header | Typography, spacing, radius, motion |
| Console header for their own staff | Anything outside these five slots |
| Generated agency QR poster | |

**`AccentHue` is a closed enum of eight pre-verified hues**, not a colour picker. Each is checked at build time against `content.primary`, `surface.raised` and the `plein soleil` theme for ≥ 4.5:1. A free picker guarantees that some operator eventually chooses a yellow that is invisible in direct sun — and it will be invisible on *our* ticket, in *our* app, at the moment a conductor needs to read it. Eight good options beats sixteen million bad ones.

`BrandProfile` is passed explicitly to the five components that accept it. It is **never** injected into the theme, because a theme override is exactly how "just the accent band" becomes a recoloured app six months later.

Defaults are strong enough to skip: no logo yields a monogram tile in the accent hue, no tagline yields the route list. An operator who never opens the Vitrine step still looks maintained.

---

## 11. Governance

- Package `packages/bel_design`, consumed unchanged by all three UI apps (ADR-0004).
- **Goldens are the contract:** every component × light/dark/plein-soleil × fr/en × 3 text scales. Visual regressions fail CI. On a small team this is the only defence against drift.
- A raw `Color(0x…)`, a magic `EdgeInsets` number or a `TextStyle` literal outside the package is a **build failure**, not a review comment.
- Adding a component requires: goldens, both locales, all applicable states, and a line in the component gallery app.
- **The gallery app is a real deliverable** — a Flutter Web page of every component in every state, deployed on every merge. It is how design reviews happen without a designer opening an IDE.
