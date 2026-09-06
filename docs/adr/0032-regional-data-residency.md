# ADR-0032 — Regional data residency, as a partition on the operator

**Status:** Proposed · **Date:** 2026-09-06 · **Reads with:** ADR-0011, ADR-0031, `08-disruption.md` §2.2–§5

## Context

Every operator's data lives in one Postgres instance, in one region, isolated from every other
operator by Row-Level Security (ADR-0011). That is real tenant isolation — the database itself
refuses a query missing its scope — but it is not data *residency*. There is exactly one place any
operator's data can live, and it is wherever we run Cloud SQL today.

No customer has asked for this. It is not in Phase 5 or Phase 6, and neither roadmap document
names it. This ADR exists because the shape of the answer — if a regulator, an enterprise operator,
or a second country's data-protection law ever makes it a requirement — is a genuine architectural
choice, not a configuration flag, and the choice interacts with features already built. Better to
write it down once, unhurried, than to improvise it under a contract deadline.

**The premise to reject first: this is not "add a `region` column."** ADR-0031 already drew that
exact distinction for markets — a market is context, not a partition, because departures cross
borders and a partitioned row is either invisible at one end or double-sold. Region-as-residency is
the opposite kind of fact: it is not about which cities a traveller sees, it is about **which
physical database an operator's rows are written to**, and it is an operator-level fact, like a
market, not a per-row one.

**The conflict this creates:** BilletEnLigne already runs cross-operator transactions inside a
single `COMMIT` — the protection agreement and protection movement (`08-disruption.md` §2.2 option
③, §5) move bookings between two operators' books, re-sign tickets under the receiving operator's
code, and settle the rebill, all in one transaction, against one connection. If operator A's rows
live in a Frankfurt database and operator B's live in a Johannesburg one, that transaction cannot
exist as written. **Regional residency is therefore a constraint on who may sign a protection
agreement with whom, not a free per-operator choice.**

## Decision (recommended, not yet accepted)

**A region is a physical deployment of the data plane — its own Postgres instance, its own object
store, its own signing keys — and an operator is assigned to exactly one at onboarding.** Nothing
about a booking, a seat, a ticket or a ledger entry changes; RLS, `TenantScope` and every schema
guarantee in ADR-0011 apply unchanged *inside* a region. What changes is that "the database" stops
being a singleton the API process always has one connection pool to, and becomes a value resolved
per operator.

1. **The control plane is small, global, and holds no fare data.** Operator identity (which region
   an operator is assigned to), platform staff, the admin app's cross-operator directory (names,
   status, compliance dates — the fields `10-build-status.md` already shows platform staff reading
   today) and billing/payout-run metadata live here. This mirrors Cogitova's ADR-0027/ADR-0016
   split, for the same reason: a control-plane outage must never stop a coach boarding, and a school
   / an operator both keep working on entirely local information while the platform side is down.

2. **Each region is a complete data plane** — Postgres with the existing 45-migration schema, RLS
   policies and all; the object store for KYB documents, logos and manifests; the signing key for
   that region's tickets (ADR-0007's Ed25519 keys are already per-deployment, so this changes
   nothing about the ticket format, only how many deployments exist). A region is not a shard of one
   schema — it is a full, independently-restorable instance of the schema BilletEnLigne already
   runs.

3. **The planes talk through one gateway, never through each other's connection string** — copying
   ADR-0005/ADR-0016's rule verbatim, for the reason they state it: the boundary a handler might
   forget is not a boundary. The control plane pushes operator status and region assignment; a
   region's API never opens a connection to another region's Postgres, and never to the control
   plane's.

4. **A protection agreement may only be signed between two operators in the same region.** This is
   the one place the constraint becomes visible to a user rather than staying infrastructure: the
   agreement-creation screen offers only same-region operators, refused at the API and not only
   hidden in the console (ADR-0031 §4's rule, same reasoning). It is a real loss of generality —
   Congo and Gabon are a real corridor and could end up in different regions for unrelated reasons —
   and the honest mitigation is the same one ADR-0031 gives for cross-border routes: keep the CEMAC
   markets that actually share corridors in one region for as long as they are commercially one
   region, and let the constraint bind only once residency and corridor overlap actually conflict.

5. **Region is chosen once, at onboarding, and moving an operator afterward is a migration, not a
   setting.** An operator's rows, tickets, KYB documents and ledger history physically move —
   dump, restore, re-verify the ledger balances, re-sign nothing (tickets are already signed and
   moving them changes no seat or fare). This is deliberately rare and deliberately expensive: a
   product that made region a checkbox would be promising a live-migration guarantee this ADR does
   not ask for.

6. **The public sales boundary (ADR-0023) and traveller search resolve region the same way they
   resolve market today** — from the operator being searched, not from the traveller. A traveller
   in Brazzaville searching a Brazzaville→Libreville coach reaches whichever region that operator
   lives in; the app holds no concept of region at all, exactly as it holds none of market beyond
   the resolved chip.

## Consequences

**Good.** An operator (or a regulator) that requires data to stay in a named jurisdiction gets an
answer with a real database behind it — a Postgres instance and an object store that never leave
that region — not a compliance document describing a shared one. The existing RLS and `TenantScope`
guarantees are untouched; residency is layered on top of tenant isolation, not a replacement for it.

**Bad.** A second full deployment per region, each with its own Postgres, object store, signing key
and worker — real infrastructure cost and a second (third, fourth) set of migrations to run,
monitor and back up. Cross-region operator search — an admin looking up an operator by name across
every region — needs the control plane's directory rather than a query, which is more infrastructure
for a screen platform staff use daily.

**Risk — the protection-agreement constraint is the whole cost of this ADR, and it is a business
constraint wearing an engineering one's clothes.** Refusing an agreement between two operators who
would otherwise sign one, because residency happened to put them in different regions, is a real
commercial loss on a real corridor. This is worth restating exactly because it is the kind of cost
that is invisible until the day a rescue coach is needed and the two operators best placed to run it
turn out to be unable to.

**Risk — this reads as done once written down, and it is not.** Nothing here has a line of code
behind it. The gate is the same one every other unstarted phase in `09-roadmap.md` names: a customer
or a regulation that actually requires it. Building the multi-region control/data-plane split before
that gate opens buys optionality nobody has asked for yet, at the cost of every regional deployment
this platform runs from that day forward.

## What this does not decide

- Which regions exist, or which cloud/provider each runs on. `terraform/gcp-module` and
  `terraform/azure-module` already show this codebase is comfortable splitting providers by
  concern (ADR unstated, see `terraform/azure-module/main.tf`'s own comment); nothing here picks a
  second region's provider.
- Whether the admin app's cross-operator directory needs its own database or can stay a set of
  columns replicated from each region's control-plane push — either is consistent with this
  decision.
- How payout runs settle across regions, if BilletEnLigne itself ever needs to move money between
  an operator in one region and its own account in another. Today every payout is one operator's
  ledger to one bank account; this ADR does not address a cross-region money movement because none
  exists to address.
- Whether Phase 5's second market (ADR-0031 §8) and a second *region* are ever the same event.
  They are orthogonal by construction — a market is data an operator carries, a region is where
  that data physically sits — and nothing requires opening them together.
