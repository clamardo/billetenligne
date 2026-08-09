# BilletEnLigne — Operator Lifecycle & Back Offices

**Status:** Draft v1 · **Date:** 2026-08-09
**Implements:** ADR-0011 (tenancy/RBAC) · ADR-0013 (auth) · ADR-0015 (policy) · **Related:** `04-payments.md`

---

## 1. Lifecycle states

An operator is a state machine. Every transition is audited, reversible where it should be, and irreversible where it must be.

```
  prospect
     │ invite / self-signup
     ▼
  registered ──────▶ application_draft
                          │ submit
                          ▼
                    under_review ──────▶ rejected (with reasons, re-appliable after 30 d)
                          │ documents ok
                          ▼
                    kyb_verifying ─────▶ info_requested ──┐
                          │ verified                       │ operator responds
                          ▼                                └──▶ back to kyb_verifying
                     approved
                          │ settlement account verified + agreement signed
                          ▼
                  ┌──▶ ACTIVE ◀──┐
                  │      │        │ reinstate
       suspend    │      │        │
                  └── suspended ──┘
                         │ offboard requested (by operator or by us)
                         ▼
                    offboarding  ── existing tickets honoured, no new sales
                         │ last departure flown + final payout settled
                         ▼
                     offboarded  (read-only archive, 7-year retention)
```

**`suspended` and `offboarding` both stop new sales but honour issued tickets.** A platform that strands paying passengers to punish an operator has punished the wrong party. This is the rule that governs the entire second half of this document.

---

## 2. Onboarding

### 2.1 Two entry paths

**Invited** (how the first ten operators arrive): our ops team creates a prospect, the owner receives an SMS + email with a magic link. Pre-fills what we already know. Fastest path.

**Self-signup** (how it scales): `console.billetenligne.cg/inscription`. Company name, owner name, phone, email, city, fleet size. Verified by OTP.

Either way the goal is the same: **the operator should reach "I can see my own dashboard" in under 15 minutes**, even though they cannot sell yet. Nothing kills B2B onboarding like a form that ends in "we'll be in touch".

### 2.2 The application wizard

Six steps, saveable at every point, resumable from any device, with a progress bar that tells the truth about what remains.

| Step | Collected | Notes |
|---|---|---|
| **1 · Entreprise** | Legal name, trading name, RCCM number, NIU (tax id), legal form, registered address, year founded | RCCM/NIU format-validated client-side |
| **2 · Dirigeant** | Owner full name, ID type + number, ID scan, selfie, phone, email | Screened in step 5 |
| **3 · Licences** | Transport operating licence, fleet insurance certificate, technical inspection certificates | **Each with an expiry date** — see §3.3 |
| **4 · Exploitation** | Routes served, fleet size, stations/agencies, typical daily departures | Drives our launch effort estimate |
| **5 · Encaissement** | Settlement account: MoMo Business wallet or bank. Account name must match legal name | Verified by name-check or micro-deposit |
| **6 · Accord** | Commission rate, payout frequency, platform floor terms (ADR-0015), signature | E-signed, PDF archived |

Design rules that matter for this audience:

- **Photograph, don't scan.** Every document upload is camera-first with auto edge-detection. The owner has a phone, not a scanner.
- **Save on every field.** Connections drop. A wizard that loses 20 minutes of typing is never completed twice.
- **Plain French, no jargon.** "Numéro RCCM (registre du commerce)" — not "RCCM".
- **Show what is missing, always.** A persistent checklist: *"Il manque : attestation d'assurance, RIB"*.
- **Never block on a document we can chase later.** Insurance can be provisional at review; it cannot be missing at activation.

### 2.3 Review (admin back office)

The `operations` role works a queue, oldest first, with SLA colouring.

