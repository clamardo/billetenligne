import 'money.dart';

/// What we keep from one operator's fare, netted at source.
///
/// **A commission is a term of a contract with one operator, not a property
/// of a country.** It is negotiated when that operator is onboarded — a large
/// carrier with its own agency network argues for less than a two-coach
/// family business, and both are right — so the rate lives on the operator
/// row (`operators.commission_bps`) and this type is how it travels from
/// there to a ledger posting.
///
/// Basis points, never a `double`. 500 bps is 5%. A percentage kept as
/// floating point is one that eventually credits an operator a franc less
/// than their own arithmetic says, and that argument costs more than the
/// franc.
///
/// The ceiling mirrors the database CHECK rather than inventing a second
/// policy: the two must agree, and a value the schema would refuse must never
/// reach a ledger posting.
final class CommissionTerm {
  const CommissionTerm._(this.bps);

  factory CommissionTerm(int bps) {
    if (bps < 0 || bps > maxBps) {
      throw ArgumentError.value(bps, 'bps', 'must be between 0 and $maxBps');
    }
    return CommissionTerm._(bps);
  }

  /// 30% — the ceiling `operators_commission_sane` already enforces.
  static const maxBps = 3000;

  /// Where a newly onboarded operator starts, before anybody negotiates: the
  /// opening line of a conversation, not a rate everyone is charged forever.
  static const seed = CommissionTerm._(500);

  /// Cash sales carry none of it at all (product brief D-04).
  static const none = CommissionTerm._(0);

  final int bps;

  /// Rounded half-up, like every other money multiplication here, because an
  /// operator checking our arithmetic by hand rounds that way.
  Money on(Money fare) => fare.percentBps(bps);

  /// For a statement or an onboarding screen: `5%`, `7.5%`, `12.25%`.
  String get display {
    final whole = bps ~/ 100;
    final fraction = bps % 100;
    if (fraction == 0) return '$whole%';
    final decimals = fraction.toString().padLeft(2, '0');
    return '$whole.${decimals.endsWith('0') ? decimals[0] : decimals}%';
  }

  @override
  bool operator ==(Object other) =>
      other is CommissionTerm && other.bps == bps;

  @override
  int get hashCode => bps.hashCode;

  @override
  String toString() => 'CommissionTerm($display)';
}
