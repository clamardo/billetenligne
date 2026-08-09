# ADR-0023 — The traveller is not a tenant

**Status:** Accepted · **Date:** 2026-08-09 · **Depends on:** ADR-0011, ADR-0012 · **Amends:** ADR-0011

## Context

ADR-0011 made Postgres Row-Level Security the real tenancy boundary: a connection sets `app.tenant_id` from the verified token, and every policy reads `operator_id = app_tenant_id()`. That is correct for the console and the admin back office, and it has held up.

It has a hole, and building the booking path found it immediately.

**A traveller belongs to no operator.** Aline signing in with her Firebase account has no tenant. Under ADR-0011's policies alone, `app_tenant_id()` is NULL, every tenant policy evaluates false, and the entire buying path sees an empty database. Search returns nothing, the seat map is blank, and no hold can be created.

This is the majority of our traffic. It cannot be a special case bolted onto the tenant model.

## The option we rejected

The obvious fix is to look up the departure's operator and set `app.tenant_id` to it for the duration of the public request. One line of middleware. Every policy then works untouched.

It is also wrong, and worth writing down *why*, because it will be proposed again.

It would run an anonymous request from the public internet with **the operator's own full tenant authority**. Every policy that says "this tenant may see its own rows" would say yes. One careless join in one public handler — a `SELECT * FROM operator_staff` while building a "contact the operator" panel, a debug query left in — and that operator's staff list, KYB documents, payout schedule or ledger leaves the building. The blast radius of a routine bug becomes a competitor's commercial data, which is the exact failure ADR-0011 exists to prevent.

The tenant scope is a statement about *whose data this is*. A traveller's request is not the operator's data; it merely touches some of it.

## Decision

**A third database role, with its own narrow policies, and least privilege at the connection rather than at the query.**

### Four roles, one login

| Role | Serves | May do |
|---|---|---|
| `bel_public` | The traveller | Read the catalogue; hold and release seats; see its own holds, bookings and tickets |
| `bel_app` | Operator staff | Its own tenant, per ADR-0011 |
| `bel_admin` | Our back office | Across tenants, every read audited |
| `bel_api` | **The connection itself** | Nothing at all |

`bel_api` is the role the API logs in as, and it is `NOINHERIT`. It holds membership of the other three and the privileges of none of them. Every transaction opens with `SET LOCAL ROLE`, declaring which surface it is serving.

Two properties fall out of that:

* **A connection that has not declared its surface can read nothing.** Forgetting to scope is not a silent widening; it is an immediate permission error.
* **`LOCAL` means the declaration dies at `COMMIT`.** A pooled connection cannot carry an elevated role back into the pool and into the next request. This is the failure mode that makes role-switching dangerous in most designs, and it is closed by construction rather than by remembering to `RESET`.

The alternative — three pools with three sets of credentials — costs three secrets to rotate and buys nothing, because a pool that can log in as `bel_admin` is exactly as dangerous as a role that can `SET ROLE` to it.

### The grant list *is* the public attack surface

`bel_public`'s grants are enumerated one table at a time, never `GRANT ... ON ALL TABLES`. It has no grant whatsoever on `operator_staff`, `platform_staff`, `kyb_documents`, `ledger_entries`, `payment_events`, `audit_log`, `refunds`, `payouts`, `vehicles`, `stations` or `redemptions`.

This matters more than the policies do. Policies decide which *rows*; grants decide which *tables exist at all* for this role. A grant list is the defence that survives a SQL injection in a public handler, because no crafted query can reach a table the role was never granted. A future table is invisible to the traveller until somebody adds a line and justifies it in review.

### The traveller cannot sell a seat

The single most important line in the migration:

```sql
CREATE POLICY seats_public_hold ON seats
  FOR UPDATE
  USING      (app_is_public() AND state IN ('available', 'held'))
  WITH CHECK (app_is_public() AND state IN ('available', 'held'));
```

`USING` covers the row as it stands, so a `sold` or `blocked` seat is invisible to this policy and cannot be touched. `WITH CHECK` covers the row as it would become, so a crafted request cannot write `sold` and skip payment.

**There is no path from an unauthenticated request to a sold seat.** Selling is a system action taken after money is captured, under the operator's own scope. That is a property of the schema, not of our handlers, and it is asserted in `verify_public.sql` rather than described here and hoped for.

### `app.user_id`, and failing closed

Holds, bookings, tickets and idempotency keys are scoped by `user_id = app_user_id()`, read from the same setting the INSERT fills from — so the two cannot drift apart.

An anonymous connection has a NULL user id. `user_id = NULL` is NULL, and NULL is not true, so browsing without signing in sees *no* holds rather than everyone's. The failure direction is the safe one, which is the only acceptable arrangement.

## Consequences

**Good.**

* The booking path works for people who do not work for a bus company, which is nearly everyone.
* The blast radius of a bug in a public handler is bounded by a grant list, not by that handler's own carefulness.
* Adding a public endpoint requires adding a grant, which requires a reviewer to ask what it is for.
* Nine executable assertions in `verify_public.sql` — including that these permissive policies did not accidentally widen the operator's own view, which is the subtle way this change could have gone wrong.

**Costs.**

* Four roles instead of three, and provisioning must create `bel_api` and its memberships. Handled in `infra/dev/seed/00-roles.sql` and, in real environments, in Terraform.
* Two places to think about when adding a tenant-scoped table: the tenant policy in 0004's array, and a decision about whether the traveller may see it at all. That second decision is one we *want* somebody to make consciously.
* Every request pays one extra round trip for `SET LOCAL ROLE` and `set_config`. Measured in microseconds against a hot path that takes row locks; not worth optimising until it shows up in a profile.

## Alternatives considered

**Set `app.tenant_id` to the departure's operator for public requests.** Rejected above — it hands an internet request an operator's own authority.

**A security-definer function per public operation.** Each public read becomes a function that bypasses RLS and applies its own filter. Works, but it moves the boundary from declarative policy into procedural code, where it is much harder to audit and impossible to check with the coverage test we already have.

**No RLS on the public path; filter in application code.** This is exactly the arrangement ADR-0011 rejected, and its failure mode — one missing `WHERE` — is the reason RLS is here in the first place.

**A separate read-only replica for public traffic.** Solves reads and nothing about holds, which are writes. Worth revisiting for search volume later; it is not an answer to this question.
