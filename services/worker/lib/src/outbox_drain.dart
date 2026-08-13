import 'dart:convert';

import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/documents/pdf_response.dart';
import 'package:bel_api/src/infrastructure/documents/statement_pdf.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_payouts.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_ticket_links.dart';
import 'package:bel_api/src/infrastructure/web/qr_png.dart';
import 'package:bel_api/src/infrastructure/web/ticket_email.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:postgres/postgres.dart';

import 'sweepers.dart';

/// Delivers what the request path composed.
///
/// **A send is never inline with a request** (ADR-0019 rule 1). Confirming a
/// booking writes an outbox row inside the same transaction that posts the
/// ledger and issues the ticket; this drains it. The consequence is the one
/// that matters: a slow SMS gateway cannot slow down a payment confirmation,
/// and an unreachable one cannot fail it.
///
/// Four properties, each of which is a real failure this avoids:
///
///   * **Composed in the recipient's stored language**, on the server, from
///     the shared catalog (ADR-0008). The traveller never receives a message
///     in whatever language the sending process happened to default to.
///   * **`FOR UPDATE SKIP LOCKED`**, so two drains running at once split the
///     queue rather than fighting over the front of it.
///   * **Marked delivered in the same transaction as the send is attempted.**
///     The window between them is the one where a crash sends twice.
///   * **Exponential backoff on failure**, so a bad address does not spin at
///     full rate for a day — every attempt is a message we pay for.
final class OutboxDrain {
  OutboxDrain({
    required Database db,
    required NotificationGateway notifications,
    required TranslationCatalog catalog,
    required this.timeZone,
    PostgresTicketLinks? links,
    this.maxAttempts = 6,
  }) : _db = db,
       _notifications = notifications,
       _catalog = catalog,
       _links = links ?? PostgresTicketLinks(db);

  final Database _db;
  final NotificationGateway _notifications;
  final TranslationCatalog _catalog;

  /// Mints the ticket links this drain sends (ADR-0026). On the drain rather
  /// than behind the port because minting is a write inside *this*
  /// transaction: the row and the message that carries the token commit
  /// together or neither does.
  final PostgresTicketLinks _links;

  /// Six attempts over about an hour of backoff. Past that a message is not
  /// arriving, and a queue that retries forever is a queue that hides a dead
  /// address behind a growing number.
  final int maxAttempts;

  /// The market's zone, and every time in every message is rendered in it.
  ///
  /// **By Postgres, not by Dart.** `timestamptz` arrives here as UTC, and a
  /// message that says "départ 05h00" for the 06:00 from Brazzaville is a
  /// passenger who misses their coach by an hour — the one failure in this
  /// file a traveller would actually be harmed by. Dart's own library has no
  /// zone database; the database next to us does.
  final String timeZone;

  Future<SweepResult> drain({int limit = 100}) async {
    var sent = 0;

    for (var i = 0; i < limit; i++) {
      final delivered = await _next();
      if (delivered == null) break;
      if (delivered) sent++;
    }

    return SweepResult(name: 'outbox.delivered', affected: sent);
  }

