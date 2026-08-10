import 'dart:io';

import 'package:bel_domain/bel_domain.dart';
import 'package:yaml/yaml.dart';

/// A `config/markets.yaml` that could not be read as markets.
///
/// Deliberately fatal rather than survivable — see [MarketCatalog.load] for
/// why a malformed file stops the process instead of quietly reverting to the
/// compiled-in one.
final class MarketConfigError implements Exception {
  const MarketConfigError(this.message);
  final String message;
  @override
  String toString() => 'MarketConfigError: $message';
}

/// The markets this deployment serves, read from `config/markets.yaml`.
///
/// This is the loader ADR-0006 has been asking for. Until it existed, the API
/// answered `/public/v1/market` from `Market.congoBrazzaville` compiled into
/// the binary, which meant enabling Orange Money — a rail that is *already*
/// written down, in the file, one `enabled:` away — needed a release. The
/// whole argument for keeping country facts as data is that they change on
/// somebody else's schedule: a carrier renumbers, a wallet finishes its
/// integration, a service fee moves. None of those are code changes.
///
/// The catalog is parsed once at startup and never re-read. A config push is
/// a restart, not a file watcher — a rail that changes mid-request would mean
/// a booking priced under one fee and paid under another.
final class MarketCatalog {
  const MarketCatalog({required this.markets, required this.defaultMarket});

  final List<Market> markets;

  /// What a request that names no country gets. There is one today; the field
  /// exists so that the day there are two, nothing has to guess.
  final Market defaultMarket;

  /// What runs when there is no file: a fresh clone, a unit test, CI.
  static const compiledIn = MarketCatalog(
    markets: [Market.congoBrazzaville],
    defaultMarket: Market.congoBrazzaville,
  );

  Market? byCode(String code) {
    for (final m in markets) {
      if (m.code == code.toUpperCase()) return m;
    }
    return null;
  }

