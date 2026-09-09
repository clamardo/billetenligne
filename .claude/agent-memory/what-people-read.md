# 4 · Copy the traveller reads

The server never sends prose (ADR-0008): it sends a **code and parameters**, and the sentence is
chosen on the client from the catalog. That rule is the reason every entry here exists — a failure
without a key of its own has to borrow somebody else's sentence, and borrowed sentences lie.

---

## A raw dotted key on screen means the catalog is missing a leaf

**Tally: 2 — 2026-09-09 (`enum.PaymentRail.cg.fake_money` on the payment screen; `enum.TripSort.*`
on the results screen, J8).**

Nothing fails. `context.t` returns the key, and the key is displayed to the traveller as if it were
words. Enum labels live under `enum.{TypeName}.{value}`, and a new enum value needs its EN **and**
FR line or it ships as a dotted string.

The second occurrence was **not** a missing entry: `TripSort` was written in both languages, and
appended to the *end* of `enums/domain.yaml` — which is four top-level blocks below `enum:`, under
`disruption:`. The real key was `disruption.TripSort.earliest`. Every guard passed, because the
catalog tests check EN/FR **parity** and placeholders, and both files were wrong in the same way.

**Do instead:** append into the block, never onto the end of the file — `grep -n '^[a-z]' <file>`
first and check which top-level key you are actually under. And when a new label is added, assert it
from the widget test that renders it (`find.text('Le moins cher')`), which is the only check that
reads the key the way the traveller does.

---

## Edit `packages/bel_localization/i18n/`, never `apps/*/assets/i18n/`

`apps/*/assets/i18n/` is **generated and gitignored**. Editing it appears to work — the app picks
the change up — and the edit is gone the next time anyone runs the sync.

Source of truth: `packages/bel_localization/i18n/{en,fr}/**.yaml`. Then `./tool/sync_i18n.sh`.

---

## Reusing another failure's message key puts a false sentence on a dead end

**Tally: 1 — 2026-09-09 (`errors.auth.unauthorized`, "Sign in to continue.").**

When the Firebase exchange failed *after* our API had accepted and consumed the one-time code, the
underlying `FirebaseRefused` carried `errors.auth.unauthorized`. The traveller was told to sign in,
having just done so, on a screen where the only remaining action was impossible: the code on it was
already spent.

**Do instead:** when a failure means something the existing key does not, give it its **own** type
and its **own** key, and wrap at the layer that knows the difference (here `adoptGranted`, because
only the caller that spent the code knows the code was spent). Then adapt the screen — a message
that names a dead end must be accompanied by removing the dead action and offering the live one.

The general form: **the message and the buttons are one answer.** Changing the sentence and leaving
the buttons is half a fix.

---

## Kilo tokens only

No raw hex, no `Colors.*` — the lint and the contrast gates in CI both fail on it. Spacing comes
from `KiloSpacing` (`s1`…`s16`, a 4pt scale), never a bare number. Empty, loading, failed and
offline states are `KStateView`'s sealed cases rather than hand-rolled columns; a screen that
hand-rolls one is a screen whose empty state is white and centred and wrong.
