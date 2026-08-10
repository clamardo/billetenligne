import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// The wizard's answers on the wire.
///
/// Flat, and deliberately not six nested objects one per step. The steps are
/// a UI decision — `03-operator-lifecycle.md` §2.2 could reorder them
/// tomorrow — and a wire format that encodes the pagination is a wire format
/// that breaks when somebody moves a field.
///
/// **What is not here is the checklist.** `missing`, `isSubmittable` and the
/// RCCM check all live in `bel_domain`, which both the console and the server
/// compile (ADR-0004), so the progress bar and the server's refusal are the
/// same function rather than two implementations that agree until they do
/// not.
final class ApplicationFactsDto {
  const ApplicationFactsDto(this.facts);

  final ApplicationFacts facts;

  Map<String, Object?> toJson() => Wire.compact({
    'legalName': facts.legalName,
    'tradingName': facts.tradingName,
    'rccmNumber': facts.rccmNumber,
    'taxId': facts.taxId,
    'legalForm': facts.legalForm,
    'registeredAddress': facts.registeredAddress,
    'yearFounded': facts.yearFounded,
    'ownerName': facts.ownerName,
    'ownerIdType': facts.ownerIdType,
    'ownerIdNumber': facts.ownerIdNumber,
    'ownerPhone': facts.ownerPhone,
    'ownerEmail': facts.ownerEmail,
    'transportLicenceNumber': facts.transportLicenceNumber,
    'transportLicenceExpires': _day(facts.transportLicenceExpires),
    'insurerName': facts.insurerName,
    'fleetInsuranceExpires': _day(facts.fleetInsuranceExpires),
    'routesServed': facts.routesServed,
    'fleetSize': facts.fleetSize,
    'stationCount': facts.stationCount,
    'dailyDepartures': facts.dailyDepartures,
    'settlementKind': facts.settlementKind,
    'settlementAccountName': facts.settlementAccountName,
    'settlementAccountRef': facts.settlementAccountRef,
    'agreementAccepted': facts.agreementAccepted,
  });

  factory ApplicationFactsDto.fromJson(Map<String, Object?> json) =>
      ApplicationFactsDto(
        ApplicationFacts(
          legalName: json['legalName'] as String?,
          tradingName: json['tradingName'] as String?,
          rccmNumber: json['rccmNumber'] as String?,
          taxId: json['taxId'] as String?,
          legalForm: json['legalForm'] as String?,
          registeredAddress: json['registeredAddress'] as String?,
          yearFounded: json['yearFounded'] as int?,
          ownerName: json['ownerName'] as String?,
          ownerIdType: json['ownerIdType'] as String?,
          ownerIdNumber: json['ownerIdNumber'] as String?,
          ownerPhone: json['ownerPhone'] as String?,
          ownerEmail: json['ownerEmail'] as String?,
          transportLicenceNumber: json['transportLicenceNumber'] as String?,
          transportLicenceExpires: _readDay(json['transportLicenceExpires']),
          insurerName: json['insurerName'] as String?,
          fleetInsuranceExpires: _readDay(json['fleetInsuranceExpires']),
          routesServed: json['routesServed'] as String?,
          fleetSize: json['fleetSize'] as int?,
          stationCount: json['stationCount'] as int?,
          dailyDepartures: json['dailyDepartures'] as int?,
          settlementKind: json['settlementKind'] as String?,
          settlementAccountName: json['settlementAccountName'] as String?,
          settlementAccountRef: json['settlementAccountRef'] as String?,
          agreementAccepted: json['agreementAccepted'] == true,
        ),
      );

  /// `YYYY-MM-DD`, not an instant. An insurance certificate expires on a day
  /// in the operator's own country; sending it as UTC midnight is how a
  /// certificate valid until the 30th reads as expired on the 30th.
  static String? _day(DateTime? v) => v == null
      ? null
      : '${v.year.toString().padLeft(4, '0')}-'
            '${v.month.toString().padLeft(2, '0')}-'
            '${v.day.toString().padLeft(2, '0')}';

  static DateTime? _readDay(Object? v) {
    if (v is! String || v.isEmpty) return null;
    final parsed = DateTime.tryParse(v);
    return parsed == null
        ? null
        : DateTime.utc(parsed.year, parsed.month, parsed.day);
  }
}

/// An application, as the applicant's own wizard renders it.
final class OperatorApplicationDto {
  const OperatorApplicationDto({
    required this.operatorId,
    required this.code,
    required this.status,
    required this.facts,
    required this.createdAt,
    this.submittedAt,
    this.decisionReason,
  });

  final String operatorId;
  final String code;

  /// `application_draft`, `under_review`, `info_requested`, `approved`,
  /// `active`, `rejected` — the lifecycle in §1, unrenamed for the wire.
  final String status;

  final ApplicationFacts facts;
  final DateTime createdAt;
  final DateTime? submittedAt;

  /// What a reviewer typed when they asked for more or refused. Free text
  /// **and therefore the one prose field the server sends** — it is somebody's
  /// sentence about this specific application, so there is no key to render
  /// it from (ADR-0008 is about messages the system composes, not about
  /// quoting a human).
  final String? decisionReason;

  bool get isEditable =>
      status == 'application_draft' || status == 'info_requested';

  Map<String, Object?> toJson() => Wire.compact({
    'operatorId': operatorId,
    'code': code,
    'status': status,
    'facts': ApplicationFactsDto(facts).toJson(),
    'createdAt': Wire.instant(createdAt),
    'submittedAt': submittedAt == null ? null : Wire.instant(submittedAt!),
    'decisionReason': decisionReason,
  });

  factory OperatorApplicationDto.fromJson(Map<String, Object?> json) =>
      OperatorApplicationDto(
        operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
        code: Wire.requireString(json['code'], 'code'),
        status: Wire.requireString(json['status'], 'status'),
        facts: ApplicationFactsDto.fromJson(
          Wire.requireMap(json['facts'], 'facts'),
        ).facts,
        createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
        submittedAt: Wire.readInstantOrNull(
          json['submittedAt'],
          field: 'submittedAt',
        ),
        decisionReason: json['decisionReason'] as String?,
      );
}

/// "I want to sell tickets." The only thing asked before the wizard opens.
///
/// One field, on purpose: §2.1 wants the applicant looking at their own
/// dashboard inside fifteen minutes, and a signup form that asks for an RCCM
/// number before it shows anything is a form people close.
final class StartApplicationRequest {
  const StartApplicationRequest({required this.legalName});

  final String legalName;

  Map<String, Object?> toJson() => {'legalName': legalName};

  factory StartApplicationRequest.fromJson(Map<String, Object?> json) =>
      StartApplicationRequest(
        legalName: Wire.requireString(json['legalName'], 'legalName'),
      );
}
