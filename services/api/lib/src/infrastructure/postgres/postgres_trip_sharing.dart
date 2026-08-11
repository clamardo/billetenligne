import 'dart:convert';
import 'dart:math';

import 'package:bel_domain/bel_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' hide Result;

import '../../application/ports/trip_sharing.dart';
import '../db/database.dart';

/// Sharing a trip, against Postgres (ADR-0014 §2).
///
/// The interesting part is what is *not* here. There is no query that
/// assembles a follower's page: `followed_trip()` does that, in SQL, under a
/// SECURITY DEFINER, and the list of columns it returns is the list of things
/// a follower may know. A handler that built the payload from a join would be
/// a handler somebody adds a seat label to one afternoon.
final class PostgresTripSharing implements TripSharing {
  PostgresTripSharing(this._db, {Uri? shareBase, Random? random})
    : _shareBase = shareBase ?? Uri.parse('https://blt.cg'),
      _random = random ?? Random.secure();

  final Database _db;

  /// Where the link points. Configured rather than compiled in, because the
  /// short domain ADR-0014 asks for is bought by somebody in a browser and
  /// pointing at it must not need a release.
  final Uri _shareBase;

  final Random _random;

  @override
  Future<Result<TripShare, ShareRefusal>> share({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final booking = await _booking(tx, bookingRef);
    if (booking == null) return const Err(UnknownShare());

    // A reservation somebody may never pay for is not a trip. A link that
    // resolved to one would quietly stop working when the hold lapsed, which
    // reads to whoever holds it as our bug.
    if (booking['state'] != 'confirmed') return const Err(NothingToShare());

    final live = await _live(tx, booking['id']! as String);
    if (live != null) {
      // The same link, without the token. Minting a second one would leave a
      // live link the traveller cannot see in order to revoke it.
      return Ok(_shareOf(live));
    }

    final token = _newToken();
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO trip_shares
          (booking_id, departure_id, operator_id, token_hash, expires_at)
        VALUES (@booking, @departure, @operator, @hash, @expires)
        RETURNING expires_at, opens, revoked_at
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, booking['id']),
        'departure': TypedValue(Type.uuid, booking['departure_id']),
        'operator': TypedValue(Type.uuid, booking['operator_id']),
        'hash': TypedValue(Type.text, _hash(token)),
        'expires': TypedValue(
          Type.timestampTz,
          shareExpiry(booking['arrives_at']! as DateTime),
        ),
      },
    );

    final row = rows.first.toColumnMap();
    return Ok(
      TripShare(
        token: token,
        expiresAt: row['expires_at']! as DateTime,
        opens: row['opens']! as int,
        revoked: false,
      ),
    );
  });

  @override
  Future<TripShare?> shareFor({
    required String bookingRef,
    required String userId,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final booking = await _booking(tx, bookingRef);
    if (booking == null) return null;

    final live = await _live(tx, booking['id']! as String);
    return live == null ? null : _shareOf(live);
  });

  @override
  Future<Result<void, ShareRefusal>> revoke({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final booking = await _booking(tx, bookingRef);
    if (booking == null) return const Err(UnknownShare());

    // Revoking twice is not an error: the traveller pressing it again on a
    // bad connection means the same thing both times, and an error there
    // would read as "it did not work".
    await tx.execute(
      Sql.named('''
        UPDATE trip_shares
           SET revoked_at = @now
         WHERE booking_id = @booking AND revoked_at IS NULL
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, booking['id']),
        'now': TypedValue(Type.timestampTz, now),
      },
    );

    return const Ok(null);
  });

  @override
  Future<FollowedTrip?> follow({
    required String token,
    required DateTime now,
  }) => _db.transaction(const DbScope.anonymous(), (tx) async {
    final rows = await tx.execute(
      Sql.named('SELECT * FROM followed_trip(@hash)'),
      parameters: {'hash': TypedValue(Type.text, _hash(token))},
    );
    if (rows.isEmpty) return null;

    final r = rows.first.toColumnMap();

    // Revoked and never-issued are the same answer. See the port.
    if (r['revoked'] == true) return null;

    final expiresAt = r['expires_at']! as DateTime;
    if (openable(now: now, expiresAt: expiresAt).failureOrNull != null) {
      return null;
    }

    final departsAt = r['departs_at']! as DateTime;
    final arrivesAt = r['arrives_at']! as DateTime;

    return FollowedTrip(
      operatorName: r['operator_name']! as String,
      routeCode: r['route_code']! as String,
      originCity: r['origin_city']! as String,
      destinationCity: r['destination_city']! as String,
      departsAt: departsAt,
      arrivesAt: arrivesAt,
      status: r['status']! as String,
      // Tier 3 only, today. GPS reporting and checkpoint taps are ADR-0014's
      // tiers 1 and 2 and neither is built — so what comes back is honestly
      // labelled an estimate rather than dressed as a position.
      progress: scheduledProgress(
        now: now,
        departsAt: (r['revised_departs_at'] as DateTime?) ?? departsAt,
        arrivesAt: arrivesAt,
      ),
      expiresAt: expiresAt,
      disruptionKind: r['disruption_kind'] as String?,
      disruptionCause: r['disruption_cause'] as String?,
      disruptionNote: r['disruption_note'] as String?,
      revisedDepartsAt: r['revised_departs_at'] as DateTime?,
    );
  });

  Future<Map<String, Object?>?> _booking(TxSession tx, String ref) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.id, b.departure_id, b.operator_id, b.state::text AS state,
               d.arrives_at
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
         WHERE b.ref = @ref
      '''),
      parameters: {'ref': TypedValue(Type.text, ref)},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  Future<Map<String, Object?>?> _live(TxSession tx, String bookingId) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT expires_at, opens, revoked_at
          FROM trip_shares
         WHERE booking_id = @booking AND revoked_at IS NULL
      '''),
      parameters: {'booking': TypedValue(Type.uuid, bookingId)},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  static TripShare _shareOf(Map<String, Object?> row) => TripShare(
    expiresAt: row['expires_at']! as DateTime,
    opens: row['opens']! as int,
    revoked: row['revoked_at'] != null,
  );

  /// A share URL, from the token.
  Uri urlFor(String token) =>
      _shareBase.replace(path: '${_shareBase.path}/t/$token');

  /// 160 bits, base64url, no padding.
  ///
  /// Longer than a payment code and deliberately unlike one: this is not read
  /// aloud or typed, it is pasted into WhatsApp, so the only property that
  /// matters is that it cannot be guessed. Twenty-seven characters of
  /// `Random.secure` is not something anybody walks.
  String _newToken() {
    final bytes = List<int>.generate(20, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// SHA-256, like a sign-in code. No salt and no work factor on purpose: a
  /// 160-bit random token is not brute-forceable and a slow hash on a page
  /// that polls every sixty seconds would be a cost with no benefit.
  static String _hash(String token) =>
      sha256.convert(utf8.encode(token)).toString();
}
