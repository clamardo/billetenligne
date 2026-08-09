# BilletEnLigne — traveller app

Search a route, choose a seat, hold it. Built for the cheapest Android handset
an operator's customers actually carry (ADR-0002).

## Running it

```bash
flutter run                                        # demo data, no server
flutter run --dart-define=BEL_API_URL=http://10.0.2.2:8080   # against the API
```

`10.0.2.2` is the host machine as seen from the Android emulator, which is the
loop this app is developed in. With no `BEL_API_URL` the app runs on
`DemoTravelGateway`: a working timetable and a coach whose seats are genuinely
held, so the whole funnel is reviewable by somebody who is not set up to run
Postgres.

## Layout

```
lib/src/
  application/     the funnel, in pure Dart — no Flutter import, enforced by CI
    ports/         what the outside world must provide
  infrastructure/  the real gateway (bel_client) and the demo one
  presentation/    screens, and the only place that turns a code into a sentence
```

`BookingFlow` is a plain broadcast stream rather than a `ChangeNotifier`,
because `ChangeNotifier` lives in `package:flutter/foundation` and the layer
check refuses Flutter in the application layer. That rule caught this exact
import during the build, and it was right to: a use case that needs the Flutter
SDK cannot be tested with `dart test` and has quietly inverted the dependency
direction.

## Strings

Every string comes from the YAML catalog in `packages/bel_localization/i18n`,
copied here by `tool/sync_i18n.sh` and fingerprinted by
`test/i18n_freshness_test.dart`. French is the source and the fallback: a phone
set to a language we do not speak gets French, which every traveller in this
market reads.

## Two traps when testing this app

Both are documented in `test/funnel_widget_test.dart`, and both cost an hour:

* **Never `await` gateway work outside a pump.** A widget test runs in a
  fake-async zone where the clock advances only while pumping, so
  `await flow.holdSelection()` on its own hangs forever.
* **Never `pumpAndSettle` on the hold screen.** The countdown schedules a frame
  every second for as long as it lives, so nothing ever settles.
