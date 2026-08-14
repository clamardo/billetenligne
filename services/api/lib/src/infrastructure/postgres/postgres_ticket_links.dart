import 'dart:convert';
import 'dart:math';

import 'package:bel_domain/bel_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' hide Result;

import '../../application/ports/ticket_links.dart';
import '../db/database.dart';

/// The ticket you can always get to, against Postgres (ADR-0026).
///
/// Two things are deliberately absent.
///
/// **There is no query here that assembles the holder's page.**
/// `ticket_by_link()` does that, in SQL, under a SECURITY DEFINER, and the
/// columns it returns are the list of things a link may show. A handler that
/// built the payload from a join would be a handler somebody adds a phone
/// number to one afternoon.
///
/// **There is no plaintext token in a queue row.** The console asks for a
/// send; the drain mints. So the token exists in the message that carries it
/// and in a SHA-256 hash, and nowhere a week later.
final class PostgresTicketLinks implements TicketLinks {
  PostgresTicketLinks(this._db, {Uri? linkBase, Random? random})
    : _linkBase = linkBase ?? Uri.parse('https://blt.cg'),
      _random = random ?? Random.secure();

  final Database _db;

  /// Where the link points. Configured rather than compiled in: the short
  /// domain is bought by somebody in a browser, and pointing at it must not
  /// need a release.
  final Uri _linkBase;

  final Random _random;

