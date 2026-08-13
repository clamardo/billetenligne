@Tags(['sqlite'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_scanner/src/application/boarding_session.dart';
import 'package:bel_scanner/src/infrastructure/sqlite_redemption_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

/// The boarding log that survives being killed.
///
/// Real SQL against a real SQLite, in memory. What is being tested is the
/// storage engine holding a rule the app used to hold in a `Map` — because
/// Android kills a backgrounded camera app under memory pressure, which is
/// exactly what a ten-minute boarding on a cheap handset produces.
void main() {
  late SqliteRedemptionStore store;
  final at = DateTime.utc(2026, 8, 15, 5, 52);

  // A test host is not a handset: on Android the engine is the one
  // `sqlite3_flutter_libs` bundles, and on a developer's Linux box it is
  // whatever the distribution ships — `libsqlite3.so.0` unless the -dev
  // package happens to be installed. The traveller app's vault suite carries
  // the same three lines, for the same reason.
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
        OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'),
      );
    }
  });

  setUp(() => store = SqliteRedemptionStore.memory());
  tearDown(() => store.dispose());

  test('the first scan wins, enforced by the primary key', () {
    final log = store.forDeparture('dep-1');

    log.record(
      bookingRef: 'BEL-7QK4M2',
      seatLabel: '14A',
      at: at,
      deviceId: 'handset-1',
    );
    log.record(
      bookingRef: 'BEL-7QK4M2',
      seatLabel: '14A',
      at: at.add(const Duration(minutes: 3)),
      deviceId: 'handset-2',
    );

    // The time a dispute is settled with is the first one, not the one the
    // conductor's second tap produced.
    expect(log.scannedAt('BEL-7QK4M2', '14A'), at);
    expect(log.count, 1);
    expect(log.pending().single.deviceId, 'handset-1');
  });

  test('two coaches in one day do not share a seat label', () {
    store
        .forDeparture('dep-morning')
        .record(
          bookingRef: 'BEL-AAA111',
          seatLabel: '14A',
          at: at,
          deviceId: 'handset-1',
        );

    // The evening run's 14A has never boarded, and must not be refused.
    expect(
      store.forDeparture('dep-evening').scannedAt('BEL-BBB222', '14A'),
      isNull,
    );
    expect(store.forDeparture('dep-evening').pending(), isEmpty);
  });

  test('what has been sent stays sent, and what has not stays queued', () {
    final log = store.forDeparture('dep-1');
    for (final seat in ['14A', '14B', '2C']) {
      log.record(
        bookingRef: 'BEL-7QK4M2',
        seatLabel: seat,
        at: at,
        deviceId: 'handset-1',
      );
    }

    log.markSynced(['BEL-7QK4M2/14A', 'BEL-7QK4M2/2C']);

    expect(log.pending().single.key, 'BEL-7QK4M2/14B');
    // Everything is still there — the outbox emptied, the record did not.
    expect(log.recorded(), hasLength(3));
    expect(store.departuresAwaitingSync(), ['dep-1']);

    log.markSynced(['BEL-7QK4M2/14B']);
    expect(store.departuresAwaitingSync(), isEmpty);
  });

  test('a manual boarding and a stale-code override survive as themselves', () {
    final log = store.forDeparture('dep-1');
    log.record(
      bookingRef: 'BEL-H4T9RB',
      seatLabel: '5A',
      at: at,
      deviceId: 'handset-1',
      manual: true,
    );
    log.record(
      bookingRef: 'BEL-H4T9RB',
      seatLabel: '5B',
      at: at,
      deviceId: 'handset-1',
      codeWasStale: true,
    );

    final rows = {for (final r in log.recorded()) r.key: r};
    // Counted so an operator can see how often each happens; a spike in
    // either is usually a real problem somewhere else.
    expect(rows['BEL-H4T9RB/5A']!.mode, 'manual');
    expect(rows['BEL-H4T9RB/5B']!.codeWasStale, isTrue);
  });

  test('the counter comes back with the app', () {
    final log = store.forDeparture('dep-1');
    final manifest = BoardingManifest(
      departureId: 'dep-1',
      operatorCode: 'ODN',
      departsAt: at.add(const Duration(minutes: 8)),
      entries: {
        for (final seat in ['14A', '14B', '2C'])
          BoardingManifest.keyFor('BEL-7QK4M2', seat): ManifestEntry(
            bookingRef: 'BEL-7QK4M2',
            seatLabel: seat,
            passengerName: 'Passager $seat',
            rotatingSecret: const [1, 2, 3],
          ),
      },
    );

    for (final seat in ['14A', '14B']) {
      log.record(
        bookingRef: 'BEL-7QK4M2',
        seatLabel: seat,
        at: at,
        deviceId: 'handset-1',
      );
    }

    // The app was killed here. This is the next launch, re-pinning the same
    // coach: a fresh session over the log that outlived it.
    final resumed = BoardingSession(
      manifest: manifest,
      verifier: TicketVerifier(
        signatures: _NothingVerifies(),
        mac: const HmacSha256Authenticator(),
        log: log,
      ),
      log: log,
      deviceId: 'handset-1',
      clock: FixedClock(at),
      resumed: log.recorded(),
    );

    expect(resumed.progress, '2 / 3');
    expect(resumed.boarded.first.passengerName, 'Passager 14A');
    // And the one nobody scanned is still the one the conductor calls for.
    expect(resumed.noShows.single.seatLabel, '2C');
  });

  group('the road, in the same file', () {
    test('a confirmed waypoint survives the app being killed', () {
      store.roadFor('dep-1').confirm(stopId: 'stop-dolisie', at: at);

      // A conductor confirms Dolisie four hours into a run with no signal.
      // Losing that to a backgrounded camera app is losing the only reason
      // somebody at the far end stopped phoning the agency.
      final relaunched = store.roadFor('dep-1');
      expect(relaunched.confirmed()['stop-dolisie'], at);
      expect(relaunched.pending().single.stopId, 'stop-dolisie');
      expect(store.departuresAwaitingCheckpoints(), ['dep-1']);
    });

    test('first tap wins, by the storage engine', () {
      final road = store.roadFor('dep-1');
      road.confirm(stopId: 'stop-nkayi', at: at);
      road.confirm(stopId: 'stop-nkayi', at: at.add(const Duration(hours: 1)));

      // The same rule the server enforces with ON CONFLICT DO NOTHING, held
      // here by INSERT OR IGNORE rather than by whoever remembers it.
      expect(road.confirmed()['stop-nkayi'], at);
    });

    test('two coaches in a day do not share a road', () {
      store.roadFor('dep-1').confirm(stopId: 'stop-nkayi', at: at);

      // A conductor works the outbound and the return. The same waypoint is
      // passed on both, and a log that could not tell them apart would show
      // the evening run already past Nkayi before it left.
      expect(store.roadFor('dep-2').confirmed(), isEmpty);
      expect(store.roadFor('dep-2').pending(), isEmpty);
    });

    test('what went up stops being pending, and stays confirmed', () {
      final road = store.roadFor('dep-1');
      road.confirm(stopId: 'stop-nkayi', at: at);
      road.markSynced(['stop-nkayi']);

      expect(road.pending(), isEmpty);
      expect(store.departuresAwaitingCheckpoints(), isEmpty);
      // Sent is not forgotten: the list still has to draw the tick.
      expect(road.confirmed(), contains('stop-nkayi'));
    });
  });
}

final class _NothingVerifies implements SignatureVerifier {
  @override
  bool verify({
    required List<int> message,
    required List<int> signature,
    required int keyId,
  }) => false;
}
