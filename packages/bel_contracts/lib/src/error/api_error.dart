import '../json/json_codec.dart';
import 'error_code.dart';

/// The single error shape every endpoint returns.
///
/// ```json
/// { "error": { "code": "payment.insufficient_funds",
///              "messageKey": "errors.payment.insufficient_funds",
///              "params": { "operator": "Airtel Money" },
///              "retryable": true,
///              "traceId": "01J..." } }
/// ```
///
/// There is no `message` field, deliberately. A human-readable string here
/// would be rendered in whatever language the server happened to pick, and
/// would eventually be shown to a French traveller in English (ADR-0008).
final class ApiError {
  const ApiError({
    required this.code,
    this.params = const {},
    this.traceId,
    this.fieldErrors = const {},
    bool? retryable,
  }) : _retryable = retryable;

  final String code;

  /// Interpolation values for the catalog template, e.g. `{operator}`.
  final Map<String, Object?> params;

  /// Correlates a user-visible failure with the server log. Shown in the
  /// support screen so an agent can find the request in one search.
  final String? traceId;

  /// Per-field validation problems, keyed by field path.
  final Map<String, String> fieldErrors;

  final bool? _retryable;

  bool get retryable => _retryable ?? ErrorCode.retryable.contains(code);

  String get messageKey => ErrorCode.messageKey(code);

  Map<String, Object?> toJson() => {
    'error': Wire.compact({
      'code': code,
      'messageKey': messageKey,
      'params': params.isEmpty ? null : params,
      'retryable': retryable,
      'traceId': traceId,
      'fieldErrors': fieldErrors.isEmpty ? null : fieldErrors,
    }),
  };

  factory ApiError.fromJson(Map<String, Object?> json) {
    final body = Wire.requireMap(json['error'] ?? json, 'error');
    return ApiError(
      code: Wire.requireString(body['code'], 'error.code'),
      params: (body['params'] as Map?)?.cast<String, Object?>() ?? const {},
      traceId: body['traceId'] as String?,
      retryable: body['retryable'] as bool?,
      fieldErrors:
          (body['fieldErrors'] as Map?)?.cast<String, String>() ?? const {},
    );
  }

  /// Maps a domain failure straight onto the wire. The domain already speaks
  /// in codes and params, so this is a rename, not a translation.
  factory ApiError.fromDomain(
    String code, {
    Map<String, Object?> params = const {},
    String? traceId,
  }) => ApiError(code: code, params: params, traceId: traceId);

  @override
  String toString() => 'ApiError($code, params: $params)';
}
