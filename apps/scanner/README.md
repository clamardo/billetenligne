# BilletEnLigne — boarding scanner

The conductor's app. It exists to answer one question at a coach door, in
direct sun, in under two seconds, with the radio switched off: **does this
person board?** (ADR-0022)

## Running it

```bash
flutter run                                                  # a signed demo coach, no server
flutter run --dart-define=BEL_API_URL=http://10.0.2.2:8080   # against the API
```

`10.0.2.2` is the host machine as seen from the Android emulator. With no
`BEL_API_URL` the app runs on `DemoBoardingGateway`: a departure with eight
passengers, **genuinely Ed25519-signed**, with live rotating codes. It makes
the same three calls the real gateway does, so the coach list, the pin and the
outbox all work on a fresh clone — and a demo that faked its own verdict would
prove nothing.

Other defines: `BEL_DEVICE_ID` names the handset on every redemption (unique
per launch otherwise), and `BEL_FIREBASE_EMULATOR` points the sign-in at a
local emulator.

## The shape of a boarding

1. **Sign in** — `bel_backoffice`'s shared screen, second factor included. A
   conductor is operator staff, and ADR-0013 has no smaller tier.
2. **Pick today's coach** — `GET /console/v1/boarding?date=`. Route, hour,
   yard, how many are expected. No money, no names: the `conductor` role holds
   `boarding.scan` and nothing else.
3. **Pin it** — `GET /console/v1/departures/{id}/boarding`. Passengers, their
   rotating secrets, the ticket-signing public keys, and every ticket voided
   since it was signed. **This is the last time the network is needed.**
4. **Board** — every verdict is a local decision: a signature check, a manifest
   lookup and the device's own redemption log.
5. **Empty the outbox** — `POST /console/v1/departures/{id}/redemptions`, when
   somebody taps it, wherever there is signal. Both `recorded` and `unknown`
   leave the queue; a ticket this coach has never heard of will not start being
   on it, and a handset that retries forever is flat by eleven.

## Layout

```
lib/src/
  application/     the session, the sync, in pure Dart — no Flutter, enforced by CI
    ports/         BoardingGateway, RedemptionOutbox
  infrastructure/  the API gateway, the demo one, the redemption log
  presentation/    the picker, the door, the verdict
```

## The trap that cost a bug

`SignatureVerifier.verify` is **synchronous** — a conductor boarding sixty
people cannot wait on a future per scan — while real Ed25519 is not. The gap is
`SignaturePreparer`: `BoardingSession.warm(raw)` does the async half on the one
payload just decoded, immediately before `scan` decides.

The demo departure prepares every signature when it *builds* them, so the app
looked correct for as long as it only ever ran against a fixture. Against a
real coach the device has never seen a traveller's signature until the camera
reads it, and without `warm` **every genuine ticket reads as forged**.
`test/wire_boarding_test.dart` fails if that await goes away.

## Strings

Deliberately French, written where they are shown. There is one audience, they
are standing at a coach door, and an indirection between them and the word
*EMBARQUÉ* buys nothing. The catalog is bundled for exactly one screen — the
shared sign-in, which speaks in keys — and `test/i18n_freshness_test.dart`
fingerprints the copy against `packages/bel_localization/i18n`.

## Tests

```bash
flutter test
```

`boarding_test.dart` is the door against the demo coach; `wire_boarding_test.dart`
is the door against a manifest that arrived as JSON, with a scripted transport
and real signatures; `coach_picker_test.dart` is the screen between the two.
