# The demo world

```bash
./tool/demo.sh            # seed it
./tool/demo.sh --purge    # remove every trace of it
```

Re-running seeds replaces rather than stacks, so it is always safe to run
again.

## Why it exists

Several things this product does only happen to a company that has existed for
a while: paperwork three weeks from lapsing, an application small enough for
the onboarding pass to approve on its own, a second operator on the same road
willing to take stranded passengers. Without them those paths are written and
never once watched working — the first time anybody sees the compliance banner
would be the day a real operator's insurance is about to lapse.

The world is built **through the real adapters**, not by inserting rows: the
wizard starts the applications, the platform console approves them, the
operator console draws the layouts and the roads and materialises the
departures. A seed that INSERTed its way to a finished world would prove that
INSERT works. This one fails if the product does.

The company names are **invented rather than borrowed**. Real Congolese
operators exist, and a demo world wearing one of their names is a screenshot
that says something untrue about a company that never agreed to be in it.

## The mark is the delete path

Every operator carries a `DEMO-` code and every person a
`@demo.billetenligne.cg` address. `--purge` removes exactly those and nothing
else, so going to production is a command rather than an afternoon at a psql
prompt. The demo phone numbers are in `+242 0690…` and are deliberately *not*
part of the mark: `0690` is a real allocation, so a purge keyed to a phone
prefix would eventually delete somebody who exists.

The removal order is read out of the foreign keys at runtime rather than
written down here, because a hand-written list would be correct today and
quietly wrong the first time a migration adds a table. The integration suite
(`services/worker/test/demo_world_pg_test.dart`) seeds, exercises and purges,
and then counts what is left.

Two things the walk cannot do on its own, and both are deliberate:

- The **outbox** holds no foreign key to anything, because a message must
  outlive the row it describes long enough to be sent (ADR-0019). It is named
  explicitly in the purge, and it is the one place a new table could hide —
  which is why the suite counts leftovers rather than trusting the walk.
- **`audit_log` refuses DELETE by grant and by trigger** (0004), for the
  table's owner too. The purge suspends that guarantee for one transaction
  rather than breaking it: `DISABLE TRIGGER` takes an ACCESS EXCLUSIVE lock so
  no other session can write an audit row meanwhile, and Postgres DDL is
  transactional, so a purge that fails halfway rolls the trigger back on with
  everything else. That unmaking a world takes a deliberate act is the point.

Which is also why `SEED_DATABASE_URL` is a **superuser** connection and
`DATABASE_URL` is not: creating people and appointing platform staff are
writes no running surface holds a grant for (0012). A seeder that could do
them through `bel_api` would make every other control decorative.

The city catalogue is deliberately **not** removed: two operators serving
Pointe-Noire must mean the same Pointe-Noire, and it belongs to nobody.

## Companies

| Code | Name | State | There to show |
|---|---|---|---|
| `DEMO-ALZ` | Alizés Transport | active, papers in order | ordinary selling on BZV↔PNR and BZV↔DOL |
| `DEMO-KLV` | Kouilou Voyages | active, insurance in 20 days | the console's compliance banner; the counterparty for protection, and the console that answers an open call |
| `DEMO-LKN` | Cars Lékana | active, insurance lapsed | the red row on Conformité, and the pass that stops the sale |
| `DEMO-SERGE` | Niari Express | submitted, small and complete | the onboarding pass approving on its own |
| `DEMO-CLONE` | (a second "Alizés Transport") | submitted, duplicate name | the pass sorting to `elevated` and leaving it for a person |

Two of those states are produced by the worker rather than by the seed, which
is the point — run them and watch:

```bash
dart run services/worker/bin/worker.dart onboarding   # approves Niari Express, flags the duplicate
dart run services/worker/bin/worker.dart compliance   # stops Cars Lékana selling
```

`onboarding` only approves anything when the API is composed with
`BEL__SCREENING=demo`. That flag is safe to leave set: the screening adapter
clears companies by their own `DEMO-` code, not by the environment, so a flag
that survives into a real deployment auto-approves nobody.

## The open-protection channel

Both selling companies are **in the channel** (`08-disruption.md` §5), so a
call for room put out from either console reaches somebody. That is not a
column the seed sets: it goes through the protection desk, so the audit trail
says which owner joined and on what date — which is the question a dispute
about a rebill actually asks.

A call itself is not seeded, and cannot be: the number of seats on a call is
how many people are *on the coach*, and a call for an empty departure is
refused on purpose. Sell a ticket or two on an Alizés departure first, declare
a breakdown on it, then broadcast — Kouilou's console has the call within a
refresh, and answering it moves the passengers and posts the rebill in one
commit. First to accept wins; there is no second winner to test against on a
one-console demo, but the loser's path is covered in
`services/api/test/integration/open_protection_pg_test.dart`.

Calls nobody answers do not linger:

```bash
dart run services/worker/bin/worker.dart calls   # closes the ones past their window
```

## People

Any phone number accepts the code `123456` in the Auth emulator, and every
address below is a sign-in.

| Sign-in | Who |
|---|---|
| `operations@demo.billetenligne.cg` | platform staff, `operations` — reviews and suspends |
| `direction@demo.billetenligne.cg` | platform staff, `super_admin` — also offboards and approves payouts |
| `angele@demo.billetenligne.cg` | Angèle Mbemba, owner of Alizés Transport |
| `prosper@demo.billetenligne.cg` | Prosper Loubaki, owner of Kouilou Voyages |
| `mireille@demo.billetenligne.cg` | Mireille Nzaba, owner of Cars Lékana |
| `serge@demo.billetenligne.cg` | Serge Loubaki, applicant for Niari Express |
| `clone@demo.billetenligne.cg` | Inconnu Mabiala, the duplicate applicant |
| `+242069000001` | Chancelvie Okemba, a traveller |
