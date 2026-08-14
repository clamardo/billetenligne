# BilletEnLigne — The platform split

**Status:** Specification · **Date:** 2026-08-14 · **Implements:** [ADR-0027](adr/0027-verticals-are-separate.md) §1, §2, §3 · **Blocks:** [`12-rental.md`](12-rental.md), [`13-stays.md`](13-stays.md)

## 0. What this is, and why it blocks two verticals

ADR-0027 decided that each vertical gets its own domain package, its own Postgres schema and its own API route tree, over a shared platform. Today there is no shared platform — there is `bel_domain`, which holds both the platform primitives and the transport domain and calls the result "the domain".

This document is the refactor that separates them. It is five slices, **no behaviour change**, and it must land green before a line of `bel_rental` or `bel_stay` is written. Building a vertical first and splitting afterwards means splitting three domains instead of one, with two of them already depending on the wrong things.

**Nothing here is speculative.** Every number below came from running a classifier over the tree on 2026-08-14, and the scripts that produced them are in §11 so they can be re-run before starting.

---

## 1. What the scan found

### 1.1 The split is clean

`packages/bel_domain/lib/src` holds **38 files, 6 862 lines**. Classified by whether a type is about *money, identity, operators and markets* (platform) or about *seats, departures, tickets and disruption* (transport):

- **19 files, 2 802 lines → platform**
- **19 files, 4 060 lines → transport**
- **53 platform symbols, 117 transport symbols, and the name overlap is empty.**

That last fact is the important one. Zero overlapping public names means the move cannot produce an ambiguous import anywhere, and the transitional re-export in §5 is safe.

### 1.2 The dependency graph inside `bel_domain` has exactly one forced decision

Every internal import already points from transport toward platform, with **one exception**:

```
identity/totp.dart  ──imports──▶  ticketing/crypto_ports.dart
```

`totp` is identity, which is platform. `crypto_ports` lives under `ticketing/`, which is transport. Left alone, the platform package would import the transport package — precisely the illegal direction.

So `crypto_ports.dart` moves to `bel_platform/src/crypto/crypto_ports.dart`. It is four `abstract interface class` declarations — `SignatureVerifier`, `SignaturePreparer`, `MessageAuthenticator`, `TicketSigner` — and it was never about ticketing; it was filed there because ticketing was its first caller.

**That is the entire ambiguity in the graph.** Everything else falls out.

### 1.3 Most consumers of "the domain" do not use the domain

263 files import `package:bel_domain`. Classified by which symbols they actually reference:

- **149 files use platform symbols only.** After the split they import `bel_platform` and stop depending on transport entirely.
- **76 files use both.** They import both packages.
- **38 files use transport symbols only.**
- **0 dead imports.**

Fifty-seven per cent of the files that import "the domain" never touch a seat, a departure or a ticket. That is independent evidence that this boundary is real and not architectural decoration — and it is also the measure of what the split buys: 149 files stop being able to reach transport types at all.

> **A note on the method.** The first run of this classifier reported 7 dead imports. It was wrong: the declaration regex did not match `abstract interface class`, so `crypto_ports`' four types were invisible and every file that only implemented them looked empty. The corrected regex in §11 matches all six declaration forms present in the tree (`class`, `final class`, `sealed class`, `abstract class`, `abstract final class`, `abstract interface class`). Re-run it, do not trust the numbers above blindly, and check the form list first.

---

## 2. Target topology

```
packages/
  bel_platform     NEW.  Money, currency, commission, ledger, payouts; market
                         config and payment rails; email, phone, TOTP; the
                         payment intent; operator applications, document
                         expiry, onboarding risk; brand assets; the crypto
                         ports; Result, DomainFailure, Clock.
                         Zero dependencies. Knows nothing about seats.

  bel_domain       transport, and keeps its name. Departures, routes, cabin
                   sections, TransportMode, holds, booking refs, refund and
                   change policy, tickets, boarding, disruption, segments,
                   trip shares. Depends on bel_platform.

  bel_rental       LATER — 12-rental.md R2 onward.
  bel_stay         LATER — 13-stays.md S3 onward.
  bel_reviews      LATER — 14-reviews.md V1.
```

`bel_domain` keeps its name deliberately. Renaming it to `bel_transport` would touch all 263 consumer files to express something the dependency graph already states, and the churn would land in the same commits as a real refactor, where it would hide it.