```
┌─────────────────────────────────────────────────────────────┐
│  Demandes d'opérateur                        4 en attente   │
├─────────────────────────────────────────────────────────────┤
│  ⏱ 2 j  Trans Bony Voyages    Pointe-Noire   6 cars   ●●●●○ │
│  ⏱ 1 j  Océan du Nord         Brazzaville   14 cars   ●●●●● │
│  ⏱ 4 h  Sotrapo               Dolisie        3 cars   ●●●○○ │
└─────────────────────────────────────────────────────────────┘
```

The reviewer's screen puts documents on the left and a checklist on the right — no scrolling between the evidence and the decision:

| Check | Automatic | Manual |
|---|---|---|
| RCCM format + uniqueness | ✅ | |
| NIU format | ✅ | |
| Document legibility | | ✅ |
| Licence covers declared routes | | ✅ |
| Insurance valid, covers fleet size, not expired | ✅ expiry / ✅ scope | |
| ID matches owner name | | ✅ |
| Settlement account name matches legal name | ✅ name-check | |
| Sanctions / PEP screen on owner | ✅ | ✅ on hit |
| Duplicate of an existing or offboarded operator | ✅ | |

Outcomes: **Approve** · **Request info** (specific fields, one message, resumes the wizard exactly where the gap is) · **Reject** (reason codes + free text; re-application allowed after 30 days).

**Target: 90% of complete applications decided within 48 hours.** Published to operators. A marketplace that is slow to onboard supply does not grow.

### 2.4 Vitrine — logo, header and brand

Part of onboarding, and editable forever after from **Mon entreprise → Vitrine**. This is the step where an operator stops feeling like a row in someone else's database and starts feeling like their own business on the platform.

```
┌──────────────────────────────────────────────────────────┐
│  Votre vitrine                          Aperçu en direct │
├────────────────────────────────┬─────────────────────────┤
│  Logo                          │  ┌───────────────────┐  │
│  ┌──────────────────────────┐  │  │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  │
│  │  📷  Téléverser          │  │  │  [logo]           │  │
│  │  PNG/SVG · fond transp.  │  │  │  Océan du Nord    │  │
│  └──────────────────────────┘  │  │  Le confort sur   │  │
│                                │  │  toutes les routes│  │
│  Titre (FR)  [Océan du Nord ]  │  │  ★ 4,2 · 92% à    │  │
│  Titre (EN)  [Océan du Nord ]  │  │    l'heure        │  │
│                                │  └───────────────────┘  │
│  Accroche (FR)                 │                         │
│  [Le confort sur toutes les    │  ┌───────────────────┐  │
│   routes du Congo         ] 42/60│ │ 06:00 → 13:30     │  │
│  Accroche (EN)                 │  │ ▌Océan du Nord    │  │
│  [Comfort on every road   ] 22/60│ │ 9 000 FCFA        │  │
│                                │  └───────────────────┘  │
│  Couleur d'accent              │      ↑ dans la recherche│
│  ● ● ● ● ● ● ● ●   (8 teintes) │                         │
│  ⓘ Teintes vérifiées pour le   │  ┌───────────────────┐  │
│    contraste et le plein soleil│  │ ▌ BILLET          │  │
│                                │  │   [logo] 14A      │  │
│  Motif d'en-tête               │  └───────────────────┘  │
│  ○ Uni  ◉ Diagonale  ○ Vagues  │      ↑ sur le billet    │
└────────────────────────────────┴─────────────────────────┘
```

**What the operator controls**

| Field | Constraint | Why the constraint |
|---|---|---|
| **Logo** | SVG preferred, or PNG with transparency. **≤ 40 KB**, auto-downscaled to 3 raster sizes + a monochrome variant | It ships to every traveller's phone on a metered bundle (ADR-0009). A 2 MB logo is a data cost imposed on the poorest user. |
| **Titre** | 30 chars, **FR + EN** | Renders in the reader's language (ADR-0008) |
| **Accroche** (tagline) | 60 chars, FR + EN | Long enough to say something, short enough not to wrap on a 320 dp screen |
| **Couleur d'accent** | **Chosen from 8 curated hues**, not a free colour picker | Every hue is pre-verified against `content.primary`, `surface.raised` and `plein soleil` for ≥ 4.5:1 contrast. A free picker guarantees an operator eventually picks a yellow that is invisible in sunlight. |
| **Motif d'en-tête** | 3 generated vector patterns, or flat | Generated, ~1 KB, themed to the accent. No photography — see below. |
| **Photo de couverture** | Optional, ≤ 120 KB, **16:9, auto-compressed**, never required | Most operators have no usable photography. A storefront that looks empty without one is a broken design. |

