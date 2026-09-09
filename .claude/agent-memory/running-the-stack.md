# 2 · Bringing the stack up and driving the app

**The most expensive file so far.** Every entry is a way of running the app slightly wrong and
getting a plausible screen back instead of an error.

The working launch, in full, is in [`run-local-stack`](../skills/run-local-stack/SKILL.md). Read the
skill for the commands; read this for the ways they go wrong.

---

## A missing `--dart-define` turns a *correct* code into "Sign in to continue."

**Tally: 1 — 2026-09-09. Cost roughly an hour and a wrong diagnosis.**

Launched without `--dart-define=BEL_FIREBASE_EMULATOR=localhost:9099`. Sign-in then does two things
that look like one: our API accepts the six digits (200, code consumed), and `BelSession.adopt`
exchanges the custom token with Firebase — which, pointed at production from an emulator, fails.

The screen showed **"Sign in to continue."** on a code that was right, with the code already spent.
Every instinct said the sign-in flow was broken. Nothing was broken except the launch command.

**Do instead:** launch with *both* defines, always:

```
flutter run -d emulator-5554 \
  --dart-define=BEL_API_URL=http://localhost:8080 \
  --dart-define=BEL_FIREBASE_EMULATOR=localhost:9099
```

The symptom is now a distinct message (`errors.auth.not_completed`, "Your code was correct, but
signing in did not finish") rather than the generic unauthorised sentence, so the *next* occurrence
says so on screen. That is a signpost, not a guard — the launch still has to be right.

---

## `BEL_API_URL`, not `BEL_API_BASE_URL` — and the wrong name fails silently

**Tally: 1 — 2026-09-09.**

The define is `BEL_API_URL`. Get the name wrong and nothing errors: the app falls back to its demo
gateways and shows **invented coaches the API has never heard of**, on a screen that looks entirely
normal. The tell is data that does not match what is in Postgres.

Write `localhost`; `_reachable()` rewrites it per platform (`10.0.2.2` on the Android emulator).
Writing `10.0.2.2` yourself breaks the desktop and web targets.

**Do instead:** after launching, check one value on screen against the database before trusting
anything else on it.

---

## The fake payment rail only settles for two magic numbers

**Tally: 1 — 2026-09-09.**

`FakePaymentGateway` (registered as `cg.fake_money` whenever no real rail has credentials) ignores
any other MSISDN and leaves the payment **pending forever**, which reads exactly like a broken
poller.

| Enter in the app | MSISDN | Behaviour |
|---|---|---|
| `060000000` | `242060000000` | always declines |
| `060000001` | `242060000001` | settles **one poll later** |

Settlement happens on the *query*, not on the request — so a screen that never polls never settles.

---

## A fresh Postgres, beside the one already running

The user has their own Postgres on the default port. Never take 5432.

```
BEL_DEV_PROJECT=billetenligne-alt BEL_DEV_PORT=5442 BEL_ENV_FILE=$PWD/infra/dev/.env.alt
```

Mailpit for the one-time codes: UI at `http://localhost:8025`, and
`curl -s 'http://localhost:8025/api/v1/messages?limit=1'` to read the latest without a browser.

---

## `pkill` chained to the relaunch exits 144 and the relaunch never happens

**Tally: 3 — all 2026-09-09.**

```bash
pkill -f "flutter_tools.*run" && flutter run …     # exit 144, no relaunch
```

**144 is what this `pkill` returns here even when it worked** — the third occurrence killed the app
correctly and still exited 144. So it is useless as a success signal and fatal as a `&&` guard.

**Do instead:** issue the kill as its **own** call, ignore its exit code, and launch separately.

While there: `flutter run` started with `nohup … &` has **no stdin**, so `r` (hot reload) and `q`
cannot be sent to it and every code change costs a full rebuild. Give it a fifo at launch —
`mkfifo f; nohup bash -c 'exec 3<>f; flutter run … <&3' &` — then `echo r > f` reloads. And redirect the launch to
a log file rather than piping it — a `flutter run` on the left of a pipe hides everything until it
exits, which for a long-lived process is forever.