Schemas: `public` stays the platform's and transport's; `rental`, `stay` and `review` are created by their own verticals. Transport does **not** move out of `public` — relocating sixteen migrations' worth of live tables to make a statement is a large risk for a small one.

---

## 3. The inventory — where each of the 38 files goes

### → `bel_platform` (19 files, 2 802 lines)

```
shared/result.dart            Result, Ok, Err
shared/failure.dart           DomainFailure
shared/clock.dart             Clock
money/currency.dart           Currency and its exponent
money/money.dart              Money
money/commission.dart         basis points, netted at source
money/ledger.dart             chart of accounts, posting types
money/payout.dart             payout run domain
identity/email_address.dart   EmailAddress
identity/phone_number.dart    PhoneNumber, carrier resolution
identity/totp.dart            RFC 6238
market/market.dart            Market, serviceFee, languages
market/payment_rail.dart      PaymentRail, pushesToHandset
payment/payment_intent.dart   PaymentIntent state machine
branding/brand_asset.dart     vitrine assets
operator/operator_application.dart
operator/document_expiry.dart
operator/onboarding_risk.dart
ticketing/crypto_ports.dart   → becomes crypto/crypto_ports.dart  (§1.2)
```

### → stays in `bel_domain` (19 files, 4 060 lines)

```
booking/booking_ref.dart      BookingRef, PaymentCode        (see §3.1)
booking/cancellation.dart     BookingStanding, CoachHasLeft
booking/hold.dart             Hold, HoldPolicy, SeatUnavailable  (see §3.1)
catalog/transport_mode.dart   TransportMode
catalog/seat_layout.dart      CabinSection, SeatLayout, Abreast
catalog/segment.dart          ADR-0025
catalog/itinerary.dart
catalog/recurrence.dart
disruption/disruption.dart
disruption/protection.dart
disruption/reaccommodation.dart
disruption/seat_remap.dart
disruption/self_service.dart
policy/refund_policy.dart     RefundPolicy, RefundTier        (see §3.1)
policy/change_policy.dart     ChangePolicy, MissedPolicy
ticketing/rotating_code.dart
ticketing/ticket_payload.dart
ticketing/verification.dart
trip/trip_share.dart
```

### 3.1 Three files that look platform, and stay put on purpose

ADR-0027's rule for `bel_platform` membership: **a type belongs there only if at least two verticals need it and neither owns it.** Applied honestly, three tempting candidates fail it today. Each is listed with the trigger that moves it, so the decision is deferred rather than forgotten.

**`booking/booking_ref.dart` — `BookingRef`, `PaymentCode`.** A formatted human reference and an agency-till code. Rental and stays will both want a customer-facing reference. **Trigger:** the first time a second vertical needs one — `12-rental.md` R2 (`rental.rentals.ref`) or `13-stays.md` S3. Move it then, keeping the class names.

**`booking/hold.dart` — `HoldPolicy`, `HoldState`.** `HoldPolicy` carries the `ttl > paymentWindow > warnAt` invariant, which is a payment fact rather than a seat fact. But `Hold` itself has `departureId` and `seatLabels`, so the file would have to be split, and today exactly one vertical uses any of it. **Trigger:** rental's hold slice, R6. Split then: `HoldPolicy`/`HoldState`/`HoldExpired`/`HoldAlreadyConsumed` to platform, `Hold`/`SeatUnavailable` stay.

**`policy/refund_policy.dart` — `RefundDestination`.** `source | agencyCash | creditNote | travellerChoice` is a property of how money goes back, not of coaches. The rest of the file — `RefundTier`, `RefundQuote`, `AlreadyDeparted` — is anchored on a departure and is transport's. **Trigger:** `13-stays.md` S11, the cancellation slice, which is the first non-transport code that needs to say where a refund goes.

Deferring all three keeps P2 to a mechanical move of files that need no surgery. **A refactor that also makes three judgement calls is a refactor whose regressions are hard to attribute.**

---

## 4. P1 — `bel_platform` exists and is empty

Create the package, wire it in, export nothing.

`packages/bel_platform/pubspec.yaml`:

```yaml
name: bel_platform
description: >-
  Everything a vertical needs and none of them owns: money and the ledger,
  markets and payment rails, identity, operators, and the crypto ports.
  Pure Dart, zero dependencies (ADR-0027 §1).
version: 0.1.0
publish_to: none
resolution: workspace
environment:
  sdk: ^3.8.0
dev_dependencies:
  test: ^1.25.0
```

`packages/bel_platform/lib/bel_platform.dart` — a `library;` and nothing else, for now.

