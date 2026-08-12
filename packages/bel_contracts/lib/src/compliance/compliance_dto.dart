import '../json/json_codec.dart';

/// One dated document, and where it stands on the expiry ladder.
///
/// [stage] is the domain enum's name, not a sentence: `warned`, `blocked`.
/// The console renders it through the catalog like every other server-emitted
/// label (ADR-0008), so the same payload reads correctly to an operator whose
/// console is in English and to the reviewer looking at it in French.
final class ComplianceDocDto {
  const ComplianceDocDto({
    required this.docType,
    required this.expiresAt,
    required this.stage,
    required this.daysLeft,
  });

  /// `fleet_insurance`, `transport_licence`… Free text in the database
  /// because the set differs by market, so a client must be able to render a
  /// type it has never heard of.
  final String docType;

  final DateTime expiresAt;
  final String stage;

  /// Signed and whole: 3 means three days and change remain, −3 that it
  /// lapsed three days ago.
  final int daysLeft;

  Map<String, Object?> toJson() => {
    'docType': docType,
    'expiresAt': Wire.instant(expiresAt),
    'stage': stage,
    'daysLeft': daysLeft,
  };

  factory ComplianceDocDto.fromJson(Map<String, Object?> json) =>
      ComplianceDocDto(
        docType: Wire.requireString(json['docType'], 'docType'),
        expiresAt: Wire.readInstant(json['expiresAt'], field: 'expiresAt'),
        stage: Wire.requireString(json['stage'], 'stage'),
        daysLeft: Wire.requireInt(json['daysLeft'], 'daysLeft'),
      );
}

/// One operator's compliance standing: what the console banner is drawn from,
/// and what our own compliance calendar lists.
///
/// **The same payload on both surfaces.** An operator being told why its
/// sales stopped and a reviewer being told why they stopped are the same
/// facts, and two shapes would eventually disagree about the date — which is
/// exactly the disagreement that turns an enforcement into an argument.
final class ComplianceDto {
  const ComplianceDto({
    required this.operatorId,
    required this.stage,
    this.operatorName,
    this.salesBlockedAt,
    this.blockedDoc,
    this.documents = const [],
  });

  final String operatorId;

  /// Present on our own compliance calendar, absent on the operator's own
  /// console — they know who they are.
  final String? operatorName;

  /// The worst stage among [documents]. `clear` when there is nothing dated,
  /// which is not the same as compliant and is not claimed to be.
  final String stage;

  /// When the ladder stopped new sales. Null while they are still selling.
  final DateTime? salesBlockedAt;

  /// The `docType` that stopped them, so the banner names the certificate
  /// rather than saying "a document".
  final String? blockedDoc;

  /// Latest copy of each kind, worst first.
  final List<ComplianceDocDto> documents;

  bool get salesBlocked => salesBlockedAt != null;

  Map<String, Object?> toJson() => Wire.compact({
    'operatorId': operatorId,
    'operatorName': operatorName,
    'stage': stage,
    'salesBlockedAt': salesBlockedAt == null
        ? null
        : Wire.instant(salesBlockedAt!),
    'blockedDoc': blockedDoc,
    if (documents.isNotEmpty)
      'documents': [for (final d in documents) d.toJson()],
  });

  factory ComplianceDto.fromJson(Map<String, Object?> json) => ComplianceDto(
    operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
    operatorName: json['operatorName'] as String?,
    stage: Wire.requireString(json['stage'], 'stage'),
    salesBlockedAt: Wire.readInstantOrNull(
      json['salesBlockedAt'],
      field: 'salesBlockedAt',
    ),
    blockedDoc: json['blockedDoc'] as String?,
    documents: [
      for (final d in (json['documents'] as List?) ?? const [])
        ComplianceDocDto.fromJson((d as Map).cast<String, Object?>()),
    ],
  );
}
