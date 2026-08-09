# ADR-0011 — Multi-tenancy, RBAC, and two separate back offices

**Status:** Accepted · **Date:** 2026-08-09 · **Depends on:** ADR-0004

## Context

Three distinct audiences need administrative surfaces:

- **BilletEnLigne staff** — approve operators, resolve stuck payments, refund, investigate fraud, run finance and payouts. Sees *across all tenants*.
- **Operator staff** — schedules, fleet, pricing, agents, cash sales, their own revenue. Must see *only their own tenant*, and must never see a competitor's load factor or pricing.
- **Station agents / conductors** — a narrow slice of the operator's surface, on a phone.

Building one console with a "super admin" flag is the classic mistake. A single accidental missing `WHERE tenant_id = ?` then leaks a competitor's commercial data — the exact thing that makes operators refuse to join a marketplace.

## Decision

### Two separate applications, not one with a flag

| App | Audience | Deployment |
|---|---|---|
| `apps/console` | Operator staff | `console.billetenligne.cg` |
| `apps/admin` | BilletEnLigne staff | `admin.billetenligne.cg`, **IP-restricted + mandatory 2FA** |

Separate builds, separate auth realms, separate API surfaces (`/console/v1/*` vs `/admin/v1/*`). Different code paths for "my tenant" and "any tenant" means a bug in one cannot become a leak in the other. They share `bel_design`, `bel_domain` and `bel_contracts` — so this costs surprisingly little.

### Tenancy enforcement — defence in depth

1. **Postgres Row-Level Security** on every tenant-scoped table. The connection sets `app.tenant_id` from the verified token; RLS policies do the rest. **This is the real boundary** — if application code forgets a filter, the database still refuses.
2. **Application-layer scoping** in repositories as the second layer.
3. **A `TenantScope` value object** threaded through the application layer — a repository method physically cannot be called without one. Compile-time pressure, not discipline.
4. The admin API uses a *different* database role that can bypass RLS, and **every** cross-tenant read is written to an immutable audit log with actor, reason and timestamp.

### Role matrix

Deliberately **asymmetric**: our side is small and trusted, so few roles. The operator side is a real organisation with a cash desk, a yard and a finance office, so it needs genuine separation of duties.

#### BilletEnLigne (admin app) — three roles, no more

We are a small team. Ten roles for eight people is theatre, and theatre that makes people share logins is worse than no separation at all.

| Role | Can |
|---|---|
| `super_admin` | Everything: role grants, payout approval, PSP configuration, operator offboarding. **Two or three people.** |
| `operations` | The daily job — review and approve operator applications, support (find bookings, resend tickets, reschedule), refunds **up to a cap**, payment reconciliation, catalogue edits. |
| `viewer` | Read-only dashboards. Auditors, investors, new hires, on-call shadowing. |

Segregation of duties is preserved by **threshold, not by role count**: releasing a payout run and refunding above the cap both require `super_admin`, and both are logged with a mandatory reason. That gives us four-eyes on money without inventing a compliance department we do not have.

#### Operator (console app) — a real org chart

Roles are bundles of capability strings, and most are additionally **scoped to one or more stations/agencies**, which is what actually matters day to day: the Pointe-Noire vendor must not be able to open the Brazzaville till.

| Role (fr / en) | Scope | Can |
|---|---|---|
| `org_owner` — **Directeur / Owner** | Whole org | Everything. The only role that can change the **settlement account**, accept the commercial terms, add another owner, or request offboarding. |
| `org_admin` — **Administrateur** | Whole org | All operations: routes, schedules, fleet, pricing, refund policy, staff. **Cannot** touch the settlement account or legal terms. The person who actually runs the system day to day. |
| `finance` — **Responsable financier** | Whole org | Revenue, payouts, statements, invoices, commission reconciliation, refund approval above the vendor cap, exports. Read-only on operations. |
| `fleet_manager` — **Responsable de flotte** | Whole org | Coaches, seat-map layouts, amenities, maintenance status, coach↔departure assignment. |
| `dispatcher` — **Régulateur** | Whole org or region | Assign coach/driver/conductor to departures, delay, cancel, trigger passenger notifications, watch live trips. |
| `station_manager` — **Chef d'agence** | Station(s) | Everything a vendor can do, plus: manage that station's staff, open/close the **cash drawer**, approve till variances, view station performance. |
| `vendor` — **Agent guichet / Vendeur** | Station(s) | Sell in person for cash, look up and modify online bookings, reschedule within policy, refund **up to a cap**, reprint, issue the ticket-claim QR, operate their own till. **The highest-volume role.** |
| `conductor` — **Contrôleur** | Assigned departures | Boarding scan only, on a phone. Sees the manifest for their departure and nothing else. |
| `viewer` — **Consultation** | Whole org | Read-only. For an accountant, a partner, or the owner's phone. |

Notes that matter in practice:

- **A person can hold several roles.** In a five-coach operator the owner *is* the finance office and often the dispatcher. Roles are additive; the UI hides what a user cannot do rather than showing it disabled, except for money screens where a disabled control with "réservé au responsable financier" teaches the org chart.
- **`vendor` is station-scoped and till-bound.** Every cash sale is attributed to a vendor and a till session. Cash-out at end of shift produces a till reconciliation the station manager signs off. This is the feature that turns "we lose money somewhere between the agent and the office" into a solved problem — and it is the reason operators will adopt the console.
- **`conductor` is departure-scoped and time-boxed** (ADR-0013): the credential dies at end of shift.
- Capability strings, never role names, in every check: `booking.refund`, `booking.refund.above_cap`, `till.close`, `payout.approve`, `operator.settlement_account.edit`, `departure.cancel`. A new role is then a configuration row, not a release.

### Sensitive-action rules

- Changing an operator's settlement account requires **owner** + a fresh 2FA challenge + a **24 h cooling-off** during which payouts are held and the previous account is notified. Settlement-account takeover is the single highest-value fraud against a platform like this.
- Refunds above a threshold need a second approver.
- Every admin action carries a mandatory free-text reason, stored in the audit log.

## Consequences

More surface to build and secure. Accepted — the alternative risks the trust that the whole marketplace depends on. RLS adds a small query cost and real operational discipline (every migration must consider its policy). The audit log is append-only and shipped to separate storage.
