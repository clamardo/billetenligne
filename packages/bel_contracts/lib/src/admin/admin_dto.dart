import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';
import '../onboarding/application_dto.dart';
import 'operator_lifecycle.dart';

/// An operator, as our own back office lists them.
///
/// Deliberately not the console's operator shape: this one carries the review
/// queue's facts — how long it has waited, how many documents are expiring,
/// what commission was agreed — and none of them belong on a screen an
/// operator can open.
final class AdminOperatorDto {
  const AdminOperatorDto({
    required this.id,
    required this.code,
    required this.legalName,
    required this.status,
    required this.marketCode,
    required this.createdAt,
    required this.commissionBps,
    this.tradingName,
    this.rccmNumber,
    this.taxId,
    this.documentCount = 0,
    this.expiringDocumentCount = 0,
    this.vehicleCount = 0,
    this.routeCount = 0,
    this.staffCount = 0,
    this.riskBand,
    this.riskReasons = const [],
  });

  final String id;
  final String code;
  final String legalName;
  final String status;
  final String marketCode;
  final DateTime createdAt;

  /// Basis points. 500 is 5%. Never a float on the wire, for the same reason
  /// it is never one in the domain.
  final int commissionBps;

  final String? tradingName;
  final String? rccmNumber;
  final String? taxId;
  final int documentCount;
  final int expiringDocumentCount;
  final int vehicleCount;
  final int routeCount;
  final int staffCount;

  /// `low` · `standard` · `elevated`, from the auto-review pass
  /// (`03-operator-lifecycle.md` §2.3). **Null means not yet looked at**, and
  /// a queue must draw that differently from `low`: one is a judgement and
  /// the other is the absence of one.
  final String? riskBand;

  /// Why it is not the band below, as codes. Rendered through the catalog
  /// like every other server-emitted label (ADR-0008), and never shown to the
  /// applicant — telling somebody which check they failed is how a check
  /// becomes a tool for finding the way past it.
  final List<String> riskReasons;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'code': code,
    'legalName': legalName,
    'tradingName': tradingName,
    'status': status,
    'marketCode': marketCode,
    'createdAt': Wire.instant(createdAt),
    'commissionBps': commissionBps,
    'rccmNumber': rccmNumber,
    'taxId': taxId,
    'documentCount': documentCount,
    'expiringDocumentCount': expiringDocumentCount,
    'vehicleCount': vehicleCount,
    'routeCount': routeCount,
    'staffCount': staffCount,
    'riskBand': riskBand,
    if (riskReasons.isNotEmpty) 'riskReasons': riskReasons,
  });

  factory AdminOperatorDto.fromJson(Map<String, Object?> json) =>
      AdminOperatorDto(
        id: Wire.requireString(json['id'], 'id'),
        code: Wire.requireString(json['code'], 'code'),
        legalName: Wire.requireString(json['legalName'], 'legalName'),
        tradingName: json['tradingName'] as String?,
        status: Wire.requireString(json['status'], 'status'),
        marketCode: Wire.requireString(json['marketCode'], 'marketCode'),
        createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
        commissionBps: Wire.requireInt(json['commissionBps'], 'commissionBps'),
        rccmNumber: json['rccmNumber'] as String?,
        taxId: json['taxId'] as String?,
        documentCount: (json['documentCount'] as int?) ?? 0,
        expiringDocumentCount: (json['expiringDocumentCount'] as int?) ?? 0,
        vehicleCount: (json['vehicleCount'] as int?) ?? 0,
        routeCount: (json['routeCount'] as int?) ?? 0,
        staffCount: (json['staffCount'] as int?) ?? 0,
        riskBand: json['riskBand'] as String?,
        riskReasons: [
          for (final code in (json['riskReasons'] as List?) ?? const [])
            code as String,
        ],
      );

  /// The lifecycle states a reviewer has to act on.
  ///
  /// Named here as well as on [OperatorLifecycle] because the queue screen
  /// sends exactly this list as its filter, and one table shared by the
  /// server's SQL guard and the client's filter is one table that cannot
  /// disagree with itself.
  static const pendingStatuses = OperatorLifecycle.pending;

  bool get isPending => pendingStatuses.contains(status);
}

final class KybDocumentDto {
  const KybDocumentDto({
    required this.id,
    required this.docType,
    required this.createdAt,
    this.expiresAt,
    this.verifiedAt,
    this.rejectedReason,
  });

  final String id;

  /// `rccm` | `insurance` | `licence` | `owner_id` | … A string rather than an
  /// enum, because the list a regulator asks for changes, and a migration per
  /// document type is a migration per regulation.
  final String docType;

  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? verifiedAt;
  final String? rejectedReason;

  bool get isVerified => verifiedAt != null;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'docType': docType,
    'createdAt': Wire.instant(createdAt),
    'expiresAt': expiresAt == null ? null : Wire.instant(expiresAt!),
    'verifiedAt': verifiedAt == null ? null : Wire.instant(verifiedAt!),
    'rejectedReason': rejectedReason,
  });

  factory KybDocumentDto.fromJson(Map<String, Object?> json) => KybDocumentDto(
    id: Wire.requireString(json['id'], 'id'),
    docType: Wire.requireString(json['docType'], 'docType'),
    createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
    expiresAt: Wire.readInstantOrNull(json['expiresAt'], field: 'expiresAt'),
    verifiedAt: Wire.readInstantOrNull(json['verifiedAt'], field: 'verifiedAt'),
    rejectedReason: json['rejectedReason'] as String?,
  );
}