  /// One message. Null when the queue is empty.
  Future<bool?> _next() => _db.transaction(const DbScope.worker(), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
            SELECT id, event_type, payload
              FROM outbox
             WHERE delivered_at IS NULL
               AND next_attempt_at <= now()
               AND attempts < @max
             ORDER BY next_attempt_at
             LIMIT 1
             FOR UPDATE SKIP LOCKED
          '''),
      parameters: {'max': TypedValue(Type.integer, maxAttempts)},
    );

    if (rows.isEmpty) return null;

    final row = rows.first.toColumnMap();
    final id = row['id'] as int;
    final payload = _decode(row['payload']);

    final message = await _compose(tx, row['event_type'] as String, payload);

    // Nothing to send is not a failure: a booking whose purchaser left no
    // reachable address is a perfectly ordinary counter sale. Marked
    // delivered so it stops being retried.
    if (message == null) {
      await _markDelivered(tx, id);
      return false;
    }

    final failure = await _notifications.send(message);

    if (failure == null) {
      await _markDelivered(tx, id);
      return true;
    }

    // Backoff doubles per attempt: one minute, two, four… An address that
    // bounces would otherwise be retried at full rate for a day, and
    // every one of those is a message we pay for.
    await tx.execute(
      Sql.named('''
            UPDATE outbox
               SET attempts = attempts + 1,
                   last_error = @error,
                   next_attempt_at =
                     now() + make_interval(mins => power(2, attempts)::int)
             WHERE id = @id
          '''),
      parameters: {
        'id': TypedValue(Type.bigInteger, id),
        'error': TypedValue(Type.text, failure.name),
      },
      ignoreRows: true,
    );
    return false;
  });

  Future<void> _markDelivered(TxSession tx, int id) => tx.execute(
    Sql.named('UPDATE outbox SET delivered_at = now() WHERE id = @id'),
    parameters: {'id': TypedValue(Type.bigInteger, id)},
    ignoreRows: true,
  );

  /// Renders the message, in the recipient's stored language.
  ///
  /// The recipient and the language are read **now**, not carried in the
  /// payload: a traveller who changed their language between booking and
  /// delivery should get the new one, and an address written into a queue row
  /// is an address that goes stale.
  Future<OutboundMessage?> _compose(
    TxSession tx,
    String eventType,
    Map<String, Object?> payload,
  ) async {
    switch (eventType) {
      case 'booking.confirmed':
        final bookingId = payload['bookingId'];
        if (bookingId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT b.ref, u.phone_e164, u.email, u.language,
                   r.origin_city, r.destination_city,
                   to_char(d.departs_at AT TIME ZONE @tz, 'DD/MM')
                     AS departs_date,
                   to_char(d.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS departs_time,
                   (SELECT string_agg(bs.seat_label, ', ' ORDER BY bs.seat_label)
                      FROM booking_seats bs WHERE bs.booking_id = b.id) AS seats
              FROM bookings b
              JOIN departures d ON d.id = b.departure_id
              JOIN routes r ON r.id = d.route_id
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
             WHERE b.id = @id
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, bookingId),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        if (rows.isEmpty) return null;
        final b = rows.first.toColumnMap();

        // SMS where we have a number, email otherwise. SMS is the trust
        // anchor in this market and everything touching money goes out on it
        // (ADR-0019 rule 7) — but a counter sale to somebody with no handset
        // still deserves a receipt.
        final phone = b['phone_e164'] as String?;
        final email = b['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, b['language'] as String? ?? 'fr');
        final params = <String, Object?>{
          'route': '${b['origin_city']}–${b['destination_city']}',
          'date': b['departs_date'],
          'time': b['departs_time'],
          'seat': b['seats'] ?? '',
          'reference': 'BEL-${b['ref']}',
        };

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : t('email.booking.subject', params),
          body: t('sms.paymentConfirmed.body', params),
          // Matches the dedupe key the writer used, so a message composed by
          // two drains is still one message.
          eventId: 'booking.confirmed:$bookingId',
        );

      case 'ticket.link':
        // The one place a ticket-link token is ever minted (ADR-0026). It is
        // here, and not in the request that asked for it, so the plaintext
        // exists in the message below and in a SHA-256 hash — never in a
        // queue row somebody reads a week later.
        //
        // A retry after a failed send mints a new one and revokes the last,
        // which is correct: the previous token was never delivered.
        final bookingId = payload['bookingId'];
        final channel = payload['channel'];
        final sentTo = payload['sentTo'];
        if (bookingId is! String || channel is! String || sentTo is! String) {
          return null;
        }

        // The road as this booking bought it (ADR-0025): a passenger who
        // bought Dolisie→Pointe-Noire is told Dolisie, at the hour the coach
        // reaches Dolisie, and sent to the yard at Dolisie — not the terminus
        // the coach happens to run to and the gate in Brazzaville it left
        // from. The same numbering every other reader uses.
        final rows = await tx.execute(
          Sql.named('''
            WITH road AS (
              SELECT 0 AS position, r.origin_city AS city,
                     d.origin_station_id AS station_id, 0 AS offset_minutes
                FROM bookings b
                JOIN departures d ON d.id = b.departure_id
                JOIN routes r ON r.id = d.route_id
               WHERE b.id = @id
               UNION ALL
              SELECT rs.sequence, rs.city_code, rs.station_id,
                     rs.offset_minutes
                FROM bookings b
                JOIN departures d ON d.id = b.departure_id
                JOIN route_stops rs ON rs.route_id = d.route_id
               WHERE b.id = @id
               UNION ALL
              SELECT 1 + (SELECT count(*)::int FROM route_stops x
                           WHERE x.route_id = d.route_id),
                     r.destination_city, d.destination_station_id,
                     (EXTRACT(EPOCH FROM (d.arrives_at - d.departs_at)) / 60)::int
                FROM bookings b
                JOIN departures d ON d.id = b.departure_id
                JOIN routes r ON r.id = d.route_id
               WHERE b.id = @id
            )
            SELECT b.ref, u.language,
                   COALESCE(bp.city, r.origin_city) AS origin_city,
                   COALESCE(ap.city, r.destination_city) AS destination_city,
                   COALESCE(o.trading_name, o.legal_name) AS operator_name,
                   os.name AS station_name,
                   os.boarding_notes AS station_notes,
                   to_char((d.departs_at
                            + make_interval(mins => COALESCE(bp.offset_minutes, 0)))
                           AT TIME ZONE @tz, 'DD/MM')
                     AS departs_date,
                   to_char((d.departs_at
                            + make_interval(mins => COALESCE(bp.offset_minutes, 0)))
                           AT TIME ZONE @tz, 'HH24"h"MI')
                     AS departs_time,
                   (SELECT string_agg(bs.seat_label, ', '
                                      ORDER BY bs.seat_label)
                      FROM booking_seats bs WHERE bs.booking_id = b.id)
                     AS seats
              FROM bookings b
              JOIN departures d ON d.id = b.departure_id
              JOIN routes r ON r.id = d.route_id
              JOIN operators o ON o.id = b.operator_id
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
              LEFT JOIN road bp ON bp.position = lower(b.road_span)
              LEFT JOIN road ap ON ap.position = upper(b.road_span)
              LEFT JOIN stations os ON os.id = bp.station_id
             WHERE b.id = @id AND b.state = 'confirmed'
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, bookingId),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        // Cancelled between the vendor asking and the drain running. Nothing
        // to send, and nothing wrong: marked delivered so it stops retrying.
        if (rows.isEmpty) return null;
        final l = rows.first.toColumnMap();

