import '../identity/email_address.dart';
import '../identity/phone_number.dart';

/// The six steps of the onboarding wizard (`03-operator-lifecycle.md` §2.2).
///
/// An enum rather than a page index, because the *order* is a UI decision and
/// the *completeness* of each one is not. A reviewer's checklist, an
/// applicant's progress bar and the server's refusal to accept a half-filled
/// application are three readings of the same question, and this is where it
/// is answered once.
enum ApplicationStep {
  entreprise,
  dirigeant,
  licences,
  exploitation,
  encaissement,
  accord,
}

/// Everything the wizard has collected, at whatever stage it is at.
///
/// Every field is nullable and that is the design: an application is
/// *legitimately* incomplete for most of its life. "Save on every field"
/// (§2.2) means the server accepts a record whose only populated column is a
/// legal name, and the thing that must never be half-filled is the
/// **submission**, not the row.
final class ApplicationFacts {
  const ApplicationFacts({
    this.legalName,
    this.tradingName,
    this.rccmNumber,
    this.taxId,
    this.legalForm,
    this.registeredAddress,
    this.yearFounded,
    this.ownerName,
    this.ownerIdType,
    this.ownerIdNumber,
    this.ownerPhone,
    this.ownerEmail,
    this.transportLicenceNumber,
    this.transportLicenceExpires,
    this.insurerName,
    this.fleetInsuranceExpires,
    this.routesServed,
    this.fleetSize,
    this.stationCount,
    this.dailyDepartures,
    this.settlementKind,
    this.settlementAccountName,
    this.settlementAccountRef,
    this.agreementAccepted = false,
  });

  // 1 · Entreprise
  final String? legalName;
  final String? tradingName;
  final String? rccmNumber;
  final String? taxId;
  final String? legalForm;
  final String? registeredAddress;
  final int? yearFounded;

  // 2 · Dirigeant
  final String? ownerName;
  final String? ownerIdType;
  final String? ownerIdNumber;
  final String? ownerPhone;
  final String? ownerEmail;

  /// 3 · Licences — **declared, not photographed.**
  ///
  /// The scans live in `kyb_documents`, which the public role has no grant
  /// on and will not be given one: a table of identity documents is the last
  /// one to open to the internet, and the schema guarantee refuses it. What
  /// the wizard collects is the pair §3.3 actually enforces against — a
  /// number and an expiry — so a lapsed insurance certificate is a query
  /// rather than a discovery. The photographs are collected by the reviewer
  /// today, which is stated rather than implied.
  final String? transportLicenceNumber;
  final DateTime? transportLicenceExpires;
  final String? insurerName;
  final DateTime? fleetInsuranceExpires;

  // 4 · Exploitation
  final String? routesServed;
  final int? fleetSize;
  final int? stationCount;
  final int? dailyDepartures;

  // 5 · Encaissement
  final String? settlementKind;
  final String? settlementAccountName;
  final String? settlementAccountRef;

  // 6 · Accord
  final bool agreementAccepted;

  static const settlementKinds = {'momo', 'bank'};

