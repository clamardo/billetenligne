import '../money/money.dart';

/// What kind of instrument a rail is. This *is* a closed set — it describes
/// how a payment behaves, not who provides it, and the four shapes below are
/// genuinely all there are for us.
enum PaymentRailKind {
  /// Asynchronous, push-to-handset, PIN entered out of band. The default.
  mobileMoney,

  /// Synchronous-ish, 3-D Secure redirect, PSP-hosted.
  card,

  /// No PSP at all, but it implements the same port so agency and digital
  /// sales reconcile against one another.
  cash,

  bankTransfer,
}

/// A mobile money carrier.
///
/// Deliberately **not** a Dart `enum`. Carriers are an open set that grows
/// with every country — the DRC alone adds Vodacom M-Pesa and Orange Money,
/// and neither Congo-Brazzaville nor we should have to care. A closed enum
/// would mean every new market edits a type that `switch` statements across
/// the codebase depend on being exhaustive.
///
/// Identity is the [id] string, which is also what the wire format and the
/// translation catalog key off (`enum.MobileOperator.<id>`).
final class MobileOperator {
  const MobileOperator(this.id);

  final String id;

  // Congo-Brazzaville (launch).
  static const airtel = MobileOperator('airtel');
  static const mtn = MobileOperator('mtn');
  static const orange = MobileOperator('orange');

  // Known elsewhere in the region. Present so the identifiers are stable
  // before they are needed; no adapter exists for them yet.
  static const vodacomMpesa = MobileOperator('vodacom_mpesa');
  static const moov = MobileOperator('moov');

  static const unknown = MobileOperator('unknown');

  /// Carriers with a stable identifier. A market may reference one that is
  /// not listed here — this is a convenience, not a whitelist.
  static const known = <MobileOperator>[
    airtel,
    mtn,
    orange,
    vodacomMpesa,
    moov,
  ];

  static MobileOperator byId(String id) {
    for (final o in known) {
      if (o.id == id) return o;
    }
    return unknown;
  }

  bool get isKnown => this != unknown;

  /// Translation-catalog key. The label itself lives in
  /// `i18n/{lang}/enums/domain.yaml`, never here.
  String get labelKey => 'enum.MobileOperator.$id';

  @override
  bool operator ==(Object other) => other is MobileOperator && other.id == id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => id;
}

/// One way to pay, in one market.
///
/// A rail is **data**. Adding Orange Money to Congo, or standing up the DRC
/// with M-Pesa, is a new [PaymentRail] entry plus one adapter implementing the
/// `PaymentGateway` port — no change to the booking flow, the ledger, the
/// payment state machine or any screen. The app never hardcodes a rail list;
/// it renders whatever the server returns (ADR-0006).
final class PaymentRail {
  const PaymentRail({
    required this.id,
    required this.kind,
    this.operator,
    this.ussdCode,
    this.minAmount,
    this.maxAmount,
    this.enabled = true,
    this.disabledReasonKey,
  });

  /// Stable identifier used on the wire and to resolve an adapter, e.g.
  /// `cg.airtel_money`. Namespaced by market so two countries can run the
  /// same carrier with different credentials, limits and endpoints.
  final String id;

  final PaymentRailKind kind;

  /// Set for [PaymentRailKind.mobileMoney]; null otherwise.
  final MobileOperator? operator;

  /// Shown on the waiting screen when the push prompt does not arrive —
  /// prompts genuinely fail, and a user with a manual path beats a spinner.
  final String? ussdCode;

  final Money? minAmount;
  final Money? maxAmount;

  /// Rails are toggled from configuration, not by shipping an app release —
  /// critical in a market where many users never update.
  final bool enabled;

  /// Why it is unavailable, as a catalog key. A disabled tile always explains
  /// itself; a grey box with no reason is a support ticket.
  final String? disabledReasonKey;

  String get labelKey =>
      operator?.labelKey ?? 'enum.PaymentRailKind.${kind.name}';

  bool accepts(Money amount) {
    if (minAmount != null && amount < minAmount!) return false;
    if (maxAmount != null && amount > maxAmount!) return false;
    return true;
  }

  @override
  bool operator ==(Object other) => other is PaymentRail && other.id == id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => id;
}
