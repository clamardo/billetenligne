import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../kilo_theme.dart';
import '../tokens/kilo_colors.dart';
import 'kilo_art.g.dart';

export 'kilo_art.g.dart' show KArt, KSceneArt;

/// The eight colours every piece of Kilo artwork is drawn against.
///
/// The SVGs under `assets/` are authored in a sentinel palette — eight
/// impossible magenta values — which this substitutes for real tokens when
/// the picture is painted. One file therefore renders correctly in light,
/// dark and plein soleil, and an operator's own accent can be pushed through
/// [brand] so a storefront hero is drawn in that operator's colour without a
/// second copy of the artwork.
@immutable
final class KArtPalette {
  const KArtPalette({
    required this.ink,
    required this.muted,
    required this.brand,
    required this.brandWash,
    required this.accent,
    required this.accentWash,
    required this.surface,
    required this.hairline,
  });

  factory KArtPalette.from(KiloColors c, {Color? brand, Color? accent}) =>
      KArtPalette(
        ink: c.contentPrimary,
        muted: c.contentSecondary,
        brand: brand ?? c.brandPrimary,
        brandWash: c.brandPrimarySoft,
        accent: accent ?? c.brandAccent,
        accentWash: c.brandAccentSoft,
        surface: c.surfaceRaised,
        hairline: c.borderSubtle,
      );

  factory KArtPalette.of(BuildContext context, {Color? brand, Color? accent}) =>
      KArtPalette.from(context.kilo.color, brand: brand, accent: accent);

  final Color ink;
  final Color muted;
  final Color brand;
  final Color brandWash;
  final Color accent;
  final Color accentWash;
  final Color surface;
  final Color hairline;

  static const _sentinels = [
    '#FF00E0',
    '#FF00E1',
    '#FF00E2',
    '#FF00E3',
    '#FF00E4',
    '#FF00E5',
    '#FF00E6',
    '#FF00E7',
  ];

  List<Color> get _colours => [
    ink,
    muted,
    brand,
    brandWash,
    accent,
    accentWash,
    surface,
    hairline,
  ];

  /// Substitutes the sentinel palette for this one.
  ///
  /// Memoised: `SvgPicture.string` re-parses on every rebuild, and an empty
  /// state inside a scrolling list rebuilds often.
  String paint(String svg) =>
      _cache.putIfAbsent('$hashCode:${svg.hashCode}', () {
        var out = svg;
        final colours = _colours;
        for (var i = 0; i < _sentinels.length; i++) {
          out = out.replaceAll(_sentinels[i], _hex(colours[i]));
        }
        return out;
      });

  static final Map<String, String> _cache = {};

  static String _hex(Color c) {
    String pair(double v) =>
        (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#${pair(c.r)}${pair(c.g)}${pair(c.b)}';
  }

  @override
  bool operator ==(Object other) =>
      other is KArtPalette &&
      other.ink == ink &&
      other.muted == muted &&
      other.brand == brand &&
      other.brandWash == brandWash &&
      other.accent == accent &&
      other.accentWash == accentWash &&
      other.surface == surface &&
      other.hairline == hairline;

  @override
  int get hashCode => Object.hash(
    ink,
    muted,
    brand,
    brandWash,
    accent,
    accentWash,
    surface,
    hairline,
  );
}

/// A spot illustration, for an empty, error or success state.
///
/// Always decorative: the state's heading and body carry the meaning, so this
/// is hidden from assistive technology unless a [semanticLabel] says
/// otherwise. A screen reader announcing "illustration of a bus" above the
/// sentence that already says there are no departures is noise.
class KIllustration extends StatelessWidget {
  const KIllustration(
    this.art, {
    super.key,
    this.size = 168,
    this.brand,
    this.accent,
    this.semanticLabel,
  });

  final KArt art;
  final double size;
  final Color? brand;
  final Color? accent;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = KArtPalette.of(context, brand: brand, accent: accent);
    return ExcludeSemantics(
      excluding: semanticLabel == null,
      child: SvgPicture.string(
        palette.paint(art.source),
        width: size,
        height: size * 0.75,
        semanticsLabel: semanticLabel,
      ),
    );
  }
}

/// Full-bleed hero artwork.
///
/// [cover] is an operator's own uploaded photograph. Where one exists it wins
/// — a real coach outside a real terminal beats any drawing we can make — and
/// the scene is what fills the space until they upload one, so the layout is
/// never designed around an image that might not arrive.
class KScene extends StatelessWidget {
  const KScene(
    this.scene, {
    super.key,
    this.height = 200,
    this.brand,
    this.accent,
    this.cover,
    this.overlay,
    this.child,
  });

  final KSceneArt scene;
  final double height;
  final Color? brand;
  final Color? accent;
  final ImageProvider<Object>? cover;

  /// Dim the artwork so text on top stays legible. Defaults to on whenever
  /// something is actually laid over the scene, and off when it is not — a
  /// hero with nothing on it should be the drawing, not a wash of it.
  final bool? overlay;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final palette = KArtPalette.of(context, brand: brand, accent: accent);
    final tint = brand ?? kilo.color.brandPrimary;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (cover != null)
            Image(image: cover!, fit: BoxFit.cover, excludeFromSemantics: true)
          else
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SvgPicture.string(
                palette.paint(scene.source),
                width: 800,
                height: 400,
              ),
            ),
          // Text sits on this, so the artwork is dimmed towards the bottom
          // rather than trusted to be dark enough on its own.
          if (overlay ?? (child != null || cover != null))
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tint.withValues(alpha: cover != null ? 0.24 : 0.0),
                    tint.withValues(alpha: cover != null ? 0.82 : 0.42),
                  ],
                  stops: const [0.35, 1],
                ),
              ),
            ),
          if (child != null) Positioned.fill(child: child!),
        ],
      ),
    );
  }
}