  /// The field names this step is still missing.
  ///
  /// **Field names, never sentences** (ADR-0008). The surface renders
  /// `application.field.<name>`; the domain has no idea who is reading.
  List<String> missingIn(ApplicationStep step, {DateTime? asOf}) =>
      switch (step) {
        ApplicationStep.entreprise => [
          if (_blank(legalName)) 'legalName',
          if (!isValidRccm(rccmNumber)) 'rccmNumber',
          if (!isValidTaxId(taxId)) 'taxId',
          if (_blank(legalForm)) 'legalForm',
          if (_blank(registeredAddress)) 'registeredAddress',
        ],
        ApplicationStep.dirigeant => [
          if (_blank(ownerName)) 'ownerName',
          if (_blank(ownerIdType)) 'ownerIdType',
          if (_blank(ownerIdNumber)) 'ownerIdNumber',
          if (!_validPhone(ownerPhone)) 'ownerPhone',
          if (!_validEmail(ownerEmail)) 'ownerEmail',
        ],
        // A date in the past is worse than a missing one: it reads as answered
        // on a checklist. Judged only when the caller supplies [asOf] — the
        // domain does not own a clock, and a validator that reached for one
        // would be untestable in the only way that matters.
        ApplicationStep.licences => [
          if (_blank(transportLicenceNumber)) 'transportLicenceNumber',
          if (transportLicenceExpires == null ||
              (asOf != null && !transportLicenceExpires!.isAfter(asOf)))
            'transportLicenceExpires',
          if (_blank(insurerName)) 'insurerName',
          if (fleetInsuranceExpires == null ||
              (asOf != null && !fleetInsuranceExpires!.isAfter(asOf)))
            'fleetInsuranceExpires',
        ],
        ApplicationStep.exploitation => [
          if (_blank(routesServed)) 'routesServed',
          if (fleetSize == null || fleetSize! < 1) 'fleetSize',
          if (stationCount == null || stationCount! < 1) 'stationCount',
        ],
        ApplicationStep.encaissement => [
          if (!settlementKinds.contains(settlementKind)) 'settlementKind',
          if (_blank(settlementAccountName)) 'settlementAccountName',
          if (_blank(settlementAccountRef)) 'settlementAccountRef',
        ],
        ApplicationStep.accord => [if (!agreementAccepted) 'agreement'],
      };

  bool isComplete(ApplicationStep step, {DateTime? asOf}) =>
      missingIn(step, asOf: asOf).isEmpty;

  /// Everything outstanding, in wizard order — the persistent checklist §2.2
  /// asks for: *"Il manque : attestation d'assurance, RIB"*.
  List<String> missing({DateTime? asOf}) => [
    for (final step in ApplicationStep.values) ...missingIn(step, asOf: asOf),
  ];

  /// A submission is complete or it is not sent. There is no partial submit:
  /// a reviewer working a queue of half-applications is a reviewer who stops
  /// working the queue.
  bool isSubmittable({DateTime? asOf}) => missing(asOf: asOf).isEmpty;

  /// Steps done out of six — what the progress bar shows, and it tells the
  /// truth about what remains rather than about how far the applicant has
  /// scrolled.
  int stepsComplete({DateTime? asOf}) =>
      ApplicationStep.values.where((s) => isComplete(s, asOf: asOf)).length;

  /// The account name must match the legal name (§2.2 step 5). Compared
  /// loosely — case, accents in the punctuation sense, and the SARL/S.A.R.L.
  /// spelling are not what this check is for. A hard mismatch is what a
  /// reviewer needs flagged; a formatting difference is noise that trains
  /// people to click through warnings.
  bool get settlementNameMatchesLegalName {
    final a = _fold(settlementAccountName);
    final b = _fold(legalName);
    if (a.isEmpty || b.isEmpty) return false;
    return a == b || a.contains(b) || b.contains(a);
  }

  /// RCCM — the commercial register number.
  ///
  /// Deliberately permissive: the real format is
  /// `CG-BZV-01-2016-B12-00042`, and it is written by hand on paper by
  /// registries that do not all agree about separators. A validator that
  /// rejects a genuine number costs us an operator; one that accepts a
  /// malformed one costs a reviewer ten seconds. So this checks shape, not
  /// membership: allowed characters, a plausible length, and at least one
  /// digit — because "ABC" is a typo and `CG/BZV/01/2016/B12/00042` is a
  /// number.
  static bool isValidRccm(String? raw) {
    final v = (raw ?? '').trim().toUpperCase();
    if (v.length < 6 || v.length > 40) return false;
    if (!RegExp(r'^[A-Z0-9\-/. ]+$').hasMatch(v)) return false;
    return RegExp(r'[0-9]').hasMatch(v);
  }

