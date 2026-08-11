import 'dart:convert';

import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
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
    this.maxAttempts = 6,
  }) : _db = db,
       _notifications = notifications,
       _catalog = catalog;

  final Database _db;
  final NotificationGateway _notifications;
  final TranslationCatalog _catalog;

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
