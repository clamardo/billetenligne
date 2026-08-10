import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/storefronts.dart';

/// Storefronts held in memory, for tests and for the demo server.
///
/// Unlike the operator console, this one has a fake rather than a refusal. The
/// storefront is a *public* read, on the surface a fresh clone is supposed to
/// be able to browse — and unlike a coach or a timetable it is a handful of
/// strings, so a fake is not a second definition of anything the console owns.
/// It is seeded from the same operator the memory inventory sells, so the demo
/// search results and the demo storefront agree about who is running the coach.
final class MemoryStorefronts implements Storefronts {
  MemoryStorefronts({List<VitrineDto>? seed})
    : _byId = {for (final v in seed ?? const <VitrineDto>[]) v.operatorId: v};

  /// The operator the in-memory inventory sells for.
  factory MemoryStorefronts.demo({String operatorId = 'op-demo'}) =>
      MemoryStorefronts(
        seed: [
          VitrineDto(
            operatorId: operatorId,
            code: 'ODN',
            legalName: 'Ocean du Nord SARL',
            tradingName: 'Ocean du Nord',
            accentHue: 'foret',
            headerPattern: 'flat',
          ),
        ],
      );

  final Map<String, VitrineDto> _byId;

  @override
  Future<VitrineDto?> forOperator(String operatorId) async =>
      _byId[operatorId];

  @override
  Future<VitrineDto?> save({
    required String operatorId,
    required SaveVitrineRequest edit,
  }) async {
    final existing = _byId[operatorId];
    if (existing == null) return null;
    return _byId[operatorId] = VitrineDto(
      operatorId: existing.operatorId,
      code: existing.code,
      legalName: existing.legalName,
      tradingName: existing.tradingName,
      accentHue: edit.accentHue,
      headerPattern: edit.headerPattern,
      titleFr: _orNull(edit.titleFr),
      titleEn: _orNull(edit.titleEn),
      taglineFr: _orNull(edit.taglineFr),
      taglineEn: _orNull(edit.taglineEn),
      logoAsset: existing.logoAsset,
      coverAsset: existing.coverAsset,
    );
  }

  @override
  Future<void> setAsset({
    required String operatorId,
    required BrandAssetKind kind,
    required String? key,
  }) async {
    final existing = _byId[operatorId];
    if (existing == null) return;

    _byId[operatorId] = VitrineDto(
      operatorId: existing.operatorId,
      code: existing.code,
      legalName: existing.legalName,
      tradingName: existing.tradingName,
      accentHue: existing.accentHue,
      headerPattern: existing.headerPattern,
      titleFr: existing.titleFr,
      titleEn: existing.titleEn,
      taglineFr: existing.taglineFr,
      taglineEn: existing.taglineEn,
      logoAsset: kind == BrandAssetKind.logo ? key : existing.logoAsset,
      coverAsset: kind == BrandAssetKind.cover ? key : existing.coverAsset,
    );
  }

  @override
  Future<StorefrontDto?> byCode(String code) async {
    for (final vitrine in _byId.values) {
      if (vitrine.code.toLowerCase() == code.trim().toLowerCase()) {
        // No routes: the memory catalogue owns departures and this fake does
        // not reach into it. An empty list is honest — a demo storefront that
        // invented three lines would be the second definition this fake
        // exists to avoid.
        return StorefrontDto(vitrine: vitrine);
      }
    }
    return null;
  }

  static String? _orNull(String? raw) {
    final trimmed = raw?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