  /// NIU — the tax identifier. Same reasoning, tighter alphabet.
  static bool isValidTaxId(String? raw) {
    final v = (raw ?? '').trim().toUpperCase();
    if (v.length < 6 || v.length > 24) return false;
    if (!RegExp(r'^[A-Z0-9\-]+$').hasMatch(v)) return false;
    return RegExp(r'[0-9]').hasMatch(v);
  }

  ApplicationFacts copyWith({
    String? legalName,
    String? tradingName,
    String? rccmNumber,
    String? taxId,
    String? legalForm,
    String? registeredAddress,
    int? yearFounded,
    String? ownerName,
    String? ownerIdType,
    String? ownerIdNumber,
    String? ownerPhone,
    String? ownerEmail,
    String? transportLicenceNumber,
    DateTime? transportLicenceExpires,
    String? insurerName,
    DateTime? fleetInsuranceExpires,
    String? routesServed,
    int? fleetSize,
    int? stationCount,
    int? dailyDepartures,
    String? settlementKind,
    String? settlementAccountName,
    String? settlementAccountRef,
    bool? agreementAccepted,
  }) => ApplicationFacts(
    legalName: legalName ?? this.legalName,
    tradingName: tradingName ?? this.tradingName,
    rccmNumber: rccmNumber ?? this.rccmNumber,
    taxId: taxId ?? this.taxId,
    legalForm: legalForm ?? this.legalForm,
    registeredAddress: registeredAddress ?? this.registeredAddress,
    yearFounded: yearFounded ?? this.yearFounded,
    ownerName: ownerName ?? this.ownerName,
    ownerIdType: ownerIdType ?? this.ownerIdType,
    ownerIdNumber: ownerIdNumber ?? this.ownerIdNumber,
    ownerPhone: ownerPhone ?? this.ownerPhone,
    ownerEmail: ownerEmail ?? this.ownerEmail,
    transportLicenceNumber:
        transportLicenceNumber ?? this.transportLicenceNumber,
    transportLicenceExpires:
        transportLicenceExpires ?? this.transportLicenceExpires,
    insurerName: insurerName ?? this.insurerName,
    fleetInsuranceExpires: fleetInsuranceExpires ?? this.fleetInsuranceExpires,
    routesServed: routesServed ?? this.routesServed,
    fleetSize: fleetSize ?? this.fleetSize,
    stationCount: stationCount ?? this.stationCount,
    dailyDepartures: dailyDepartures ?? this.dailyDepartures,
    settlementKind: settlementKind ?? this.settlementKind,
    settlementAccountName: settlementAccountName ?? this.settlementAccountName,
    settlementAccountRef: settlementAccountRef ?? this.settlementAccountRef,
    agreementAccepted: agreementAccepted ?? this.agreementAccepted,
  );

  static bool _blank(String? v) => (v ?? '').trim().isEmpty;

  static bool _validEmail(String? v) => v != null && EmailAddress.parse(v).isOk;

  static bool _validPhone(String? v) => v != null && PhoneNumber.parse(v).isOk;

  /// Lower-cased, punctuation and company-form noise removed.
  static String _fold(String? v) {
    if (v == null) return '';
    var s = v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    for (final noise in const [
      'sarl',
      'sa',
      'sas',
      'sarlu',
      'ets',
      'etablissements',
      'societe',
      'entreprise',
    ]) {
      s = s.replaceAll(RegExp('\\b$noise\\b'), ' ');
    }
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

/// A generated operator code — `oceandunord` becomes `OCEAN-4K2`.
///
/// Server-side and never the applicant's choice: the code appears in
/// `blt.cg/o/<code>`, so letting somebody type one is letting them squat
/// `TAXI` or impersonate a competitor. Derived from the legal name so it is
/// recognisable, suffixed so it is unique.
String operatorCodeFrom(String legalName, String entropy) {
  final letters = legalName.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final stem = letters.isEmpty
      ? 'OP'
      : letters.substring(0, letters.length < 6 ? letters.length : 6);
  final tail = entropy
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]'), '')
      .padRight(3, 'X');
  return '$stem-${tail.substring(0, 3)}';
}
