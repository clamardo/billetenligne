/// One entry from `i18n/languages.yaml`.
final class SupportedLanguage {
  const SupportedLanguage({
    required this.code,
    required this.culture,
    required this.englishName,
    required this.nativeName,
    required this.flag,
    required this.rtl,
    required this.displayOrder,
  });

  /// Folder name under `i18n/`, and the value stored on the account.
  final String code;

  /// Used for date/number formatting only — never for string lookup.
  final String culture;

  final String englishName;
  final String nativeName;
  final String flag;
  final bool rtl;
  final int displayOrder;

  @override
  String toString() => '$code ($nativeName)';
}