/// One line of the immutable trail. Read-only everywhere, including here.
final class AuditEntryDto {
  const AuditEntryDto({
    required this.action,
    required this.actorType,
    required this.createdAt,
    this.actorId,
    this.reason,
  });

  final String action;
  final String actorType;
  final DateTime createdAt;
  final String? actorId;
  final String? reason;

  Map<String, Object?> toJson() => Wire.compact({
    'action': action,
    'actorType': actorType,
    'createdAt': Wire.instant(createdAt),
    'actorId': actorId,
    'reason': reason,
  });

  factory AuditEntryDto.fromJson(Map<String, Object?> json) => AuditEntryDto(
    action: Wire.requireString(json['action'], 'action'),
    actorType: Wire.requireString(json['actorType'], 'actorType'),
    createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
    actorId: json['actorId'] as String?,
    reason: json['reason'] as String?,
  );
}

/// Everything about one operator on one page.
final class AdminOperatorDetailDto {
  const AdminOperatorDetailDto({
    required this.operator,
    this.documents = const [],
    this.trail = const [],
    this.application,
    this.submittedAt,
  });

  final AdminOperatorDto operator;

  /// What the applicant typed into the wizard, or null for an operator that
  /// arrived before self-signup existed. The reviewer's checklist is computed
  /// from it by the same domain code the applicant's progress bar used, so
  /// the two cannot disagree about what is missing.
  final ApplicationFacts? application;

  final DateTime? submittedAt;
  final List<KybDocumentDto> documents;
  final List<AuditEntryDto> trail;

  Map<String, Object?> toJson() => Wire.compact({
    'operator': operator.toJson(),
    'application': application == null
        ? null
        : ApplicationFactsDto(application!).toJson(),
    'submittedAt': submittedAt == null ? null : Wire.instant(submittedAt!),
    'documents': [for (final d in documents) d.toJson()],
    'trail': [for (final e in trail) e.toJson()],
  });

  factory AdminOperatorDetailDto.fromJson(Map<String, Object?> json) =>
      AdminOperatorDetailDto(
        operator: AdminOperatorDto.fromJson(
          Wire.requireMap(json['operator'], 'operator'),
        ),
        application: json['application'] == null
            ? null
            : ApplicationFactsDto.fromJson(
                Wire.requireMap(json['application'], 'application'),
              ).facts,
        submittedAt: Wire.readInstantOrNull(
          json['submittedAt'],
          field: 'submittedAt',
        ),
        documents: Wire.readList(
          json['documents'],
          KybDocumentDto.fromJson,
          field: 'documents',
        ),
        trail: Wire.readList(
          json['trail'],
          AuditEntryDto.fromJson,
          field: 'trail',
        ),
      );
}

/// Approve · request info · reject · suspend · reinstate.
///
/// The reason is a required field, not an optional note. "Why" is the question
/// an audit answers and it cannot be reconstructed afterwards (ADR-0011).
final class OperatorDecisionRequest {
  const OperatorDecisionRequest({
    required this.decision,
    required this.reason,
    this.detail,
  });

  final String decision;
  final String reason;
  final String? detail;

  Map<String, Object?> toJson() =>
      Wire.compact({'decision': decision, 'reason': reason, 'detail': detail});

  factory OperatorDecisionRequest.fromJson(Map<String, Object?> json) =>
      OperatorDecisionRequest(
        decision: Wire.requireString(json['decision'], 'decision'),
        reason: Wire.requireString(json['reason'], 'reason'),
        detail: json['detail'] as String?,
      );
}

/// Sets what an operator negotiated.
final class SetCommissionRequest {
  const SetCommissionRequest({
    required this.commissionBps,
    required this.reason,
  });

  final int commissionBps;
  final String reason;

  Map<String, Object?> toJson() => {
    'commissionBps': commissionBps,
    'reason': reason,
  };

  factory SetCommissionRequest.fromJson(Map<String, Object?> json) =>
      SetCommissionRequest(
        commissionBps: Wire.requireInt(json['commissionBps'], 'commissionBps'),
        reason: Wire.requireString(json['reason'], 'reason'),
      );
}

/// Who is signed in to the back office, and what they may do.
final class AdminIdentityDto {
  const AdminIdentityDto({
    required this.userId,
    required this.role,
    required this.capabilities,
    this.email,
    this.fullName,
  });

  final String userId;
  final String role;

  /// Sent so the app can hide what this person cannot do. **Never** the thing
  /// that decides it: every route re-checks server-side, because a hidden
  /// button is a UI convenience and not a control (ADR-0011).
  final List<String> capabilities;

  final String? email;
  final String? fullName;

  /// The same shape `ConsoleIdentityDto` offers, so a screen written against
  /// one reads the same as a screen written against the other. A hint for
  /// drawing navigation — never the thing that decides.
  bool can(String capability) => capabilities.contains(capability);

  Map<String, Object?> toJson() => Wire.compact({
    'userId': userId,
    'role': role,
    'capabilities': capabilities,
    'email': email,
    'fullName': fullName,
  });

  factory AdminIdentityDto.fromJson(Map<String, Object?> json) =>
      AdminIdentityDto(
        userId: Wire.requireString(json['userId'], 'userId'),
        role: Wire.requireString(json['role'], 'role'),
        capabilities:
            (json['capabilities'] as List?)?.cast<String>() ?? const [],
        email: json['email'] as String?,
        fullName: json['fullName'] as String?,
      );
}