**Where it appears** — a bounded surface, deliberately:

- The **operator storefront** in the app: a deep-linkable page (`blt.cg/o/ocean-du-nord`) with the hero, routes served, amenities, reliability score, and the refund policy in plain language. Shareable, and the natural landing page for the operator's own WhatsApp and poster campaigns.
- A **4 px accent band** on the trip card in search results, plus the logo mark.
- The **top band on the ticket** and on the printed PDF.
- The **console header**, so their staff see their own brand all day.
- The **onboarding QR poster** generated for their agencies (§2.3 of `01-feature-spec.md`).

**Where it explicitly does not appear:** the app's chrome, buttons, navigation, or any system colour. Fourteen operators cannot each recolour the application. This boundary is enforced in code, not in a style guide — see `05-design-system.md` §11.

**Live preview is the whole point.** The right-hand pane shows the real widgets — storefront hero, search row, ticket band — rendered by the same components the traveller gets (ADR-0004). An operator sees exactly what a customer will see, before saving. Nothing sells the platform better in a demo.

Defaults are good enough to skip: no logo yields a **generated monogram tile** in the accent colour, and the legal name becomes the title. An operator can complete onboarding without ever opening this step and still look maintained rather than abandoned.

---

### 2.5 Activation — the golden path

Approval does not equal selling. Activation requires, in order:

1. Agreement signed
2. Settlement account verified (name-check or micro-deposit confirmed)
3. **At least one coach with a seat map** configured (`06-fleet-and-routes.md`)
4. **At least one route with a schedule**
5. **A refund policy chosen** — preset counts (ADR-0015)
6. **Vitrine reviewed** — logo and tagline, or the accepted generated default (§2.4)
7. **At least one staff member invited** beyond the owner
8. A **test booking** completed end to end, by the operator, on a real departure, paid with real mobile money and refunded

Step 8 is non-negotiable and it is the highest-value fifteen minutes in the whole relationship. The operator sees the traveller experience, the payment arriving, and the refund working — before a single customer does. Every objection they have surfaces here, where it costs nothing.

A **guided setup checklist** lives on the console dashboard until all eight are green, with time estimates per item and a "reprendre" button. Nobody should have to guess what stands between them and their first sale.

---

## 3. Steady state

### 3.1 Operator console modules

Full module list in `01-feature-spec.md` §10. Governance-relevant additions:

- **Mon entreprise** — legal details, documents, agreement, commission rate (read-only), **Vitrine** (§2.4, editable at any time), settlement account (owner + 2FA + 24 h cooling-off, ADR-0011).
- **Personnel** — invite by phone, assign roles (ADR-0011 matrix), station scoping, revoke instantly. Conductor pairing codes issued and expiring per shift.
- **Conformité** — the operator's own view of their document expiry status, so a lapse is their problem before it is ours.

### 3.2 Health score

Visible to the operator, used by us, and (in simplified form) surfaced to travellers:

| Signal | Weight |
|---|---|
| On-time departure rate | 30% |
| Disruption rate (`08-disruption.md`) | 20% |
| Disruptions resolved without refund | 15% |
| Refund/complaint rate | 15% |
| Manifest accuracy (scanned vs sold) | 10% |
| Document compliance | 10% |

Shown to travellers only as an honest, simple figure — *"92% à l'heure"* — never as a composite score nobody can interpret.