Root `pubspec.yaml`: add `- packages/bel_platform` to `workspace`, **first**, above `bel_domain`, because the list reads as a dependency order even though pub does not require it to.

`melos.yaml`: `packages: packages/**` already matches it. Add it to the `test:domain` script's package list, beside `bel_domain`, so its tests run in the fast suite from the day it has one.

Add `bel_platform: ^0.1.0` to the dependencies of every pubspec that declares `bel_domain` today. There are ten:

`apps/traveller` · `apps/scanner` · `apps/console` · `apps/admin` · `packages/bel_crypto` · `packages/bel_client` · `packages/bel_contracts` · `packages/bel_domain` · `services/api` · `services/worker`

Every one of them uses at least one platform symbol, so none of these is a speculative dependency.

**Done when:** `melos bootstrap` succeeds, `dart analyze --fatal-infos` is clean, and CI is green with a package that contains nothing. Commit it on its own — an empty package landing green proves the workspace plumbing before any code moves through it.

---

## 5. P2a — move the files, with a transitional re-export

`git mv` the 19 files in §3, fixing their relative imports, and move `ticketing/crypto_ports.dart` to `crypto/crypto_ports.dart`.

`packages/bel_platform/lib/bel_platform.dart` exports all 19.

`packages/bel_domain/lib/bel_domain.dart` keeps its 19 transport exports, drops the 19 that left, and gains **one transitional line**:

```dart
// TRANSITIONAL — removed by P2b. Every consumer that imports bel_domain for
// a platform type keeps compiling while the move lands, so this slice can be
// reviewed as a pure file move rather than as 225 import edits.
//
// It is legal (bel_domain → bel_platform is the allowed direction) and it is
// still wrong to keep: a re-export hides where a type lives, and a reader
// cannot tell whether `Money` is transport's or the platform's. P2b removes
// it, and a CI check keeps it removed.
export 'package:bel_platform/bel_platform.dart';
```

`packages/bel_domain/pubspec.yaml` gains `bel_platform` as a real dependency and its description changes from *"domain core"* to what it now is: the transport domain.

Move the corresponding tests too — `packages/bel_domain/test` has 24 files and they follow their subjects.

**Done when:** the full suite passes with **zero behaviour changes**, `dart run tool/check_layers.dart` is clean, and `git diff --stat` shows renames, import-path edits and pubspec lines — and nothing else. If a diff hunk changes a condition, an operator or a constant, it does not belong in this commit.

### Why the re-export, given it is admitted to be wrong

Without it this slice is one commit touching 225 files: 19 moves plus 206 import edits, reviewed as one blob. With it, the move is reviewable on its own and the import churn is a separate, mechanical, revertible commit. The cost is one line that lives for one commit and is fenced by a CI check from the moment it is removed.

---

## 6. P2b — remove the re-export

Delete the transitional line. `dart analyze` then reports undefined names in the 225 files that were relying on it. Fix them with a script rather than by hand — the classification is exactly the one §11 computes.

The rule per file:

- references a platform symbol → ensure `import 'package:bel_platform/bel_platform.dart';`
- references **no** transport symbol → remove `import 'package:bel_domain/bel_domain.dart';`
- imports are re-sorted; `dart format` afterwards

Expected outcome, from the scan: **149 files end up importing only `bel_platform`, 76 import both, 38 are untouched.**

Then remove `bel_domain` from the pubspecs of any package whose files no longer reference a transport symbol at all. `bel_crypto` is the likely candidate — it implements `SignatureVerifier` and `MessageAuthenticator`, both of which are now platform's — and dropping that edge is the first visible payoff of the whole exercise.

Add the guard to `tool/check_layers.dart` so the re-export cannot come back:

```dart
LayerRule(
  name: 'the domain barrel re-exports no other package',
  appliesTo: 'packages/bel_domain/lib/bel_domain.dart',
  forbidden: ['package:bel_platform/'],
  because:
      'A re-export hides where a type lives. A reader must be able to tell '
      'from the import whether Money is transport\'s or the platform\'s, '
      'because in three months two more packages will be asking.',
),
```

That rule matches `export` lines only if the checker's regex covers them; it currently matches `import`. **Extend `_import` to match both `import` and `export`** — a one-word change to the pattern, and it makes every existing rule stronger at the same time, because today a package could evade any of them by re-exporting instead of importing.

**Done when:** the suite is green, `check_layers` is green, and re-adding the export line fails CI with a readable message.

---

