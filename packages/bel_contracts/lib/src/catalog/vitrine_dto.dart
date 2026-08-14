import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// The closed vocabularies a storefront is built from.
///
/// Here rather than in `bel_design`, because the **server** is what refuses a
/// ninth accent and the server cannot import a Flutter package. The design
/// system owns the colours; this owns the list, and a test in `bel_design`
/// asserts the two agree — which is the only way a hue can exist in one and
/// not the other for exactly one commit.
abstract final class Vitrine {
  /// Eight, each pre-verified against `contentPrimary`, `surfaceRaised` and
  /// plein soleil. A free colour picker guarantees that some operator
  /// eventually chooses a yellow that is invisible in direct sun — and it
  /// would be invisible on *our* ticket, at the moment a conductor needs to
  /// read it (`05-design-system.md` §10).
  static const accents = <String>[
    'foret',
    'laterite',
    'indigo',
    'brique',
    'prune',
    'ocean',
    'olive',
    'ardoise',
  ];

  /// Four generated vectors, about a kilobyte each. No photography: most
  /// operators have none usable, and 120 KB of cover image is a data cost
  /// imposed on the poorest user (ADR-0009).
  ///
  /// `kuba` — the interlocking chevrons of Kuba cloth — was drawn in the
  /// design system from the day the motifs were, and was in neither this list
  /// nor the header component's own copy of it. Two enums with the same three
  /// names, and the fourth in only one of them, so the one motif that is
  /// actually Congolese was reachable from nowhere in the product.
  static const patterns = <String>['flat', 'diagonale', 'vagues', 'kuba'];

  static bool isAccent(String? raw) => accents.contains(raw);
  static bool isPattern(String? raw) => patterns.contains(raw);
}

/// An operator's storefront, as they configure it and as a traveller sees it.
///
/// One DTO for both directions on purpose. The console's live preview renders
/// the same shape the public page does, drawn by the same widgets — and a
/// preview built from a second type is a preview that will eventually show
/// something the storefront does not (`03-operator-lifecycle.md` §2.4).
///
/// Bounded rather than free-form, and every bound is a real defence:
///
///   * the accent comes from a **closed set of eight**, each pre-verified for
///     contrast in direct sun. A free picker guarantees that some operator
///     eventually chooses a yellow that is invisible on our ticket, at the
///     moment a conductor needs to read it;
///   * the header pattern is one of three **generated vectors**, about a
///     kilobyte each, because this ships to every traveller's phone on a
///     metered bundle (ADR-0009);
///   * the title and tagline are **two languages each**, so the storefront
///     renders in the reader's own (ADR-0008).
final class VitrineDto {
  const VitrineDto({
    required this.operatorId,
    required this.code,
    required this.legalName,
    required this.accentHue,
    required this.headerPattern,
    this.tradingName,
    this.titleFr,
    this.titleEn,
    this.taglineFr,
    this.taglineEn,
    this.logoAsset,
    this.coverAsset,
    this.logoUrl,
    this.coverUrl,
  });

  final String operatorId;

  /// What `blt.cg/o/<code>` resolves on. The operator's own short code, which
  /// is already unique and already printed on their agency's poster.
  final String code;

  final String legalName;
  final String? tradingName;

  /// One of the eight. A string on the wire rather than an index, because an
  /// index is a number that silently means something else the day the list
  /// is reordered.
  final String accentHue;

  /// `flat` | `diagonale` | `vagues` | `kuba`.
  final String headerPattern;

  final String? titleFr;
  final String? titleEn;
  final String? taglineFr;
  final String? taglineEn;

  /// Storage keys, not URLs, and null until an operator uploads one. The
  /// generated monogram is the documented default, not a placeholder.
  final String? logoAsset;
  final String? coverAsset;

  /// Where to actually fetch them.
  ///
  /// Resolved by the server from the key, and **not** derivable by a client:
  /// the account, the container and whatever CDN sits in front of them all
  /// change without the file changing, and a client that built this URL would
  /// be a client that breaks on a storage migration. Null when there is no
  /// asset, and also when the deployment has no storage configured — which is
  /// why the monogram fallback is keyed off the URL rather than the key.
  final String? logoUrl;
  final String? coverUrl;

  /// What to show a reader of [language].
  ///
  /// Falls through to the other language before falling back to the trading
  /// name: a storefront with a French tagline and no English one should show
  /// the French to an English reader rather than nothing. Half a sentence in
  /// the wrong language beats an empty header.
  String titleFor(String language) =>
      _pick(language, titleFr, titleEn) ?? tradingName ?? legalName;

  String? taglineFor(String language) => _pick(language, taglineFr, taglineEn);

  static String? _pick(String language, String? fr, String? en) {
    final first = language.startsWith('en') ? en : fr;
    final second = language.startsWith('en') ? fr : en;
    if (first != null && first.trim().isNotEmpty) return first;
    if (second != null && second.trim().isNotEmpty) return second;
    return null;
  }

  /// The same vitrine with its asset URLs resolved.
  ///
  /// A method rather than a constructor argument threaded through every
  /// adapter, because *where a file can be fetched from* is a fact about the
  /// deployment and not about the row — the storage adapter knows it and the
  /// database does not.
  VitrineDto withAssetUrls({String? logoUrl, String? coverUrl}) => VitrineDto(
    operatorId: operatorId,
    code: code,
    legalName: legalName,
    tradingName: tradingName,
    accentHue: accentHue,
    headerPattern: headerPattern,
    titleFr: titleFr,
    titleEn: titleEn,
    taglineFr: taglineFr,
    taglineEn: taglineEn,
    logoAsset: logoAsset,
    coverAsset: coverAsset,
    logoUrl: logoUrl,
    coverUrl: coverUrl,
  );

