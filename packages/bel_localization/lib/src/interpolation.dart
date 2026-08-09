/// Named-placeholder interpolation: `"Depart a {time} depuis {station}"`.
///
/// Named only, never positional and never concatenation — French word order is
/// not English word order (ADR-0008).
final class TranslationInterpolation {
  const TranslationInterpolation._();

  static final _placeholder = RegExp(r'\{(\w+)\}');

  static String format(String template, Map<String, Object?> args) {
    if (args.isEmpty || !template.contains('{')) return template;
    return template.replaceAllMapped(_placeholder, (m) {
      final key = m.group(1)!;
      final value = args[key];
      // An unknown placeholder is left intact rather than blanked — a visible
      // `{seat}` in QA is a bug report; a silent empty string is a mystery.
      return value?.toString() ?? m.group(0)!;
    });
  }

  /// Every placeholder a template expects. Used by the CI check that asserts
  /// fr and en agree on their placeholders.
  static Set<String> placeholdersIn(String template) =>
      _placeholder.allMatches(template).map((m) => m.group(1)!).toSet();
}
