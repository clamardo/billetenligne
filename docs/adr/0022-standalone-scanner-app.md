# ADR-0022 — The boarding scanner is a standalone app

**Status:** Accepted · **Date:** 2026-08-09
**Supersedes:** the "conductor mode ships inside the traveller app, role-gated" decision in `01-feature-spec.md` §1 (S2) and ADR-0009
**Related:** ADR-0007 (ticket security), ADR-0011 (RBAC), ADR-0013 (identity)

## Context

The original plan put conductor mode inside the traveller app, unlocked by a role. One binary, one pipeline, less to maintain. On review that is wrong, and the reasons are not close.

The two are not the same product wearing different hats. They differ in who owns the device, who owns the update schedule, what permissions are needed, and what happens when one is compromised.

| | Traveller app | Boarding scanner |
|---|---|---|
| **Device owner** | The traveller, personally | The **operator** — a shared handset kept at the coach door |
| **Who installs it** | Anyone, from Play | A station manager, once, per device |
| **Update cadence** | Play, whenever the user updates (often never) | Operator schedule, deliberately |
| **Camera** | Once per booking, to scan a claim QR | **Always on**, with torch, for a ten-minute boarding burst |
| **Screen** | Normal | Keep-awake, max brightness, kiosk / lock-task |
| **Data held** | The user's own tickets | **Manifests for every departure on that vehicle** — hundreds of passengers' names |
| **If compromised** | One person's bookings | The ability to mark passengers boarded across a fleet |
| **Store listing** | Public | Private / internal, or sideloaded per operator |

## Decision

**A separate Flutter application, `apps/scanner`.** Not a module, not a flavour, not a role gate.

```
apps/
├─ traveller/   consumer. Search, book, pay, ticket wallet.
├─ scanner/     operator-owned. Boarding validation, offline.  ← this ADR
├─ console/     Flutter Web — operator back office
└─ admin/       Flutter Web — BilletEnLigne
```

It shares `bel_domain`, `bel_design`, `bel_localization` and `bel_contracts` like every other surface — so this costs far less than it appears. What it does *not* share is a binary, a permission set, a credential or a release train.

### Why the size argument alone settles it

ADR-0009 sets a hard **15 MB per-ABI APK budget**, because the target user is on an Android Go phone buying 500 MB data bundles.

Bundling the scanner into the traveller app adds, for **every traveller**:

- a camera + ML barcode pipeline (several MB)
- Ed25519 verification and its dependency
- an offline manifest store and its schema
- kiosk/lock-task and screen-wake plumbing

That is a permanent tax on 100% of users to serve well under 1% of them, paid in download size on a metered connection. We would be spending the poorest users' data budget on a feature they will never open.

### Why the permission argument settles it twice

A consumer ticketing app that requests always-on camera, torch control, keep-screen-awake and lock-task mode looks like spyware, and every permission prompt is a conversion loss (ADR-0009). The scanner needs all of them and is installed by a station manager who expects them.

### Credentials, and why separation is a security property

Conductors sign in with a **dispatcher-issued pairing code**, scoped to assigned departures and expiring at end of shift (ADR-0013). That credential lives only in the scanner app.

Keeping it out of the consumer binary means a compromised or repackaged traveller app has no path to boarding validation, and no code to reverse-engineer for it. A single binary holding both a passenger's wallet and a fleet's boarding authority is a needless concentration of risk.

### The scanner's own shape

- **Offline first, absolutely.** Manifest pinned per departure; verification is a local signature check plus a local redemption log; verdict in under 2 s with no network (ADR-0007). Redemptions queue through the outbox and sync opportunistically.
- **`plein soleil` is the default theme**, not an option (`05-design-system.md` §2.3).
- **One screen.** Camera fills it; a verdict replaces it full-bleed. No navigation, no tabs, no settings buried in a drawer.
- **Manual boarding by reference or name** against the offline manifest, for a dead passenger phone. Never leave a paying passenger at the roadside because of our technology.
- **Distribution:** private Play listing plus a **directly downloadable APK**, because agencies install these from a local file — a real channel here, not a fallback.
- Targets even weaker hardware than the traveller app: these are often the cheapest handset the operator owns.

## Alternatives considered

| Option | Verdict |
|---|---|
| **Same binary, role-gated** (the original plan) | One pipeline, and wrong on size, permissions, credentials, device ownership and update cadence simultaneously. **Reversed.** |
| **Flutter flavour of the traveller app** | Solves size, but keeps one codebase whose two halves share almost no screens, and flavour drift is a familiar source of "it worked in the other flavour" bugs. Rejected. |
| **A web app in a browser** | No offline camera guarantees, no reliable local storage of manifests, no kiosk mode. Fails the roadside test outright. Rejected. |
| **Dedicated hardware scanners** | Fastest and most robust, and where mature operators land. Hardware cost per door, and it is not where we start. Supported later via the same verification port. Rejected for v1. |

## Consequences

**Good.** The traveller app stays inside its size budget with room to spare. The scanner can request whatever it needs without a consumer explaining a permission prompt. Two release trains that genuinely move at different speeds. The blast radius of either app being compromised is bounded.

**Cost, and we own it.** A second Flutter app to build, sign, distribute and support — a second store listing, a second signing key, a second crash dashboard. Accepted: the shared packages carry the domain, the design system and the wire format, so what is actually duplicated is a thin shell.

**Watch for:** the scanner quietly growing features (revenue reports, schedule editing) because a conductor's phone is convenient. It validates boarding. Anything else belongs in the console.
