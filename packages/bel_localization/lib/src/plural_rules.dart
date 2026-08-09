/// CLDR plural categories for the languages we ship.
///
/// French and English disagree at zero — `0 place` is *singular* in French,
/// `0 seats` is *plural* in English. This is precisely the case machine
/// translation gets wrong, which is why it is code and not a convention.
final class PluralRules {
  const PluralRules._();

  static String category(String language, num count) {
    if (language.startsWith('fr')) {
      return (count >= 0 && count < 2) ? 'one' : 'other';
    }
    return count == 1 ? 'one' : 'other';
  }
}
