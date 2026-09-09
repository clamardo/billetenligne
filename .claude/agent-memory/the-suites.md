# 3 · Running the suites and reading what they say

---

## `./tool/integration.sh <path>` **adds** the path — the file then runs twice in one database

**Tally: 1 — 2026-09-09, and it cost more time than anything else that day.**

The script ends in `dart test test/integration --concurrency=1 "$@"`. Passing a file appends it to
the default target, so that file is collected **twice** and both copies run against the same
`billetenligne_it`. Tests keyed on globally-unique fixed idempotency keys then collide, and the
result is **six or seven confident failures that have nothing to do with the change under test**.

**Do instead:** run the whole suite (`./tool/integration.sh`) and read the failures. To iterate on a
single file, run `dart test` directly against the already-provisioned database rather than through
the wrapper.

**And before believing any failure is yours:** `git stash`, run again, compare. That is what proved
these were phantom, after a long time spent "fixing" them.

---

## `services/api`'s suite is run from `services/api`, and a bare relative path is not

**Tally: 1 — 2026-09-09.**

`styled_email_test.dart` opened the catalog as `CatalogLoader.fromDirectory('packages/…/i18n')`,
which only resolves when the process happens to sit at the repo root. `dart test` in this package
does not, so the file failed to **load** — reported as `Failing tests: … loading …`, which looks
like a compile error and is a missing directory. Four other suites in the same directory already
walk up (`['..', '../..', '../../..', '.']`) to find it.

**Do instead:** in `services/api/test`, never write a repo-root-relative path. Copy the `_i18nDirectory()`
walk from `storefront_page_test.dart`. And read `loading <file> [E]` as *the file threw at import
time*, not as *the file does not compile*.

---

## `check.sh` stops at the first failing block, and its output still reads like a list of OKs

**Tally: 1 — 2026-09-09, and a broken guarantee was committed on the strength of it.**

`infra/migrations/check.sh` pipes each verify file through
`grep -E 'NOTICE|PASSED'`. When a `DO $$` block raises, psql stops there and the
script stops with it — but everything up to that point has already printed as
`OK …`. Read with `tail -25`, the run is indistinguishable from a passing one:
the missing evidence is the *last* line, not a visible error, and the final
`── schema checks passed` banner is off the bottom of the window.

0051 granted `bel_public` SELECT on `departure_checkpoints`, which broke an
assertion at the very end of `verify_public.sql` saying that role could not
read the table at all. Three runs were read as passing before the exit code was
looked at.

**Do instead:** run it as `./infra/migrations/check.sh; echo "exit=$?"`, or
`| tail -3` and require the green `── schema checks passed`. A tail of OKs is
not a result. The same applies to `./tool/integration.sh`, whose own banner is
the last line for the same reason.

---

## Migrations are replayed, so a new one must be re-appliable

**Tally: 1 — 2026-09-09 (`0048_operator_custom_roles.sql`, `42P07 relation … already exists`).**

The worker's `migrations_pg_test` applies the whole directory against a database that may already
have it. A migration written once-only turns the worker suite red days after it merged.

**Do instead:** `CREATE TABLE IF NOT EXISTS`, `CREATE UNIQUE INDEX IF NOT EXISTS`, and
`DROP POLICY IF EXISTS` before every `CREATE POLICY`. Every statement, not just the first one.

---

## One database per file, so a fixture constant in one test collides in the next

**Tally: 1 — 2026-09-09.**

`crew_pg_test.dart` uses one `PgFixture` for the whole file (`setUpAll`), which is the house
pattern and right — but it means every test writes into the same rows the others can see. A test
that set the staff number `CH-014` failed on `refTaken: true` because a **different** test forty
lines above had given that number to somebody else at the same operator. The failure reads as "the
uniqueness check is wrong" and is "the fixture is shared".

**Do instead:** treat any value under a unique index — a staff number, a phone suffix, a role name —
as belonging to the *file*, not to the test. Give each test its own, the way the existing suites
already do with `freshName()` and per-test phone suffixes.

---

## Set-up SQL that writes nothing still lets the test "pass" its arrange step

**Tally: 1 — 2026-09-09 (`hold_seats_pg_test`, "a sold seat reads as taken").**

The arrangement cross-joined `bookings` with `LIMIT 1` to find a row to reuse. On a **fresh**
database there are no bookings, the insert wrote zero rows, no error was raised, and the assertion
then failed for a reason that had nothing to do with the behaviour under test.

**Do instead:** arrange through a fixture helper that *creates* what it needs
(`PgFixture.sellSeat`), never through a query that hopes a row exists. If arrange must query, assert
on the affected row count.

---

## A literal future date in a test is a time bomb with a visible fuse

**Tally: 1 — 2026-09-09 (`ticket_link_pg_test`, `DateTime.utc(2026, 8, 15, 6)` + 9 days).**

It was compared against a departure computed from the **database clock**. It passed for months and
started failing on 2026-08-24, in a file nobody had touched.

**Do instead:** read the value back (`SELECT expires_at`) and assert a *relationship*, or drive both
sides from one injected clock. Never write a wall-clock literal that has to stay in the future.

---

## A heredoc inside a backgrounded call is flattened, and `\$` inside it is the shell's

**Tally: 1 — 2026-09-09 (a Python heredoc wrote `\${booking.id}` into Dart source).**

Two separate traps that arrive together. In a `run_in_background` call, newlines become spaces and
the heredoc never produces a file. And in an *unquoted* heredoc, `${…}` is expanded by the shell
before Python ever sees it — Dart interpolation inside such a block is silently mangled.

**Do instead:** quote the delimiter (`<<'PY'`), keep heredocs in **foreground** calls only, and for
anything backgrounded write the script with the Write tool first and background only its
invocation.