## 7. P3 — the rules that make the boundary real

Three `LayerRule` entries in `tool/check_layers.dart`, beside the five that exist.

```dart
LayerRule(
  name: 'the platform knows no vertical',
  appliesTo: 'packages/bel_platform/lib/',
  forbidden: [
    'package:bel_domain/', 'package:bel_rental/', 'package:bel_stay/',
    'package:bel_reviews/', 'package:bel_contracts/', 'package:bel_design/',
    'package:flutter/', 'dart:io', 'dart:ui',
  ],
  because:
      'bel_platform is what every vertical stands on. The moment it imports '
      'one of them, adding the next vertical means changing the floor '
      '(ADR-0027 §1).',
),
LayerRule(
  name: 'verticals do not import one another',
  appliesTo: 'packages/bel_domain/lib/',
  forbidden: ['package:bel_rental/', 'package:bel_stay/'],
  because:
      'A single import is ADR-0027 undone. The models share nothing above '
      'the booking, and the day one of them borrows the other\'s type is the '
      'day the polymorphic booking row starts growing back.',
),
// The same rule again for bel_rental and for bel_stay, each forbidding the
// other two. Three entries, not one, because `appliesTo` is a path fragment
// — and three explicit rules read better in a failure message than one
// clever one.
```

Write a test for the checker itself: a fixture file under a scratch path that violates each new rule, asserting the checker exits non-zero and names the rule. **A rule that has never been seen to fail is a rule nobody has tested.**

**Done when:** `dart run tool/check_layers.dart` passes on the tree, and each of the three new rules has a test that proves it fires.

---

## 8. P4 — per-schema migration sequences, roles, and the direction check

### 8.1 The runner

`services/worker/lib/src/migrations.dart` today takes a `Directory` and records bare filenames in `schema_migrations (filename PRIMARY KEY)`. Two changes, both small and both backward-compatible.

**A sequence name.** `applyMigrations` gains `String? sequence`. When set, the recorded key becomes `'$sequence/$name'` — `rental/0001_schema.sql`. When absent, the key is the bare filename, so **every existing row in every existing database is untouched**. That property is the whole design of this change.

**The baseline check is the root sequence's alone.** The current logic refuses when `schema_migrations` is absent but `operators` exists — a platform-specific probe. It must run for the root sequence only; a sub-sequence with no rows on a live database is the normal case for a vertical that has not shipped, not an unknown baseline.

`services/worker/bin/migrate.dart` then applies the root sequence, and afterwards each sub-directory of `infra/migrations/` that contains numbered `.sql` files, in name order. `rental` before `review` before `stay` is alphabetical and arbitrary, which is correct: **no vertical's schema may depend on another's**, and if the order ever matters, that dependency is the bug.

The existing `migrationFiles()` already ignores anything that is not a numbered `.sql`, so `check.sh`, `verify.sql` and the READMEs sitting in `infra/migrations/` are skipped exactly as they are today.

### 8.2 Roles

Each vertical's `0001` creates its schema and its role. Rental's, in full:

```sql
CREATE SCHEMA IF NOT EXISTS rental;

-- Same family as bel_public / bel_app / bel_admin / bel_identity, same rule
-- (ADR-0011): bel_api is NOLOGIN NOINHERIT and gets privileges only through
-- SET LOCAL ROLE. Nothing about that changes here.
DO $$ BEGIN
  CREATE ROLE bel_rental_app NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

GRANT USAGE ON SCHEMA rental TO bel_rental_app;
GRANT bel_rental_app TO bel_api;

-- The platform tables this vertical genuinely reads. Enumerated, never
-- blanket: a vertical that can SELECT all of `public` is a vertical that
-- will eventually join to `bookings`.
GRANT SELECT ON public.operators, public.cities, public.user_accounts
  TO bel_rental_app;
GRANT SELECT, INSERT, UPDATE ON public.payables TO bel_rental_app;
```

### 8.3 The direction check

ADR-0027 §2: a vertical schema may reference `public`; `public` may never reference a vertical schema. That is what makes extraction to a service mechanical later, and it is one query, added to `infra/migrations/check.sh` beside the guarantees it already executes:

```sql
SELECT count(*) = 0 AS ok
  FROM pg_constraint c
  JOIN pg_class      t ON t.oid = c.conrelid
  JOIN pg_namespace  tn ON tn.oid = t.relnamespace
  JOIN pg_class      f ON f.oid = c.confrelid
  JOIN pg_namespace  fn ON fn.oid = f.relnamespace
 WHERE c.contype = 'f'
   AND tn.nspname = 'public'
   AND fn.nspname IN ('rental','stay','review');
```