  /// Reads the file at [path], or `BEL_MARKETS_FILE`, or `config/markets.yaml`
  /// found by walking up from the working directory.
  ///
  /// **A missing file falls back. A malformed one throws.** The asymmetry is
  /// the point. Absent is a normal state — every test run and every fresh
  /// clone — and the compiled-in market keeps the API answering. Present but
  /// wrong is somebody's deliberate push, and the failure mode we must not
  /// have is a deploy that reports success while silently serving the rails
  /// of the release before it. Better a process that refuses to start, loudly,
  /// while the old one is still up.
  static MarketCatalog load({String? path, Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final located = path ?? env['BEL_MARKETS_FILE'] ?? _find();
    if (located == null) return compiledIn;

    final file = File(located);
    if (!file.existsSync()) {
      // An explicitly named file that is not there is a mistake, not a
      // default — somebody set the variable and expected it to be read.
      if (path != null || env['BEL_MARKETS_FILE'] != null) {
        throw MarketConfigError('markets file not found: $located');
      }
      return compiledIn;
    }

    return parse(file.readAsStringSync(), source: located);
  }

  /// Walks up from the working directory, the same way the translation
  /// catalog is found. Ugly, and the alternative is every entry point knowing
  /// how deep in the tree it was launched from.
  static String? _find() {
    var dir = Directory.current;
    for (var up = 0; up < 5; up++) {
      final candidate = File('${dir.path}/config/markets.yaml');
      if (candidate.existsSync()) return candidate.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Parses the file's text. Separate from [load] so the whole of it is
  /// testable without a filesystem — and so a test can assert on the *real*
  /// `config/markets.yaml` rather than on a copy that drifts from it.
  static MarketCatalog parse(String yaml, {String source = 'markets.yaml'}) {
    final where = source;
    final Object? doc;
    try {
      doc = loadYaml(yaml);
    } on YamlException catch (e) {
      throw MarketConfigError('$where is not valid YAML: ${e.message}');
    }
    if (doc is! Map) throw MarketConfigError('$where must be a mapping');

    final rawMarkets = doc['markets'];
    if (rawMarkets is! List || rawMarkets.isEmpty) {
      throw MarketConfigError('$where lists no markets');
    }

    final markets = <Market>[];
    for (final entry in rawMarkets) {
      if (entry is! Map) {
        throw MarketConfigError('$where: a market must be a mapping');
      }
      markets.add(_market(entry, where));
    }

    final codes = <String>{};
    for (final m in markets) {
      if (!codes.add(m.code)) {
        throw MarketConfigError('$where: market ${m.code} appears twice');
      }
    }

    final defaultCode = _string(doc, 'defaultMarket', where).toUpperCase();
    final fallback = markets.where((m) => m.code == defaultCode).firstOrNull;
    if (fallback == null) {
      throw MarketConfigError(
        '$where: defaultMarket $defaultCode is not one of '
        '${markets.map((m) => m.code).join(', ')}',
      );
    }

    return MarketCatalog(markets: markets, defaultMarket: fallback);
  }

  static Market _market(Map<dynamic, dynamic> m, String where) {
    final code = _string(m, 'code', where).toUpperCase();
    final at = '$where: market $code';

    final currencyCode = _string(m, 'currency', at);
    final currency = Currency.byCode(currencyCode);
    if (currency == null) {
      // Not a typo we can guess our way past: the exponent is what decides
      // whether 9 000 is nine thousand or ninety, and inventing one is how a
      // fare comes out a hundred times wrong.
      throw MarketConfigError(
        '$at: unknown currency $currencyCode — add it to Currency first, '
        'with its exponent',
      );
    }

    final phone = m['phone'];
    if (phone is! Map) throw MarketConfigError('$at: needs a phone block');
    final prefixes = phone['prefixes'];
    if (prefixes is! Map || prefixes.isEmpty) {
      throw MarketConfigError('$at: needs at least one carrier prefix');
    }

    final rails = m['rails'];
    if (rails is! List || rails.isEmpty) {
      throw MarketConfigError('$at: needs at least one payment rail');
    }

    final parsed = <PaymentRail>[];
    final railIds = <String>{};
    for (final r in rails) {
      if (r is! Map) throw MarketConfigError('$at: a rail must be a mapping');
      final rail = _rail(r, currency, at);
      if (!railIds.add(rail.id)) {
        throw MarketConfigError('$at: rail ${rail.id} appears twice');
      }
      parsed.add(rail);
    }

    return Market(
      code: code,
      nameKey: _string(m, 'nameKey', at),
      currency: currency,
      msisdn: MsisdnPrefixTable(
        _string(phone, 'diallingCode', at),
        _int(phone, 'nationalLength', at),
        {
          for (final e in prefixes.entries)
            '${e.key}': MobileOperator('${e.value}'),
        },
      ),
      timeZone: _string(m, 'timeZone', at),
      defaultLanguage: _string(m, 'defaultLanguage', at),
      languages: _strings(m, 'languages', at),
      serviceFee: Money(_int(m, 'serviceFeeMinor', at), currency),
      defaultCommission: CommissionTerm(
        _int(m, 'defaultCommissionBps', at, orElse: CommissionTerm.seed.bps),
      ),
      rails: parsed,
    );
  }

  static PaymentRail _rail(
    Map<dynamic, dynamic> r,
    Currency currency,
    String where,
  ) {
    final id = _string(r, 'id', where);
    final at = '$where, rail $id';

    final kindName = _string(r, 'kind', at);
    final kind = PaymentRailKind.values
        .where((k) => k.name == kindName)
        .firstOrNull;
    if (kind == null) {
      throw MarketConfigError(
        '$at: unknown kind $kindName — one of '
        '${PaymentRailKind.values.map((k) => k.name).join(', ')}',
      );
    }

    final operatorId = r['operator'];
    if (kind == PaymentRailKind.mobileMoney && operatorId == null) {
      // Without a carrier there is nothing to pre-select the rail for, and no
      // adapter to resolve — the tile would render and then fail on tap.
      throw MarketConfigError('$at: a mobileMoney rail needs an operator');
    }

    Money? amount(String field) {
      final raw = r[field];
      if (raw == null) return null;
      if (raw is! int)
        throw MarketConfigError('$at: $field must be an integer');
      return Money(raw, currency);
    }

    return PaymentRail(
      id: id,
      kind: kind,
      operator: operatorId == null ? null : MobileOperator('$operatorId'),
      ussdCode: r['ussdCode'] as String?,
      minAmount: amount('minAmountMinor'),
      maxAmount: amount('maxAmountMinor'),
      enabled: r['enabled'] as bool? ?? true,
      disabledReasonKey: r['disabledReasonKey'] as String?,
    );
  }

  static String _string(Map<dynamic, dynamic> m, String field, String where) {
    final v = m[field];
    if (v is String && v.isNotEmpty) return v;
    throw MarketConfigError('$where: $field is missing');
  }

  static int _int(
    Map<dynamic, dynamic> m,
    String field,
    String where, {
    int? orElse,
  }) {
    final v = m[field];
    if (v is int) return v;
    if (v == null && orElse != null) return orElse;
    throw MarketConfigError('$where: $field must be an integer');
  }

  static List<String> _strings(
    Map<dynamic, dynamic> m,
    String field,
    String where,
  ) {
    final v = m[field];
    if (v is! List || v.isEmpty) {
      throw MarketConfigError('$where: $field must be a non-empty list');
    }
    return [for (final e in v) '$e'];
  }
}