  @override
  Future<Result<QueuedTicketLink, LinkRefusal>> queueSend({
    required String operatorId,
    required String bookingRef,
    required String channel,
    required String? sendTo,
    required String? byUserId,
    required DateTime now,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.id, b.state::text AS state, u.email, u.phone_e164
          FROM bookings b
          LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
         WHERE b.ref = @ref AND b.operator_id = @operator
      '''),
      parameters: {
        'ref': TypedValue(Type.text, bookingRef),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    // Another operator's booking is not found rather than refused: the tenant
    // policy already made it invisible, and saying "not yours" would confirm
    // the reference exists.
    if (rows.isEmpty) return const Err(UnknownBooking());
    final booking = rows.first.toColumnMap();

    // A reservation nobody has paid for has no ticket. A link to one would
    // open a page with no QR on it, which reads as our failure.
    if (booking['state'] != 'confirmed') return const Err(NothingToSend());

    // The address the vendor typed, or the one the account already carries —
    // which for a counter sale is the number the vendor typed at the till.
    final to = (sendTo?.trim().isNotEmpty ?? false)
        ? sendTo!.trim()
        : (channel == 'email'
              ? booking['email'] as String?
              : booking['phone_e164'] as String?);
    if (to == null || to.isEmpty) return const Err(NoDestination());

    // A fresh dedupe key per request, because re-sending is the whole point
    // of the button: "je ne l'ai pas reçu" is the commonest thing a customer
    // says, and a second press that silently did nothing would be worse than
    // no button.
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        VALUES ('booking', @booking, 'ticket.link', @payload,
                'ticket.link:' || @booking || ':' || gen_random_uuid()::text)
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, booking['id']),
        'payload': TypedValue(Type.jsonb, {
          'bookingId': booking['id'].toString(),
          'channel': channel,
          'sentTo': to,
          if (byUserId != null) 'byUserId': byUserId,
        }),
      },
      ignoreRows: true,
    );

    return Ok(QueuedTicketLink(channel: channel, sentTo: to));
  });

  @override
  Future<LinkedTicket?> open({required String token, required DateTime now}) =>
      _db.transaction(const DbScope.anonymous(), (tx) async {
        final rows = await tx.execute(
          Sql.named('SELECT * FROM ticket_by_link(@hash)'),
          parameters: {'hash': TypedValue(Type.text, hashOf(token))},
        );
        if (rows.isEmpty) return null;

        final head = rows.first.toColumnMap();

        // Revoked, expired and never-issued are one answer. See the port.
        if (head['revoked'] == true) return null;
        final expiresAt = head['expires_at']! as DateTime;
        if (!expiresAt.isAfter(now)) return null;

        return LinkedTicket(
          bookingRef: head['booking_ref']! as String,
          state: head['booking_state']! as String,
          operatorName: head['operator_name']! as String,
          operatorCode: head['operator_code']! as String,
          operatorAccentHue: head['operator_accent'] as String?,
          routeCode: head['route_code']! as String,
          originCity: head['origin_city']! as String,
          destinationCity: head['destination_city']! as String,
          departsAt: head['departs_at']! as DateTime,
          arrivesAt: head['arrives_at']! as DateTime,
          status: head['status']! as String,
          stationName: head['station_name'] as String?,
          stationNotes: head['station_notes'] as String?,
          channel: head['channel']! as String,
          expiresAt: expiresAt,
          seats: [
            for (final row in rows)
              if (row.toColumnMap()['payload'] != null)
                LinkedSeat(
                  seatLabel: row.toColumnMap()['seat_label']! as String,
                  passengerName:
                      row.toColumnMap()['passenger_name'] as String? ?? '',
                  payload: row.toColumnMap()['payload']! as String,
                  voided: row.toColumnMap()['voided'] == true,
                ),
          ],
        );
      });

  @override
  Future<LinkDestination?> destinationFor(String token) =>
      _db.transaction(const DbScope.anonymous(), (tx) async {
        final rows = await tx.execute(
          Sql.named('SELECT * FROM ticket_link_destination(@hash)'),
          parameters: {'hash': TypedValue(Type.text, hashOf(token))},
        );
        if (rows.isEmpty) return null;

        final row = rows.first.toColumnMap();
        return LinkDestination(
          bookingId: row['booking_id'].toString(),
          channel: row['channel']! as String,
          sentTo: row['sent_to']! as String,
        );
      });

  @override
  Future<String?> claim({required String token, required String userId}) =>
      _db.transaction(DbScope.traveller(userId), (tx) async {
        final rows = await tx.execute(
          Sql.named('SELECT claim_by_link(@hash, @user) AS ref'),
          parameters: {
            'hash': TypedValue(Type.text, hashOf(token)),
            'user': TypedValue(Type.uuid, userId),
          },
        );
        return rows.first.toColumnMap()['ref'] as String?;
      });

  @override
  Future<Result<void, LinkRefusal>> revoke({
    required String operatorId,
    required String bookingRef,
    required DateTime now,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    await tx.execute(
      Sql.named('''
        UPDATE ticket_links l
           SET revoked_at = @now
          FROM bookings b
         WHERE b.id = l.booking_id
           AND b.ref = @ref
           AND l.operator_id = @operator
           AND l.revoked_at IS NULL
      '''),
      parameters: {
        'ref': TypedValue(Type.text, bookingRef),
        'operator': TypedValue(Type.uuid, operatorId),
        'now': TypedValue(Type.timestampTz, now),
      },
      ignoreRows: true,
    );

    // Revoking twice is not an error: a vendor pressing it again on a bad
    // connection means the same thing both times, and an error there would
    // read as "it did not work".
    return const Ok(null);
  });

  /// Mints a link for a booking, inside somebody else's transaction.
  ///
  /// Called by the drain, which is the only place a token is ever created:
  /// the plaintext comes back here, goes into one message, and is stored
  /// only as a hash. Any live link on the same channel is revoked first —
  /// re-sending replaces rather than accumulates, because two live links are
  /// two things to revoke and the customer was told about one.
  ///
  /// The link outlives the coach by a day. A share dies six hours after
  /// arrival because watching a finished journey is pointless; a boarding
  /// pass has to survive a coach that left four hours late and a passenger
  /// who is arguing about it the next morning.
  Future<({String token, DateTime expiresAt})?> mintInto(
    TxSession tx, {
    required String bookingId,
    required String channel,
    required String sentTo,
    String? byUserId,
  }) async {
    final token = newToken();

    await tx.execute(
      Sql.named('''
        UPDATE ticket_links
           SET revoked_at = now()
         WHERE booking_id = @booking AND channel = @channel
           AND revoked_at IS NULL
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'channel': TypedValue(Type.text, channel),
      },
      ignoreRows: true,
    );

    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO ticket_links
          (booking_id, operator_id, token_hash, channel, sent_to, created_by,
           expires_at)
        SELECT b.id, b.operator_id, @hash, @channel, @to, @by,
               d.arrives_at + INTERVAL '24 hours'
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
         WHERE b.id = @booking
        RETURNING expires_at
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'hash': TypedValue(Type.text, hashOf(token)),
        'channel': TypedValue(Type.text, channel),
        'to': TypedValue(Type.text, sentTo),
        'by': TypedValue(Type.uuid, byUserId),
      },
    );

    if (rows.isEmpty) return null;
    return (
      token: token,
      expiresAt: rows.first.toColumnMap()['expires_at']! as DateTime,
    );
  }

  /// A link URL, from the token.
  Uri urlFor(String token) =>
      _linkBase.replace(path: '${_linkBase.path}/b/$token');

  /// 160 bits, base64url, no padding — the same shape a trip share uses, and
  /// for the same reason: this is pasted, never typed, so the only property
  /// that matters is that nobody walks it.
  String newToken() {
    final bytes = List<int>.generate(20, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// SHA-256, like a sign-in code and a trip share. No salt and no work
  /// factor: a 160-bit random token is not brute-forceable, and a slow hash on
  /// a page load would be a cost with no benefit.
  static String hashOf(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}
