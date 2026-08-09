# ADR-0010 — "Kilo": one design system, shipped as a package

**Status:** Accepted · **Date:** 2026-08-09 · **Depends on:** ADR-0004, ADR-0009

## Context

Four surfaces (traveller app, conductor mode, operator console, admin back office) built by a small team. Without a shared system they diverge within two months and every screen becomes a negotiation.

The visual constraint from ADR-0009 is severe: no heavy imagery, no elaborate motion, tiny asset budget. That is not a limitation to apologise for — it forces a system built from colour, type, space and shape, which is what actually ages well.

## Decision

**`packages/bel_design`** — a Flutter package named **Kilo**, consumed unchanged by all four surfaces. Full token and component specification lives in `docs/05-design-system.md`; this ADR records the engineering rules.

### Rules

1. **Tokens, not values.** No widget contains a hex colour, a raw pixel number or a `TextStyle` literal. Everything resolves through `context.kilo.color.*`, `context.kilo.space.*`, `context.kilo.text.*`. A custom lint fails the build on a raw `Color(0x...)` outside the package.
2. **A `ThemeExtension`, not a fork of Material.** Kilo rides on top of Material 3 rather than replacing it — we keep accessibility, focus handling and platform behaviour for free, and override appearance through tokens.
3. **Semantic colour names only.** `surface.raised`, `content.muted`, `state.success`, `brand.primary`. Never `green500` in application code. Dark mode is then a token-table swap, not a per-widget audit.
4. **Space is a 4 pt scale**, exposed as named steps. No `EdgeInsets.all(13)`.
5. **One font family**, bundled, subset. Type scale is a closed set of ~9 named styles.
6. **Components own their states.** Every interactive component defines default / hover / pressed / focused / disabled / loading / error. A component that cannot express "loading" is incomplete — on 3G, loading is the common state, not the exception.
7. **Motion budget: 300 ms ceiling**, one easing curve family, and everything respects `MediaQuery.disableAnimations`.
8. **Golden tests are the contract.** Every component has goldens in light + dark × `fr` + `en` × text scale 0.85/1.0/1.3. Visual regressions fail CI. This is the only reliable defence against drift on a small team.
9. **Accessibility is a build gate, not a review comment.** Contrast ≥ 4.5:1 for body text and ≥ 3:1 for large text and interactive boundaries — verified by an automated token-pair check. Minimum touch target 48×48 dp, no exceptions (conductors wear gloves; screens are cracked).
10. **Density variants.** The same components render at `comfortable` (mobile) and `compact` (console tables) density. One component, two densities — not two component sets.

## Consequences

Up-front cost of roughly two weeks before feature velocity picks up, then everything after is faster and consistent. The rule that hurts is #1 — engineers *will* want to hardcode a colour "just this once", which is exactly why it is lint-enforced rather than documented.

Kilo is versioned within the monorepo; a breaking token change is a coordinated change across all four apps in one commit, which is the main practical benefit of the monorepo (ADR-0004).
