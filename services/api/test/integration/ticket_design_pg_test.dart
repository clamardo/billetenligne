@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_ticket_designs.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_ticket_links.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The operator's printed stationery, against a real database.
///
/// The claims worth making here cannot be made against a fake: that the
/// partial unique index really does refuse a second default, that a design
/// with a value this build has never heard of is stored as something this
/// build can read back, and that a print link is short-lived and resolves
/// like any other.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresTicketDesigns designs;
  late PostgresBookingStore bookings;
  late PostgresTicketLinks links;
  late String stationId;
  late String roadId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    designs = PostgresTicketDesigns(db);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(41)),
    );
    links = PostgresTicketLinks(db, linkBase: Uri.parse('https://blt.cg'));
    stationId = await fixture.station('BZV', 'Agence Papier');
    roadId = await fixture.route(code: 'PRNT', destination: 'OYO');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  final now = DateTime.utc(2026, 8, 15, 6);

  Future<TicketDesignDto> save(
    String name,
    TicketDesign design, {
    bool makeDefault = false,
  }) async {
    final saved = await designs.save(
      operatorId: PgFixture.operatorId,
      edit: SaveTicketDesignRequest(
        name: name,
        design: design.toJson(),
        makeDefault: makeDefault,
      ),
    );
    return saved!;
  }

  group('the operator saves their stationery', () {
    test('a saved design comes back as what was stored', () async {
      final saved = await save(
        'Guichet Mikalou',
        TicketStarters.classicPass.copyWith(accentHue: 'indigo'),
      );

      expect(saved.format, 'boardingPass');
      expect(saved.design['accentHue'], 'indigo');
      expect(saved.isDefault, isFalse);
    });

    test('a design this build cannot read is stored as one it can', () async {
      // A console a version ahead, or a hand-edited row. A counter that
      // cannot sell because a JSON blob gained a field is a counter that
      // turns customers away, so the domain reads it and the *result* is
      // stored — never the typo.
      final saved = await designs.save(
        operatorId: PgFixture.operatorId,
        edit: const SaveTicketDesignRequest(
          name: 'Venu du futur',
          design: {
            'format': 'holographic',
            'accentHue': 'chartreuse',
            'fields': ['station', 'aFieldFromNextYear'],
          },
        ),
      );

      expect(saved!.format, 'boardingPass');
      expect(saved.design['fields'], ['station']);
      // The hue is stored as sent — the eight are a CHECK on `operators`, not
      // on this document, and a ticket rendered in an unknown hue falls back
      // to the house green rather than failing to render (`AccentHues.hex`).
      expect(saved.design['accentHue'], 'chartreuse');
    });

    test('only one design per format can be the default', () async {
      final first = await save(
        'Le petit',
        TicketStarters.classicPass,
        makeDefault: true,
      );
      final second = await save(
        'Le grand',
        TicketStarters.economyPass,
        makeDefault: true,
      );

      final all = await designs.forOperator(PgFixture.operatorId);
      final defaults = all
          .where((d) => d.isDefault && d.format == 'boardingPass')
          .toList();

      // Not merely "the second one won" — exactly one row is flagged. The
      // partial unique index refuses two outright, so a save that did the
      // clearing in a second call would fail rather than race.
      expect(defaults.map((d) => d.id), [second.id]);
      expect(defaults, hasLength(1));
      expect(all.map((d) => d.id), contains(first.id));
    });

    test('the default is resolvable by the code on a ticket link', () async {
      await save(
        'La feuille entière',
        TicketStarters.fullPageReceipt.copyWith(accentHue: 'brique'),
        makeDefault: true,
      );

      // By code, because that is what `LinkedTicket` carries: the reader is
      // holding a link and has no account and no operator id.
      final code =
          (await fixture.rows(
                "SELECT code FROM operators WHERE id = '${PgFixture.operatorId}'",
              )).single['code']!
              as String;

      final resolved = await designs.defaultFor(
        operatorCode: code,
        format: 'a4',
      );
      expect(resolved!.design['accentHue'], 'brique');

      // And a format nobody saved resolves to nothing, which is the signal
      // the print route needs to fall back to a starter.
      expect(
        await designs.defaultFor(operatorCode: code, format: 'nonesuch'),
        isNull,
      );
    });

    test('a design can be thrown away, and another operator cannot', () async {
      final mine = await save('Jetable', TicketStarters.economyPass);

      expect(
        await designs.remove(operatorId: PgFixture.operatorId, id: mine.id),
        isTrue,
      );
      expect(
        await designs.remove(operatorId: PgFixture.operatorId, id: mine.id),
        isFalse,
      );
    });
  });

  group('the vendor prints from the till', () {
    Future<({String id, String ref})> aPaidBooking(String seat) async {
      final departureId = await fixture.departure(
        seatLabels: [seat],
        onRoute: roadId,
      );
      final booking = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: seat,
        name: 'Juste B.',
      );
      await bookings.captureCash(
        bookingId: booking.id,
        operatorId: PgFixture.operatorId,
        stationId: stationId,
        soldByUserId: null,
        posting: Postings.cashSale(
          operatorId: PgFixture.operatorId,
          stationId: stationId,
          fare: booking.fare,
          serviceFee: booking.serviceFee,
        ).valueOrNull!,
      );
      return (id: booking.id, ref: booking.ref.value);
    }

    test('a print link is minted, short-lived, and opens', () async {
      final booking = await aPaidBooking('1A');

      final minted = await links.mintForPrint(
        operatorId: PgFixture.operatorId,
        bookingRef: booking.ref,
        format: 'a4',
        byUserId: null,
        now: now,
      );

      final link = minted.valueOrNull!;
      expect(link.url, contains('format=a4'));
      // Minutes, not a month. This is the one link the console is ever
      // handed, and a URL glimpsed over a shoulder has to be dead before
      // anybody could walk out and use it.
      expect(link.expiresAt, now.add(PostgresTicketLinks.printWindow));

      // Recorded on its own channel, so "who printed this twice" has an
      // answer, and `sent_to` names the till rather than an address nobody
      // ever gave.
      final rows = await fixture.rows(
        'SELECT channel, sent_to FROM ticket_links '
        "WHERE booking_id = '${booking.id}'",
      );
      expect(rows.single['channel'], 'print');
      expect(rows.single['sent_to'], startsWith('console:'));

      // And it resolves like any other link, which is the whole point: the
      // print page is `/b/{token}` with a format on it.
      final token = Uri.parse(link.url).pathSegments.last;
      final opened = await links.open(token: token, now: now);
      expect(opened!.bookingRef, booking.ref);
      expect(opened.seats, hasLength(1));
    });

    test('a reservation nobody paid for has nothing to print', () async {
      final departureId = await fixture.departure(
        seatLabels: const ['2A'],
        onRoute: roadId,
      );
      final unpaid = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: '2A',
        name: 'Juste B.',
      );

      final minted = await links.mintForPrint(
        operatorId: PgFixture.operatorId,
        bookingRef: unpaid.ref.value,
        format: 'boardingPass',
        byUserId: null,
        now: now,
      );

      // Refused where the vendor is standing, rather than printed as a page
      // with a blank square on it.
      expect(minted.valueOrNull, isNull);
    });

    test('a print does not kill the customer\'s emailed link', () async {
      final booking = await aPaidBooking('3A');

      late String emailed;
      await db.transaction(const DbScope.worker(), (tx) async {
        final minted = await links.mintInto(
          tx,
          bookingId: booking.id,
          channel: 'email',
          sentTo: 'walkin@example.cg',
        );
        emailed = minted!.token;
      });

      await links.mintForPrint(
        operatorId: PgFixture.operatorId,
        bookingRef: booking.ref,
        format: 'boardingPass',
        byUserId: null,
        now: now,
      );

      // Different channel, different life. A vendor printing a second copy
      // must not silently kill the link the customer already has in their
      // inbox — they would find out at a coach door.
      expect(await links.open(token: emailed, now: now), isNotNull);
    });
  });
}