  Map<String, Object?> toJson() => Wire.compact({
    'operatorId': operatorId,
    'code': code,
    'legalName': legalName,
    'tradingName': tradingName,
    'accentHue': accentHue,
    'headerPattern': headerPattern,
    'titleFr': titleFr,
    'titleEn': titleEn,
    'taglineFr': taglineFr,
    'taglineEn': taglineEn,
    'logoAsset': logoAsset,
    'coverAsset': coverAsset,
    'logoUrl': logoUrl,
    'coverUrl': coverUrl,
  });

  factory VitrineDto.fromJson(Map<String, Object?> json) => VitrineDto(
    operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
    code: Wire.requireString(json['code'], 'code'),
    legalName: Wire.requireString(json['legalName'], 'legalName'),
    tradingName: json['tradingName'] as String?,
    accentHue: Wire.requireString(json['accentHue'], 'accentHue'),
    headerPattern: Wire.requireString(json['headerPattern'], 'headerPattern'),
    titleFr: json['titleFr'] as String?,
    titleEn: json['titleEn'] as String?,
    taglineFr: json['taglineFr'] as String?,
    taglineEn: json['taglineEn'] as String?,
    logoAsset: json['logoAsset'] as String?,
    coverAsset: json['coverAsset'] as String?,
    logoUrl: json['logoUrl'] as String?,
    coverUrl: json['coverUrl'] as String?,
  );
}

/// What the vitrine editor sends. Only the fields an operator controls — the
/// legal name and the code are not theirs to change from this screen.
final class SaveVitrineRequest {
  const SaveVitrineRequest({
    required this.accentHue,
    required this.headerPattern,
    this.titleFr,
    this.titleEn,
    this.taglineFr,
    this.taglineEn,
  });

  final String accentHue;
  final String headerPattern;
  final String? titleFr;
  final String? titleEn;
  final String? taglineFr;
  final String? taglineEn;

  /// The lengths of `03-operator-lifecycle.md` §2.4: 30 for a title, 60 for a
  /// tagline. Long enough to say something, short enough not to wrap on a
  /// 320 dp screen — which is the screen this is read on.
  static const titleMax = 30;
  static const taglineMax = 60;

  Map<String, Object?> toJson() => Wire.compact({
    'accentHue': accentHue,
    'headerPattern': headerPattern,
    'titleFr': titleFr,
    'titleEn': titleEn,
    'taglineFr': taglineFr,
    'taglineEn': taglineEn,
  });

  factory SaveVitrineRequest.fromJson(Map<String, Object?> json) =>
      SaveVitrineRequest(
        accentHue: Wire.requireString(json['accentHue'], 'accentHue'),
        headerPattern: Wire.requireString(
          json['headerPattern'],
          'headerPattern',
        ),
        titleFr: json['titleFr'] as String?,
        titleEn: json['titleEn'] as String?,
        taglineFr: json['taglineFr'] as String?,
        taglineEn: json['taglineEn'] as String?,
      );
}

/// The public storefront: the vitrine plus what an operator actually runs.
///
/// A deep-linkable page (`blt.cg/o/ocean-du-nord`) and the natural landing
/// page for an operator's own WhatsApp and poster campaigns — which is why it
/// is anonymous, cacheable, and carries enough to book from rather than being
/// a brochure.
final class StorefrontDto {
  const StorefrontDto({
    required this.vitrine,
    this.routes = const [],
    this.onTimeRate,
  });

  final VitrineDto vitrine;
  final List<StorefrontRouteDto> routes;

  /// 0–100. Surfaced honestly, so reliability becomes a competitive
  /// advantage rather than a hidden cost.
  final int? onTimeRate;

  Map<String, Object?> toJson() => Wire.compact({
    'vitrine': vitrine.toJson(),
    'routes': [for (final r in routes) r.toJson()],
    'onTimeRate': onTimeRate,
  });

  factory StorefrontDto.fromJson(Map<String, Object?> json) => StorefrontDto(
    vitrine: VitrineDto.fromJson(Wire.requireMap(json['vitrine'], 'vitrine')),
    routes: Wire.readList(
      json['routes'],
      StorefrontRouteDto.fromJson,
      field: 'routes',
    ),
    onTimeRate: json['onTimeRate'] as int?,
  );
}

/// One line this operator runs, with the cheapest fare on it.
final class StorefrontRouteDto {
  const StorefrontRouteDto({
    required this.code,
    required this.originCity,
    required this.destinationCity,
    required this.fromFare,
    this.nextDepartureAt,
  });

  final String code;
  final String originCity;
  final String destinationCity;

  /// The cheapest published fare, so the page can say "à partir de" without a
  /// second request.
  final Money fromFare;

  final DateTime? nextDepartureAt;

  Map<String, Object?> toJson() => Wire.compact({
    'code': code,
    'originCity': originCity,
    'destinationCity': destinationCity,
    'fromFare': Wire.money(fromFare),
    'nextDepartureAt': nextDepartureAt == null
        ? null
        : Wire.instant(nextDepartureAt!),
  });

  factory StorefrontRouteDto.fromJson(Map<String, Object?> json) =>
      StorefrontRouteDto(
        code: Wire.requireString(json['code'], 'code'),
        originCity: Wire.requireString(json['originCity'], 'originCity'),
        destinationCity: Wire.requireString(
          json['destinationCity'],
          'destinationCity',
        ),
        fromFare: Wire.readMoney(json['fromFare'], field: 'fromFare'),
        nextDepartureAt: Wire.readInstantOrNull(
          json['nextDepartureAt'],
          field: 'nextDepartureAt',
        ),
      );
}