Named in the check output as *"the platform holds no key into a vertical"*, and the failure message should print the offending constraint, because the fix is always "move the reference to the other side" and the author needs to know which one.

**Done when:** `rental/0001` applies to a real database and applies again as a no-op; a scratch migration adding `public.foo.rental_id → rental.vehicles(id)` fails `check.sh` and names the constraint; and — the one that matters — **an existing database with 45 applied migrations gains no new `schema_migrations` rows and re-applies nothing**.

---

## 9. P5 — `public.payables`, the one shared money seam

```sql
CREATE TABLE payables (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id    UUID NOT NULL REFERENCES operators(id) ON DELETE RESTRICT,
  subject_kind   TEXT NOT NULL,
  -- Opaque. The platform NEVER joins on this and never parses it. It is the
  -- vertical's own reference, echoed back on settlement so the vertical can
  -- find its own aggregate. This one property is what lets a vertical become
  -- a service later without the ledger moving (ADR-0027 §3).
  subject_ref    TEXT NOT NULL,
  purchaser_user_id UUID REFERENCES user_accounts(id),
  amount_minor   BIGINT NOT NULL,
  fee_minor      BIGINT NOT NULL DEFAULT 0,
  currency       CHAR(3) NOT NULL,
  -- Snapshotted per vertical. Rental excludes the security deposit from the
  -- base; stays charge the property nothing on payAtProperty (ADR-0027 §6).
  commission_bps INTEGER NOT NULL,
  state          TEXT NOT NULL DEFAULT 'pending',
  idempotency_key TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  settled_at     TIMESTAMPTZ,

  CONSTRAINT payables_subject_kind_known
    CHECK (subject_kind IN ('transport_booking','rental','stay')),
  CONSTRAINT payables_amounts_sane CHECK (amount_minor >= 0 AND fee_minor >= 0),
  UNIQUE (subject_kind, subject_ref)
);
```

What matters architecturally:

`subject_ref` is **opaque text**. The platform stores it, echoes it back on settlement, and never parses or joins on it. That single property is what lets a vertical collect money over four payment rails, net commission and post a balanced pair of ledger entries without the ledger ever learning what a Land Cruiser is — and it is the extraction seam: the day stays becomes a service, it calls an API to create a payable and consumes a settlement event, and the ledger does not move.

The vertical side is a listener, not a join: on settlement the platform emits an event carrying `(subject_kind, subject_ref)`, and the vertical moves its own aggregate to `confirmed`. In one deployment that is a function call inside the same transaction; across a service boundary later it is a message. **Write it as the former with the shape of the latter** — a handler taking `(kind, ref)` and nothing else — so the change is the transport and not the logic.

**Transport does not migrate onto `payables` in P5.** `bookings` keeps its existing, working, tested payment path. Adding a second way to pay for a coach seat before there is a reason is risk for nothing. Transport adopts `payables` only if and when it becomes a service.

**Done when:** a payable settles through the fake rail, the ledger balances, and `infra/migrations/verify_unbalanced.sql` still fails an unbalanced pair.

---

## 10. The traps this repository will lay

Four, from things already known to have bitten here.

**`services/api/build/.dart_frog_path_dependencies/`.** Dart Frog copies every path dependency into `build/` at bundle time. That directory currently holds a stale copy of `bel_domain` — it shows up in every repo-wide grep. After the split it will hold a stale copy of *two* packages, and a smoke run against it will compile the old shape and produce a confusing error. **`rm -rf services/api/build` before any smoke run**, and treat any grep hit under `build/` as noise, not as a call site.

**`dart format` reflows code, so anchored edits stop matching.** Run the mechanical import rewrite in P2b *before* formatting, then format once at the end. Editing after a format, against strings captured before it, is how the same edit gets applied twice.

**Melos and the pub workspace are two lists.** A new package must appear in the root `pubspec.yaml`'s `workspace:` **and** be matched by `melos.yaml`'s `packages:` globs. The glob already matches; the workspace list does not, and forgetting it produces a resolution error that names the wrong thing.

**`dart test` output uses carriage returns.** Pipe through `tr '\r' '\n'` when capturing it, or the failure list is a single overwritten line.

---

## 11. Re-run the numbers before starting

The classification in §1 and §3 is a fact about the tree on 2026-08-14. Re-run it first; if the counts have moved, the inventory in §3 has moved with them.

