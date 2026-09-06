---
name: mutation-check
description: Test the sensitivity of BilletEnLigne tests by temporarily applying plausible wrong Dart logic or SQL policies in an isolated copy. Use after changing business decisions, company isolation, permissions, money, ticketing or migration invariants.
---

# Check whether the tests would notice a wrong implementation

A passing test suite does not establish that it detects a broken company predicate,
payment transition or booking rule. Mutate meaningful decisions changed by the slice;
skip documentation, styling and mechanically equivalent moves.

## Choose meaningful mutations

Examples for this repository:

- Remove a company predicate, traveller-owner check, or RLS `WITH CHECK` restriction.
- Permit a revoked staff membership or remove the active-operator check.
- Let a vendor use another station or a conductor use another departure.
- Remove a payment capture guard, duplicate-callback check or hold-expiry comparison.
- Change refund caps, minor-unit allocation, policy-version selection or seat overlap logic.
- Omit company/actor identity from a replay key or return cached bytes before authorization.

One mutation at a time, selected for a plausible defect. SQL mutations require real
PostgreSQL tests; Dart fakes cannot prove that an RLS policy notices a foreign row.

## Safe loop

1. Record the working-tree state and exact baseline bytes of touched files. Use a disposable
   copy when the tree has user edits or another process may be using it. Never demand the
   user discard existing work, reset the project, or mutate their running server's source.
2. Run the smallest relevant suite on the unmodified baseline and confirm assertions
   actually executed. Select from [regression-check](../regression-check/SKILL.md).
3. Apply one exact replacement and require exactly one match. Keep restoration in a
   `finally`/trap path, with an explicit final byte comparison even after interruption.
4. Recompile/run the changed source. For SQL, rebuild a dedicated disposable database
   from the mutated migration set; never change a live database or its migration ledger.
5. Classify the outcome: **KILLED** only for the intended test assertion/expected invariant
   failure; **SURVIVED** for a passing executed suite; **NO-BUILD/INFRA** for compile errors,
   unrelated SQL errors, skipped tests, timeouts or unavailable dependencies.
6. Restore exact bytes and refresh modification times so cached builds cannot retain the
   mutant. Compare the tree against the recorded baseline before the next mutation. If
   restoration or artifact freshness is uncertain, stop and re-establish a passing baseline.
7. After the last restoration, rerun the relevant unmutated checks. Never merge or report
   green while a mutant or stale compiled artifact remains.

Use targeted `dart test` or `flutter test` invocations, not a full application build per
mutation. Use separate PostgreSQL container names/ports for schema or integration mutants;
the normal runners recreate databases and must not share infrastructure with another run.

## Survivors and reporting

For a survivor, construct the input that distinguishes correct from mutated behavior.
Add the missing observable assertion when the path is reachable. Remove dead code only
after proving it unreachable within the intended feature contract. Do not weaken a mutant
just to produce a kill or count syntax errors as successful detection.

Report baseline command/result, mutations attempted, kills, survivors and invalid runs
separately, what survivors changed, and final restoration/verification. This skill does
not require an external mutation service or authorize deployment, merging or publication.
