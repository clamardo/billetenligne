/// Base of every domain failure.
///
/// [messageKey] is a translation-catalog key (ADR-0008) — the domain never
/// produces user-facing prose, so a failure renders in the reader's own
/// language on whichever surface displays it.
abstract class DomainFailure {
  const DomainFailure();

  String get code;
  String get messageKey => 'errors.$code';
  Map<String, Object?> get params => const {};
}