        final minted = await _links.mintInto(
          tx,
          bookingId: bookingId,
          channel: channel,
          sentTo: sentTo,
          byUserId: payload['byUserId'] as String?,
        );
        if (minted == null) return null;

        final language = l['language'] as String? ?? 'fr';
        final tr = CatalogTranslator(_catalog, language);
        final url = _links.urlFor(minted.token).toString();
        final reference = 'BEL-${l['ref']}';
        final linkParams = <String, Object?>{
          'route': '${l['origin_city']}–${l['destination_city']}',
          'date': l['departs_date'],
          'time': l['departs_time'],
          'seat': l['seats'] ?? '',
          'reference': reference,
          'url': url,
        };

        final text = channel == 'phone'
            ? tr('sms.ticketLink.body', linkParams)
            : tr('email.ticketLink.body', linkParams);

        // An SMS is 160 characters and a link. It cannot carry a code, which
        // is the whole reason the link exists.
        if (channel == 'phone') {
          return OutboundMessage(
            channel: SignInChannel.phone,
            to: sentTo,
            body: text,
            // No dedupe key: every press of "send it again" is a customer
            // saying they did not get the last one, and the outbox row
            // already carries its own uniqueness.
          );
        }

        // The codes themselves, one file per live seat. A voided ticket is
        // not attached at all: an image in somebody's inbox that boards
        // nothing is worse than no image, because they only find out at the
        // door.
        final tickets = await tx.execute(
          Sql.named('''
            SELECT t.seat_label, t.payload,
                   COALESCE(bs.passenger_name, '') AS passenger_name
              FROM tickets t
              LEFT JOIN booking_seats bs
                     ON bs.booking_id = t.booking_id
                    AND bs.seat_label = t.seat_label
             WHERE t.booking_id = @id AND t.voided_at IS NULL
             ORDER BY t.seat_label
          '''),
          parameters: {'id': TypedValue(Type.uuid, bookingId)},
        );

        final seats = [
          for (final row in tickets)
            (
              label: row.toColumnMap()['seat_label']! as String,
              name: row.toColumnMap()['passenger_name']! as String,
              payload: row.toColumnMap()['payload']! as String,
            ),
        ];

        return OutboundMessage(
          channel: SignInChannel.email,
          to: sentTo,
          subject: tr('email.ticketLink.subject', linkParams),
          body: text,
          html: TicketEmail.render(
            originCity: l['origin_city']! as String,
            destinationCity: l['destination_city']! as String,
            operatorName: l['operator_name']! as String,
            date: l['departs_date']! as String,
            time: l['departs_time']! as String,
            reference: reference,
            stationName: l['station_name'] as String?,
            stationNotes: l['station_notes'] as String?,
            seats: [
              for (final seat in seats)
                EmailedSeat(seatLabel: seat.label, passengerName: seat.name),
            ],
            url: url,
            catalog: _catalog,
            language: language,
          ),
          attachments: [
            for (final seat in seats)
              OutboundAttachment(
                // Named so the recipient can tell three codes apart without
                // opening all three.
                name: '$reference-${seat.label}.png',
                contentType: 'image/png',
                bytes: QrPng.render(seat.payload),
              ),
          ],
        );

