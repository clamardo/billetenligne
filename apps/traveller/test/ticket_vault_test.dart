@Tags(['sqlite'])
library;

import 'dart:ffi';
import 'dart:typed_data';
import 'dart:io';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_traveller/src/infrastructure/sqlite_ticket_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

/// The ticket that survives the process being killed, against a real SQLite.
///
/// In memory rather than on disk, which is the same engine and the same SQL —
/// what a file adds is a path, and a path is the one thing here that cannot
/// be exercised on a test host anyway.
void main() {
  // A test host is not a handset. On Android the engine is the one
  // `sqlite3_flutter_libs` bundles, and on a developer's Linux box it is
  // whatever the distribution ships — which is `libsqlite3.so.0` unless the
  // -dev package (and with it the bare `.so` symlink) happens to be
  // installed. Pointing at the versioned name is what keeps this suite
  // runnable on a clean machine.
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
        OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'),
      );
    }
  });

  late SqliteTicketVault vault;

  setUp(() => vault = SqliteTicketVault.memory());
  tearDown(() => vault.close());

  BookingDto booking(String id, {int seats = 1}) => BookingDto(
    id: id,
    ref: 'BEL-$id',
    state: 'confirmed',
    departureId: 'dep-$id',
    operatorName: 'Océan du Nord',
    originCity: 'BZV',
    destinationCity: 'PNR',
    departsAt: DateTime.utc(2026, 8, 20, 5),
    arrivesAt: DateTime.utc(2026, 8, 20, 13),
    passengers: [
      for (var i = 0; i < seats; i++)
        PassengerDto(fullName: 'Aline M.', seatLabel: '${i + 1}A'),
    ],
    fare: const Money.xaf(12000),
    serviceFee: const Money.xaf(300),
    total: const Money.xaf(12300),
    createdAt: DateTime.utc(2026, 8, 19),
    tickets: [
      for (var i = 0; i < seats; i++)
        TicketDto(
          id: 'tk-$id-$i',
          bookingRef: 'BEL-$id',
          seatLabel: '${i + 1}A',
          passengerName: 'Aline M.',
          qrPayload: 'BEL1.$id.${i + 1}A.signature',
          rotatingSecret: 'sixty-four-bits-of-secret',
          keyId: 1,
          issuedAt: DateTime.utc(2026, 8, 19),
        ),
    ],
  );

  test(
    'a ticket read back is the ticket that was stored, signature and all',
    () async {
      await vault.write('user-1', [booking('a', seats: 2)]);

      final back = await vault.read('user-1');

      // Whole or useless: a row missing its signature renders a QR no conductor
      // will accept, which is worse than no row at all.
      expect(back, hasLength(1));
      expect(back.single.ref, 'BEL-a');
      expect(back.single.tickets, hasLength(2));
      expect(back.single.tickets.first.qrPayload, 'BEL1.a.1A.signature');
      expect(back.single.tickets.first.rotatingSecret, isNotEmpty);
      expect(back.single.total, const Money.xaf(12300));
    },
  );

  test('a second write replaces the first, it does not add to it', () async {
    await vault.write('user-1', [booking('a'), booking('b')]);
    await vault.write('user-1', [booking('a')]);

    // The answer the server just gave is the whole truth about what this
    // traveller holds. Merging would keep a refunded ticket renderable
    // forever.
    final back = await vault.read('user-1');
    expect(back.map((b) => b.ref), ['BEL-a']);
  });

  test('one handset, two travellers, two sets of tickets', () async {
    await vault.write('user-1', [booking('a')]);
    await vault.write('user-2', [booking('b')]);

    // A telephone here is shared. A vault keyed on nothing hands the next
    // person to sign in somebody else's journey.
    expect((await vault.read('user-1')).single.ref, 'BEL-a');
    expect((await vault.read('user-2')).single.ref, 'BEL-b');
  });

  test('signing out forgets everybody', () async {
    await vault.write('user-1', [booking('a')]);
    await vault.write('user-2', [booking('b')]);

    await vault.clear();

    expect(await vault.read('user-1'), isEmpty);
    expect(await vault.read('user-2'), isEmpty);
  });

  test(
    'a traveller with nothing stored gets an empty list, not an error',
    () async {
      expect(await vault.read('nobody'), isEmpty);
    },
  );

  test('storing nothing empties the vault rather than leaving it', () async {
    await vault.write('user-1', [booking('a')]);
    await vault.write('user-1', const []);

    // A traveller whose last booking was refunded holds no tickets, and the
    // handset has to agree with that.
    expect(await vault.read('user-1'), isEmpty);
  });

  group('the company mark that travels with the ticket', () {
    // Not a real PNG. Nothing here decodes them — the vault stores bytes and
    // the widget decides what to do with what it gets — so a recognisable
    // pattern makes a failure readable.
    Uint8List mark(int seed, {int length = 64}) =>
        Uint8List.fromList(List.filled(length, seed));

    test('what was stored is what comes back', () async {
      await vault.putLogo('https://cdn/odn.png', mark(7));

      expect(await vault.logo('https://cdn/odn.png'), mark(7));
      // A mark this handset never managed to fetch is null, not an empty
      // list: the ticket draws its band and its name instead.
      expect(await vault.logo('https://cdn/never.png'), isNull);
    });

    test('a new mark at the same URL replaces the old bytes', () async {
      await vault.putLogo('https://cdn/odn.png', mark(1));
      await vault.putLogo('https://cdn/odn.png', mark(2));

      expect(await vault.logo('https://cdn/odn.png'), mark(2));
    });

    test(
      'a company that redesigns its mark does not cost two copies',
      () async {
        await vault.putLogo('https://cdn/odn-v1.png', mark(1));
        await vault.putLogo('https://cdn/odn-v2.png', mark(2));

        // The tickets now name only the new one. The old bytes are nobody's.
        await vault.keepLogos({'https://cdn/odn-v2.png'});

        expect(await vault.logo('https://cdn/odn-v1.png'), isNull);
        expect(await vault.logo('https://cdn/odn-v2.png'), mark(2));
      },
    );

    test('a traveller holding no marked tickets holds no marks', () async {
      await vault.putLogo('https://cdn/odn.png', mark(1));

      await vault.keepLogos(const {});

      expect(await vault.logo('https://cdn/odn.png'), isNull);
    });

    test('an oversized file is refused rather than kept', () async {
      // What answers a URL is whatever answers it. A misconfigured CDN
      // handing back a 4 MB original must not end up in the file that has to
      // survive on a full handset.
      await vault.putLogo(
        'https://cdn/huge.png',
        mark(3, length: SqliteTicketVault.maxLogoBytes + 1),
      );

      expect(await vault.logo('https://cdn/huge.png'), isNull);
    });

    test('signing out forgets the marks too', () async {
      await vault.putLogo('https://cdn/odn.png', mark(1));

      await vault.clear();

      expect(await vault.logo('https://cdn/odn.png'), isNull);
    });
  });
}
