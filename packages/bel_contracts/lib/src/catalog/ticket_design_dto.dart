import '../json/json_codec.dart';

/// One saved printed-ticket design, over the wire.
///
/// The design itself travels as the JSON `TicketDesign.toJson()` produces,
/// unopened: this DTO carries the row around it — who owns it, what they
/// called it, whether it is the one a till prints without asking. The
/// vocabulary inside (`accentHue`, `motif`, `fields`) is validated by the
/// domain on both sides of the wire, and re-listing it here would be the same
/// closed set written a third time.
final class TicketDesignDto {
  const TicketDesignDto({
    required this.id,
    required this.name,
    required this.format,
    required this.design,
    required this.isDefault,
  });

  final String id;
  final String name;
  final String format;

  /// `TicketDesign.toJson()`, passed through.
  final Map<String, Object?> design;

  /// The one a till prints when nobody chose. At most one per format.
  final bool isDefault;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'format': format,
    'design': design,
    'isDefault': isDefault,
  };

  factory TicketDesignDto.fromJson(Map<String, Object?> json) =>
      TicketDesignDto(
        id: Wire.requireString(json['id'], 'id'),
        name: Wire.requireString(json['name'], 'name'),
        format: Wire.requireString(json['format'], 'format'),
        design: (json['design'] as Map?)?.cast<String, Object?>() ?? const {},
        isDefault: json['isDefault'] == true,
      );
}

/// Saving one. A null [id] creates; an id updates in place.
final class SaveTicketDesignRequest {
  const SaveTicketDesignRequest({
    required this.name,
    required this.design,
    this.id,
    this.makeDefault = false,
  });

  final String? id;
  final String name;
  final Map<String, Object?> design;

  /// Asking for this to become the till's default. Clearing the previous one
  /// is the server's job, not two calls from the console — a moment with two
  /// defaults is a moment a till prints the wrong ticket.
  final bool makeDefault;

  static const nameMax = 40;

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'design': design,
    'makeDefault': makeDefault,
  };

  factory SaveTicketDesignRequest.fromJson(Map<String, Object?> json) =>
      SaveTicketDesignRequest(
        id: json['id'] as String?,
        name: Wire.requireString(json['name'], 'name'),
        design: (json['design'] as Map?)?.cast<String, Object?>() ?? const {},
        makeDefault: json['makeDefault'] == true,
      );
}

/// Where to send a vendor's browser so it prints.
///
/// Deliberately the whole URL and nothing else. The console never learns the
/// token as a value it could store or display — it opens this and forgets it,
/// and the link is dead in minutes.
final class PrintLinkDto {
  const PrintLinkDto({required this.url, required this.expiresAt});

  final String url;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
    'url': url,
    'expiresAt': Wire.instant(expiresAt),
  };

  factory PrintLinkDto.fromJson(Map<String, Object?> json) => PrintLinkDto(
    url: Wire.requireString(json['url'], 'url'),
    expiresAt: Wire.readInstant(json['expiresAt'], field: 'expiresAt'),
  );
}
