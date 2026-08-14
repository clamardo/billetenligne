/// The eight curated accent hues, as hex, for the pages this server renders
/// itself.
///
/// Duplicated from `bel_design`'s `AccentHue` rather than imported:
/// `bel_design` is Flutter, this runs on the server, and a `Color` cannot
/// cross that line. The set is closed — it is a CHECK constraint on
/// `operators.accent_hue`, not a colour picker — and
/// `packages/bel_design/test/components_test.dart` asserts these exact values
/// so a ninth hue cannot be added on one side of the line alone.
abstract final class AccentHues {
  static const table = <String, String>{
    'foret': '#0A6B4F',
    'laterite': '#D9772F',
    'indigo': '#1E3A6B',
    'brique': '#B4502E',
    'prune': '#6B2D5C',
    'ocean': '#0E5E75',
    'olive': '#54661F',
    'ardoise': '#3B4650',
  };

  /// The house green for an operator who never chose, and for a name this
  /// build has not heard of. A page renders in the wrong green far better
  /// than it fails to render.
  static String hex(String? name) => table[name] ?? table['foret']!;
}
