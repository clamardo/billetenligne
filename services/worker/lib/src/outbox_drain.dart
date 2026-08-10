import 'dart:convert';

import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_contracts/bel_contracts.dart';
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
