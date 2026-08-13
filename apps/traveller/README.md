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

## A ticket link that opens the app

`blt.cg/b/{token}` is one URL with two renderings (ADR-0026): this app when it
is installed, a server-rendered page when it is not. There is deliberately no
interstitial in between — an "install our app" screen in front of a boarding
pass, at a coach door, is the worst screen we could build.

**Android is wired.** The manifest claims `https://blt.cg/b/*` with
`autoVerify`, and `flutter_deeplinking_enabled` hands the URL to Flutter as the
initial route rather than through a plugin channel. The domain's half of the
handshake is served by the API at `/.well-known/assetlinks.json`, from
`BEL__ANDROIDPACKAGE` and `BEL__ANDROIDFINGERPRINTS`. Until a release
certificate exists the fingerprint list is empty, the file is still served, and
Android simply declines to verify — the link opens the page, which is the
correct fallback rather than a failure.

**iOS is one Xcode change away.** `ios/Runner/Runner.entitlements` exists and
declares `applinks:blt.cg`, but it is not attached to the Runner target: doing
that means editing the Xcode project, and there is no Mac and no Apple team for
this deployment. The server half — `/.well-known/apple-app-site-association`,
unsigned and with no `.json` extension, as iOS has required since 9 — is
already served from `BEL__APPLEAPPID`.

The follower page at `/t/` is **not** claimed by either platform. It is opened
by strangers with no account and no app, and an operating system offering to
install one would be answering a question nobody asked.