### 3.3 Document expiry — the automated part that earns its keep

Insurance and licences lapse, and **selling seats on an uninsured coach is a liability we will not carry**.

```
T−60 d  reminder to operator
T−30 d  reminder + console banner
T−7  d  daily reminder + SMS to owner + admin queue item
T−0     coaches under that document are BLOCKED from new departures
        existing bookings are honoured; departures within 72 h still operate
T+7  d  operator auto-suspended
```

Automatic, graduated, and impossible to be surprised by. The 72-hour grace exists so a paperwork gap does not strand people who are already travelling.

---

## 4. Suspension

Reasons: expired compliance documents · chronic disruption (> 15% over 30 days) · fraud signals · unpaid negative balance · safety incident · operator request (seasonal pause).

Effects, in this exact order:

1. Departures **stop appearing in search immediately**.
2. **No new sales**, including at agency tills.
3. **All existing tickets remain fully valid.** Departures already sold operate normally.
4. Boarding, scanning and disruption tools keep working — the operator must still be able to run what they already sold.
5. Payouts held pending resolution; the ledger keeps accruing.
6. Operator sees a full-width console banner with the reason, exactly what is required, and a **"Contester"** button.

Reinstatement is `operations` for compliance causes, `super_admin` for fraud or safety causes.

---

## 5. Offboarding

Either side may initiate. Operator-initiated needs `org_owner` + 2FA; ours needs `super_admin` + a written reason.

### 5.1 Wind-down (default 30 days, configurable)

| Phase | What happens |
|---|---|
| **Day 0** | New sales stop. Search delists. Existing tickets valid. Operator notified; passengers with future bookings **beyond** the wind-down window notified immediately and offered a free move or full refund. |
| **Days 0–N** | Operator runs its remaining departures normally, with full boarding and disruption tooling. |
| **Last departure** | Watched by our ops. Any passenger still holding a ticket past the window is auto-refunded in full. |
| **+7 days** | Refund window closes. Outstanding claims settled. |
| **Final payout** | Full reconciliation, statement issued, remaining balance paid. If the balance is negative, an invoice is issued and the case moves to collections. **Payout is never released before the last departure has operated** — that is the platform's only leverage if an operator abandons passengers. |
| **Data export** | Complete export offered: bookings, passengers, manifests, statements, documents. CSV + PDF. Available 90 days. |
| **Archive** | Tenant becomes read-only. PII minimised per retention policy. Financial records kept 7 years. Route and city catalogue entries are retained (shared reference data). |

### 5.2 Emergency offboarding

Reserved for safety incidents, confirmed fraud, or a licence being revoked by the authorities. `super_admin` only, two-person approval.

Immediate: all future departures cancelled, **all affected passengers auto-refunded in full within 24 h**, and — where an inter-operator protection agreement exists (`08-disruption.md` §5) — passengers are offered re-accommodation on another operator **before** the refund is offered. Getting people to their destination beats giving them their money back.

### 5.3 Re-onboarding

An offboarded operator may reapply. Their history is retained and visible to the reviewer. Fraud or safety offboarding sets a permanent block that only `super_admin` can lift, with a written justification stored in the audit log.

---

## 6. Admin back office — the operator-lifecycle view

| Screen | Purpose |
|---|---|
| **File d'attente** | Application review queue with SLA colouring (§2.3) |
| **Opérateurs** | All operators by state, health score, document expiry, disruption rate |
| **Fiche opérateur** | One page: documents, agreement, staff, routes, fleet, revenue, payouts, disruptions, full audit trail. Everything about one operator, no tab-hunting. |
| **Conformité** | Expiry calendar across all operators, screening hits, blocked coaches |
| **Actions** | Approve · request info · reject · suspend · reinstate · offboard — each with a mandatory reason written to the immutable audit log |

Every cross-tenant read from this app is logged with actor, subject and reason (ADR-0011). The audit log is append-only and shipped to separate storage; not even `super_admin` can edit it.