      case 'disruption.declared':
        final bookingId = payload['bookingId'];
        final disruptionId = payload['disruptionId'];
        if (bookingId is! String || disruptionId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT u.phone_e164, u.email, u.language,
                   r.origin_city, r.destination_city,
                   o.trading_name, o.legal_name,
                   x.kind::text AS kind, x.note, x.location,
                   x.marks_involuntary,
                   to_char(d.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS departs_time,
                   to_char(COALESCE(x.revised_departs_at, d.departs_at)
                             AT TIME ZONE @tz, 'HH24"h"MI') AS revised_time
              FROM bookings b
              JOIN departures d ON d.id = b.departure_id
              JOIN routes r ON r.id = d.route_id
              JOIN operators o ON o.id = b.operator_id
              JOIN disruptions x ON x.id = @disruption
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
             WHERE b.id = @booking
          '''),
          parameters: {
            'booking': TypedValue(Type.uuid, bookingId),
            'disruption': TypedValue(Type.uuid, disruptionId),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        if (rows.isEmpty) return null;
        final b = rows.first.toColumnMap();

        final phone = b['phone_e164'] as String?;
        final email = b['email'] as String?;
        final to = phone ?? email;
        // A counter sale to somebody who left no address. Nothing to send is
        // not a failure — but it is the case that makes the *manifest* the
        // conductor's fallback rather than an optimisation.
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, b['language'] as String? ?? 'fr');
        final involuntary = b['marks_involuntary'] as bool? ?? false;
        final kind = _kindName(b['kind'] as String);

        // The kind's own sentence, rendered first and passed into the
        // template as one argument. Nesting rather than six templates: the
        // envelope — who, which route, whether it costs anything — is the
        // same whatever happened to the coach.
        final summary = t('disruption.summary.$kind', {
          'time': b['revised_time'],
        });
        final note = b['note'] as String?;
        final place = b['location'] as String?;

        final body = t(
          involuntary
              ? 'sms.disruptionDeclared.involuntary'
              : 'sms.disruptionDeclared.body',
          {
            'operator': b['trading_name'] ?? b['legal_name'] ?? '',
            'route': '${b['origin_city']}–${b['destination_city']}',
            'time': b['departs_time'],
            // The dispatcher's own words come after the templated sentence,
            // because "le pont est coupé à Loufoulakari" is the part no
            // catalog can hold and the part the passenger acts on.
            'summary': [
              summary,
              if (place != null) '($place)',
              if (note != null) note,
            ].join(' '),
          },
        );

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : summary,
          body: body,
          eventId: 'disruption.declared:$disruptionId:$bookingId',
        );

      case 'disruption.resolved':
        final bookingId = payload['bookingId'];
        final disruptionId = payload['disruptionId'];
        if (bookingId is! String || disruptionId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT u.phone_e164, u.email, u.language,
                   r.origin_city, r.destination_city,
                   o.trading_name, o.legal_name,
                   to_char(d.departs_at AT TIME ZONE @tz, 'DD/MM')
                     AS departs_date,
                   to_char(d.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS departs_time,
                   (SELECT string_agg(bs.seat_label, ', '
                                      ORDER BY bs.seat_label)
                      FROM booking_seats bs WHERE bs.booking_id = b.id) AS seats
              FROM bookings b
              JOIN departures d ON d.id = b.departure_id
              JOIN routes r ON r.id = d.route_id
              JOIN operators o ON o.id = b.operator_id
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
             WHERE b.id = @booking
          '''),
          parameters: {
            'booking': TypedValue(Type.uuid, bookingId),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        if (rows.isEmpty) return null;
        final b = rows.first.toColumnMap();

        final phone = b['phone_e164'] as String?;
        final email = b['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, b['language'] as String? ?? 'fr');

        // The seat is the whole point of this message. "Votre place est déjà
        // réservée, siège 14A" is what turns an anxious passenger standing at
        // a roadside into a calm one (§3.1) — a resolution that did not name
        // the seat would send them to the counter to ask for it.
        final body = t('sms.disruptionResolved.body', {
          'operator': b['trading_name'] ?? b['legal_name'] ?? '',
          'route': '${b['origin_city']}–${b['destination_city']}',
          'date': b['departs_date'],
          'time': b['departs_time'],
          'seat': b['seats'] ?? '',
        });

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : body,
          body: body,
          eventId: 'disruption.resolved:$disruptionId:$bookingId',
        );

      case 'booking.rebooked':
        final bookingId = payload['bookingId'];
        final fromDepartureId = payload['fromDepartureId'];
        if (bookingId is! String || fromDepartureId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT b.ref, u.phone_e164, u.email, u.language,
                   r.origin_city, r.destination_city,
                   o.trading_name, o.legal_name,
                   to_char(d.departs_at AT TIME ZONE @tz, 'DD/MM')
                     AS departs_date,
                   to_char(d.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS departs_time,
                   to_char(od.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS old_time,
                   (SELECT string_agg(bs.seat_label, ', '
                                      ORDER BY bs.seat_label)
                      FROM booking_seats bs WHERE bs.booking_id = b.id) AS seats
              FROM bookings b
              JOIN departures d ON d.id = b.departure_id
              JOIN departures od ON od.id = @from
              JOIN routes r ON r.id = d.route_id
              JOIN operators o ON o.id = b.operator_id
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
             WHERE b.id = @booking
          '''),
          parameters: {
            'booking': TypedValue(Type.uuid, bookingId),
            'from': TypedValue(Type.uuid, fromDepartureId),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        if (rows.isEmpty) return null;
        final b = rows.first.toColumnMap();

        final phone = b['phone_e164'] as String?;
        final email = b['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, b['language'] as String? ?? 'fr');

        // Both times, and that is the design. The passenger has 06h00 in
        // their head and on their ticket; a message naming only the new one
        // reads as a message about somebody else's trip.
        final body = t('sms.rebooked.body', {
          'operator': b['trading_name'] ?? b['legal_name'] ?? '',
          'route': '${b['origin_city']}–${b['destination_city']}',
          'oldTime': b['old_time'],
          'date': b['departs_date'],
          'time': b['departs_time'],
          'seat': b['seats'] ?? '',
          'reference': 'BEL-${b['ref']}',
        });

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : body,
          body: body,
          eventId: 'booking.rebooked:$fromDepartureId:$bookingId',
        );

      // A passenger whose coach failed is now on another **company's** coach
      // (`08-disruption.md` §2.2 option ③). The most alarming thing that can
      // happen to a ticket without warning is the name on it changing, so the
      // message leads with the new carrier and keeps the reference they
      // already have.
      case 'booking.protected':
        final bookingId = payload['bookingId'];
        final fromDepartureId = payload['fromDepartureId'];
        if (bookingId is! String || fromDepartureId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT b.ref, u.phone_e164, u.email, u.language,
                   r.origin_city, r.destination_city,
                   o.trading_name, o.legal_name,
                   to_char(d.departs_at AT TIME ZONE @tz, 'DD/MM')
                     AS departs_date,
                   to_char(d.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS departs_time,
                   to_char(od.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS old_time,
                   (SELECT string_agg(bs.seat_label, ', '
                                      ORDER BY bs.seat_label)
                      FROM booking_seats bs WHERE bs.booking_id = b.id) AS seats
              FROM bookings b
              JOIN departures d ON d.id = b.departure_id
              JOIN departures od ON od.id = @from
              JOIN routes r ON r.id = d.route_id
              JOIN operators o ON o.id = b.operator_id
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
             WHERE b.id = @booking
          '''),
          parameters: {
            'booking': TypedValue(Type.uuid, bookingId),
            'from': TypedValue(Type.uuid, fromDepartureId),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        if (rows.isEmpty) return null;
        final b = rows.first.toColumnMap();

        final phone = b['phone_e164'] as String?;
        final email = b['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, b['language'] as String? ?? 'fr');

        // `o.trading_name` is now the RECEIVING operator, because the booking
        // changed hands. That is the whole point of the message: the coach
        // they are looking for has a different name painted on it.
        final body = t('sms.protected.body', {
          'operator': b['trading_name'] ?? b['legal_name'] ?? '',
          'route': '${b['origin_city']}–${b['destination_city']}',
          'oldTime': b['old_time'],
          'date': b['departs_date'],
          'time': b['departs_time'],
          'seat': b['seats'] ?? '',
          'reference': 'BEL-${b['ref']}',
        });

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : body,
          body: body,
          eventId: 'booking.protected:$fromDepartureId:$bookingId',
        );

      // The passenger chose their money back (`08-disruption.md` §3.2). It is
      // collected in cash at an agency, so the code that collects it has to
      // outlive the app being closed — which is why it goes by SMS as well as
      // onto the screen that issued it.
      case 'booking.refunded':
        final bookingId = payload['bookingId'];
        if (bookingId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT b.ref, u.phone_e164, u.email, u.language,
                   o.trading_name, o.legal_name,
                   f.amount_minor, f.currency, f.claim_code
              FROM refunds f
              JOIN bookings b ON b.id = f.booking_id
              JOIN operators o ON o.id = f.operator_id
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
             WHERE f.booking_id = @booking AND f.claim_code IS NOT NULL
             ORDER BY f.created_at DESC
             LIMIT 1
          '''),
          parameters: {'booking': TypedValue(Type.uuid, bookingId)},
        );

        if (rows.isEmpty) return null;
        final b = rows.first.toColumnMap();

        final phone = b['phone_e164'] as String?;
        final email = b['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, b['language'] as String? ?? 'fr');
        final currency =
            Currency.byCode(b['currency'] as String) ?? Currency.xaf;
        final language = b['language'] as String? ?? 'fr';

        final body = t('sms.refundClaim.body', {
          'amount': Money(
            b['amount_minor'] as int,
            currency,
          ).format(locale: language),
          'operator': b['trading_name'] ?? b['legal_name'] ?? '',
          'code': b['claim_code'],
          'reference': 'BEL-${b['ref']}',
        });

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : body,
          body: body,
          eventId: 'booking.refunded:$bookingId',
        );

      // The traveller cancelled their own booking (§8.2). What the message
      // has to carry is what they do next, and that differs: a claim ends at
      // a counter with a code, a source refund ends with a wait. Sending the
      // wrong one of the two is worse than sending nothing.
      case 'booking.cancelled':
        final bookingId = payload['bookingId'];
        if (bookingId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT b.ref, u.phone_e164, u.email, u.language,
                   o.trading_name, o.legal_name,
                   f.amount_minor, f.currency, f.claim_code,
                   COALESCE(p.processing_hours, 72) AS processing_hours
              FROM refunds f
              JOIN bookings b ON b.id = f.booking_id
              JOIN operators o ON o.id = f.operator_id
              LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
              LEFT JOIN refund_policies p
                     ON p.id = b.refund_policy_id
                    AND p.version = b.refund_policy_version
             WHERE f.booking_id = @booking
             ORDER BY f.created_at DESC
             LIMIT 1
          '''),
          parameters: {'booking': TypedValue(Type.uuid, bookingId)},
        );

        if (rows.isEmpty) return null;
        final b = rows.first.toColumnMap();

        final phone = b['phone_e164'] as String?;
        final email = b['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final language = b['language'] as String? ?? 'fr';
        final t = CatalogTranslator(_catalog, language);
        final currency =
            Currency.byCode(b['currency'] as String) ?? Currency.xaf;
        final amount = Money(
          b['amount_minor'] as int,
          currency,
        ).format(locale: language);
        final claimCode = b['claim_code'] as String?;

        final body = claimCode == null
            ? t('sms.cancelledPending.body', {
                'amount': amount,
                'hours': '${b['processing_hours']}',
                'reference': 'BEL-${b['ref']}',
              })
            : t('sms.cancelledClaim.body', {
                'amount': amount,
                'operator': b['trading_name'] ?? b['legal_name'] ?? '',
                'code': claimCode,
                'reference': 'BEL-${b['ref']}',
              });

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : body,
          body: body,
          eventId: 'booking.cancelled:$bookingId',
        );

      case 'seat.available':
        final alertId = payload['alertId'];
        if (alertId is! String) return null;

        final rows = await tx.execute(
          Sql.named('''
            SELECT u.phone_e164, u.email, u.language,
                   a.seats_wanted,
                   r.origin_city, r.destination_city,
                   o.trading_name, o.legal_name,
                   to_char(d.departs_at AT TIME ZONE @tz, 'DD/MM')
                     AS departs_date,
                   to_char(d.departs_at AT TIME ZONE @tz, 'HH24"h"MI')
                     AS departs_time
              FROM seat_alerts a
              JOIN departures d ON d.id = a.departure_id
              JOIN routes r ON r.id = d.route_id
              JOIN operators o ON o.id = d.operator_id
              LEFT JOIN user_accounts u ON u.id = a.user_id
             WHERE a.id = @id
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, alertId),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        if (rows.isEmpty) return null;
        final a = rows.first.toColumnMap();

        final phone = a['phone_e164'] as String?;
        final email = a['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, a['language'] as String? ?? 'fr');
        final params = <String, Object?>{
          'route': '${a['origin_city']}–${a['destination_city']}',
          'date': a['departs_date'],
          'time': a['departs_time'],
          'operator': a['trading_name'] ?? a['legal_name'] ?? '',
          'seats': '${a['seats_wanted']}',
        };

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null
              ? null
              : t('email.seatAvailable.subject', params),
          // Says "went back on sale", never "reserved for you". Nothing is
          // held: everybody waiting got this at the same moment and the
          // first to pay gets the seat. A message that implied otherwise
          // would send somebody to a station for a coach that filled while
          // they read it.
          body: t('sms.seatAvailable.body', params),
          eventId: 'seat.available:$alertId',
        );

      case 'compliance.expiring':
        final operatorId = payload['operatorId'];
        final docType = payload['docType'];
        final stage = payload['stage'];
        if (operatorId is! String || docType is! String || stage is! String) {
          return null;
        }

        // The **owner**, not whoever uploaded the certificate. A licence that
        // lapses is a company problem, and the person who can renew it is the
        // one who signed the agreement — a reminder to a dispatcher is a
        // reminder nobody acts on. Earliest accepted owner, so a company with
        // two gets one message rather than none.
        final rows = await tx.execute(
          Sql.named('''
            SELECT u.phone_e164, u.email, u.language,
                   o.trading_name, o.legal_name,
                   to_char(k.expires_at AT TIME ZONE @tz, 'DD/MM/YYYY')
                     AS expires_on
              FROM operators o
              JOIN operator_staff s ON s.operator_id = o.id
                                   AND s.revoked_at IS NULL
                                   AND 'org_owner' = ANY (s.roles)
              JOIN user_accounts u ON u.id = s.user_id
              LEFT JOIN LATERAL (
                SELECT expires_at FROM kyb_documents
                 WHERE operator_id = o.id AND doc_type = @doc
                   AND expires_at IS NOT NULL
                   AND verified_at IS NOT NULL
                   AND rejected_reason IS NULL
                 ORDER BY expires_at DESC LIMIT 1
              ) k ON TRUE
             WHERE o.id = @id
             ORDER BY s.invited_at
             LIMIT 1
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, operatorId),
            'doc': TypedValue(Type.text, docType),
            'tz': TypedValue(Type.text, timeZone),
          },
        );

        if (rows.isEmpty) return null;
        final c = rows.first.toColumnMap();

        final phone = c['phone_e164'] as String?;
        final email = c['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, c['language'] as String? ?? 'fr');
        final params = <String, Object?>{
          'operator': c['trading_name'] ?? c['legal_name'] ?? '',
          // A key, not the raw column: `transport_licence` is a database
          // value and "licence de transport" is a sentence (ADR-0008).
          'document': t.enumLabel('DocumentType', docType),
          'date': c['expires_on'] ?? '',
          'days': '${payload['daysLeft'] ?? 0}',
        };

        // The stage chooses the sentence, and the sentences differ in kind
        // rather than in tone: a reminder asks, a block reports that sales
        // have stopped, a suspension reports that the account has.
        final key = switch (stage) {
          'blocked' => 'complianceBlocked',
          'suspended' => 'complianceSuspended',
          _ => 'complianceExpiring',
        };

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null ? null : t('email.$key.subject', params),
          body: t('sms.$key.body', params),
          eventId: 'compliance:$operatorId:$docType:$stage',
        );

      case 'payout.released':
        // `04-payments.md` §6.2 asks for the statement to be downloadable
        // *and* sent. The download has existed since the payout desk shipped;
        // this is the other half, and it waited on an email adapter that
        // could carry a file — which ADR-0026 built for a boarding pass.
        //
        // **The document travels, not a link.** An operator who has to sign
        // in to read what they were paid phones us instead, which is the call
        // the statement exists to prevent — and their accountant, who files
        // it, holds no login at all.
        final runId = payload['runId'];
        if (runId is! String) return null;

        // The same reader the console and the API use. A second hydration
        // here would be a second definition of what a payout run is, and the
        // one that drifts is the one on the document somebody files.
        final run = await PostgresPayouts.readRun(tx, runId);
        if (run == null) return null;

        // The **owner**, like every other message about the company rather
        // than about a journey. Earliest accepted owner, so a company with two
        // gets one statement rather than none.
        final rows = await tx.execute(
          Sql.named('''
            SELECT u.email, u.language, o.trading_name, o.legal_name
              FROM operators o
              JOIN operator_staff s ON s.operator_id = o.id
                                   AND s.revoked_at IS NULL
                                   AND 'org_owner' = ANY (s.roles)
              JOIN user_accounts u ON u.id = s.user_id
             WHERE o.id = @id
             ORDER BY s.invited_at
             LIMIT 1
          '''),
          parameters: {'id': TypedValue(Type.uuid, run.statement.operatorId)},
        );
        if (rows.isEmpty) return null;
        final o = rows.first.toColumnMap();

        // Email only, and no SMS fallback. A statement *is* the attachment —
        // a text message saying one exists, to somebody who then cannot read
        // it, is a second phone call rather than none. An owner with no email
        // still has the download in their console.
        final to = o['email'] as String?;
        if (to == null) return null;

        final language = o['language'] as String? ?? 'fr';
        final t = CatalogTranslator(_catalog, language);
        final operatorName =
            (o['trading_name'] ?? o['legal_name'] ?? '') as String;

        // The window is half-open, `[from, to)`, so the last day it covers is
        // the day before `to`. Printing `to` would put a date on the subject
        // line that the document itself does not claim.
        final lastDay = run.statement.to.subtract(const Duration(days: 1));
        final period = '${_day(run.statement.from)} – ${_day(lastDay)}';
        final params = <String, Object?>{
          'period': period,
          'amount': run.statement.net.format(locale: language),
          'reference': run.reference ?? '',
        };

        return OutboundMessage(
          channel: SignInChannel.email,
          to: to,
          subject: t('email.payoutStatement.subject', params),
          body: t('email.payoutStatement.body', params),
          attachments: [
            OutboundAttachment(
              // The same name the download carries. An operator who saved one
              // from the console and one from their inbox must not end up
              // with two files they have to open to tell apart.
              name: statementFilename(run, operatorName),
              contentType: 'application/pdf',
              bytes: StatementPdf.render(
                run: run,
                catalog: _catalog,
                operatorName: operatorName,
                language: language,
              ),
            ),
          ],
          eventId: 'payout:$runId',
        );

      case 'operator.approved':
        final operatorId = payload['operatorId'];
        if (operatorId is! String) return null;

        // The applicant, not the owner row: at the instant this is composed
        // they have just become the owner, and the person who filled in the
        // wizard is who is waiting to hear.
        final rows = await tx.execute(
          Sql.named('''
            SELECT u.phone_e164, u.email, u.language,
                   COALESCE(o.trading_name, o.legal_name) AS name
              FROM operator_applications a
              JOIN operators o ON o.id = a.operator_id
              JOIN user_accounts u ON u.id = a.applicant_user_id
             WHERE a.operator_id = @id
          '''),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
        );

        if (rows.isEmpty) return null;
        final o = rows.first.toColumnMap();

        final phone = o['phone_e164'] as String?;
        final email = o['email'] as String?;
        final to = phone ?? email;
        if (to == null) return null;

        final t = CatalogTranslator(_catalog, o['language'] as String? ?? 'fr');
        final params = <String, Object?>{'operator': o['name'] ?? ''};

        return OutboundMessage(
          channel: phone != null ? SignInChannel.phone : SignInChannel.email,
          to: to,
          subject: phone != null
              ? null
              : t('email.operatorApproved.subject', params),
          // Says what to do next, not that a state changed. "Votre dossier
          // est approuvé" leaves somebody wondering whether to wait for a
          // second message; the next step is a route and a departure.
          body: t('sms.operatorApproved.body', params),
          eventId: 'operator.approved:$operatorId',
        );

      default:
        // An event type nobody handles is marked delivered rather than
        // retried forever. It is a deploy-order artefact — a producer shipped
        // before its consumer — and a queue that jams on one is a queue that
        // stops delivering everything behind it.
        return null;
    }
  }

  static Map<String, Object?> _decode(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is String) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    }
    return const {};
  }

  /// `DD/MM/YYYY`, the way a date is written on a document in this market.
  ///
  /// Formatted here rather than by Postgres because the payout run is already
  /// hydrated by the time this needs it, and a second query for a date the
  /// object is holding would be a second query.
  static String _day(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';

  /// `breakdown_en_route` → `breakdownEnRoute`. The column is SQL's naming
  /// and the catalog key is the domain enum's, and this is the seam.
  static String _kindName(String column) {
    final parts = column.split('_');
    return [
      parts.first,
      for (final p in parts.skip(1))
        p.isEmpty ? p : p[0].toUpperCase() + p.substring(1),
    ].join();
  }
}
