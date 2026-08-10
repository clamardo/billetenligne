import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/storefronts.dart';
import '../db/database.dart';

/// The vitrine, on two surfaces.
///
/// The editor's reads and writes run under `DbScope.tenant`; the storefront
/// runs under `DbScope.anonymous`, where migration 0005's policy already says
/// what this port promises — `app_is_public() AND status = 'active'`. So a
/// suspended operator's page stops resolving because the *database* stops
/// returning the row, not because a Dart branch remembered to check. That is
/// the boundary being tested in `verify_public.sql`, and it is why there is
/// no status clause in the SQL below.
final class PostgresStorefronts implements Storefronts {
  const PostgresStorefronts(this._db);

  final Database _db;

  static const _columns = '''
    o.id, o.code, o.legal_name, o.trading_name,
    o.accent_hue, o.header_pattern,
    o.title_fr, o.title_en, o.tagline_fr, o.tagline_en,
    o.logo_asset, o.cover_asset
  ''';

  @override
  Future<VitrineDto?> forOperator(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('SELECT $_columns FROM operators o WHERE o.id = @id'),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
        );
        return rows.isEmpty ? null : _vitrine(rows.first.toColumnMap());
      });

  @override
  Future<VitrineDto?> save({
    required String operatorId,
    required SaveVitrineRequest edit,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        UPDATE operators o
           SET accent_hue = @accent,
               header_pattern = @pattern,
               title_fr = @titleFr,
               title_en = @titleEn,
               tagline_fr = @taglineFr,
               tagline_en = @taglineEn
         WHERE o.id = @id
        RETURNING $_columns
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, operatorId),
        'accent': edit.accentHue,
        'pattern': edit.headerPattern,
        // Blank is null, not an empty string. A tagline typed and then
        // cleared has to fall back to the other language the same way one
        // never written does — otherwise clearing a field is a way to get a
        // header that renders as nothing.
        'titleFr': _orNull(edit.titleFr),
        'titleEn': _orNull(edit.titleEn),
        'taglineFr': _orNull(edit.taglineFr),
        'taglineEn': _orNull(edit.taglineEn),
      },
    );
    return rows.isEmpty ? null : _vitrine(rows.first.toColumnMap());
  });

  @override
  Future<void> setAsset({
    required String operatorId,
    required BrandAssetKind kind,
    required String? key,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // The column is chosen from a Dart enum, never from anything on the wire.
    // A caller-supplied column name here is the shape of an injection, and
    // this is a `SET` clause where it would be one.
    final column = switch (kind) {
      BrandAssetKind.logo => 'logo_asset',
      BrandAssetKind.cover => 'cover_asset',
    };

    await tx.execute(
      Sql.named('UPDATE operators SET $column = @key WHERE id = @id'),
      parameters: {
        'id': TypedValue(Type.uuid, operatorId),
        'key': TypedValue(Type.text, key),
      },
    );
  });

  @override
  Future<StorefrontDto?> byCode(String code) =>
      _db.transaction(const DbScope.anonymous(), (tx) async {
        final rows = await tx.execute(
          Sql.named(
            'SELECT $_columns FROM operators o WHERE lower(o.code) = @code',
          ),
          parameters: {'code': code.trim().toLowerCase()},
        );
        if (rows.isEmpty) return null;

        final row = rows.first.toColumnMap();
        final operatorId = row['id'].toString();

        // Only lines with a departure still to come, cheapest fare first.
        // A storefront listing a route nobody runs any more is a page that
        // sends somebody to an empty search result, which reads as our bug
        // rather than as a route that closed.
        final routes = await tx.execute(
          Sql.named('''
            SELECT r.code,
                   co.name_fr AS origin_fr, co.name_en AS origin_en,
                   cd.name_fr AS dest_fr,   cd.name_en AS dest_en,
                   min(d.fare_minor)::bigint AS from_fare,
                   min(d.currency) AS currency,
                   min(d.departs_at) AS next_departure
              FROM routes r
              JOIN cities co ON co.code = r.origin_city
              JOIN cities cd ON cd.code = r.destination_city
              JOIN departures d ON d.route_id = r.id
                                AND d.status <> 'cancelled'
                                AND d.departs_at > now()
             WHERE r.operator_id = @operator
             GROUP BY r.code, co.name_fr, co.name_en, cd.name_fr, cd.name_en
             ORDER BY min(d.departs_at)
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );

        return StorefrontDto(
          vitrine: _vitrine(row),
          routes: [
            for (final r in routes)
              _route(r.toColumnMap()),
          ],
        );
      });

  static String? _orNull(String? raw) {
    final trimmed = raw?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  static VitrineDto _vitrine(Map<String, dynamic> row) => VitrineDto(
    operatorId: row['id'].toString(),
    code: row['code'] as String,
    legalName: row['legal_name'] as String,
    tradingName: row['trading_name'] as String?,
    accentHue: row['accent_hue'] as String,
    headerPattern: row['header_pattern'] as String,
    titleFr: row['title_fr'] as String?,
    titleEn: row['title_en'] as String?,
    taglineFr: row['tagline_fr'] as String?,
    taglineEn: row['tagline_en'] as String?,
    logoAsset: row['logo_asset'] as String?,
    coverAsset: row['cover_asset'] as String?,
  );

  /// French names, because the route list on a storefront is rendered by the
  /// server rather than by a catalog key — a city name is data, not a
  /// translated string, and both columns exist for exactly this.
  static StorefrontRouteDto _route(Map<String, dynamic> row) =>
      StorefrontRouteDto(
        code: row['code'] as String,
        originCity: row['origin_fr'] as String,
        destinationCity: row['dest_fr'] as String,
        fromFare: Money(
          row['from_fare'] as int,
          // `CHAR(3)` pads. Trimming it is why every other adapter does the
          // same, and forgetting to is a currency that matches nothing.
          Currency.byCode((row['currency'] as String).trim()) ?? Currency.xaf,
        ),
        nextDepartureAt: row['next_departure'] as DateTime?,
      );
}