```python
# python3 - <<'EOF'   (from the repository root)
import re, glob, collections
PLATFORM = """shared/result shared/failure shared/clock money/currency money/commission
money/ledger money/payout money/money identity/email_address identity/phone_number
identity/totp market/market market/payment_rail payment/payment_intent
branding/brand_asset operator/operator_application operator/document_expiry
operator/onboarding_risk ticketing/crypto_ports""".split()
ALL = [f.split('lib/src/')[1][:-5]
       for f in glob.glob('packages/bel_domain/lib/src/**/*.dart', recursive=True)]
TRANSPORT = [r for r in ALL if r not in PLATFORM]

# Matches all six declaration forms present in this tree. Check the form list
# first -- the first version of this script missed `abstract interface class`
# and reported seven files as dead imports that were not.
#   grep -rhoE '^(abstract |final |sealed |base |interface |mixin )*(class|enum)\s' \
#     packages/bel_domain/lib/src --include=*.dart | sort | uniq -c
decl = re.compile(
    r'^(?:abstract |final |sealed |base |interface |mixin )*'
    r'(?:class|enum|extension type|mixin)\s+([A-Z]\w*)', re.M)

def syms(rel):
    return set(decl.findall(
        open(f'packages/bel_domain/lib/src/{rel}.dart', encoding='utf-8').read()))

plat = set().union(*(syms(r) for r in PLATFORM))
tran = set().union(*(syms(r) for r in TRANSPORT))
assert not (plat & tran), f'overlapping names: {sorted(plat & tran)}'
print(f'files    platform {len(PLATFORM):3}  transport {len(TRANSPORT):3}')
print(f'symbols  platform {len(plat):3}  transport {len(tran):3}  overlap 0')

files = [f for f in glob.glob('**/*.dart', recursive=True)
         if '/build/' not in f and '.dart_tool' not in f
         and 'package:bel_domain' in open(f, encoding='utf-8', errors='ignore').read()]
cnt = collections.Counter()
for f in files:
    s = open(f, encoding='utf-8', errors='ignore').read()
    up = any(re.search(r'\b'+x+r'\b', s) for x in plat)
    ut = any(re.search(r'\b'+x+r'\b', s) for x in tran)
    cnt['both' if up and ut else 'platform only' if up
        else 'transport only' if ut else 'dead import'] += 1
print(f'consumers {len(files)}')
for k, v in cnt.most_common(): print(f'  {k:16} {v:4}')
# EOF
```

Expected on 2026-08-14: files 19/19 · symbols 53/117, overlap 0 · consumers 263 = 149 platform-only + 76 both + 38 transport-only + 0 dead.

The same script, with the per-file rule from §6, is the P2b rewriter. It is worth writing once and running twice: **once in `--dry-run`, printing the edit it would make to each file, before it makes any.**

---

## 12. What P does not do

Named so that scope does not creep into a refactor whose entire value is that it changes no behaviour.

- **No new features, no new endpoints, no schema change to an existing table.**
- **No `bel_rental`, `bel_stay` or `bel_reviews` package.** Those are `12-rental.md` R2, `13-stays.md` S3 and `14-reviews.md` V1.
- **No change to `bookings`**, which stays transport's aggregate.
- **Transport is not migrated onto `payables`.**
- **Transport's tables do not leave the `public` schema.**
- **`bel_domain` is not renamed.**
- **The three deferred files in §3.1 are not moved**, and each has a named trigger.
- **No `bel_contracts` split.** It gains a `bel_platform` dependency and nothing else; `bel_rental_contracts` and `bel_stay_contracts` are new packages created by their own verticals, not carved out of the existing one.

---

## 13. Slice summary

- **P1** — `bel_platform` exists and is empty. Ten pubspecs, the workspace list, the melos test script. *Green with an empty package.*
- **P2a** — 19 files move; `bel_domain` re-exports transitionally. *Full suite green, diff is renames and imports only.*
- **P2b** — the re-export is removed; ~206 import edits by script; the barrel-re-export rule and the `export`-matching checker. *149 files end up on `bel_platform` alone.*
- **P3** — three layering rules, each with a test that proves it fires.
- **P4** — per-schema migration sequences, the vertical roles, and the `public`-holds-no-key-into-a-vertical check. *An existing 45-migration database gains no rows.*
- **P5** — `public.payables`, settled through the fake rail, ledger balanced.

Five commits, each green, each independently revertible. Then `13-stays.md` S1.
