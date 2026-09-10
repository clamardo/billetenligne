/// The cloth the app is woven from, as a CSS background for a web page.
///
/// The apps draw `KPatternMotif.kuba` behind their headers and their quieter
/// screens: nested chevrons that invert from tile to tile, so each one keys
/// into its neighbours. It is the one mark that makes a BilletEnLigne screen
/// recognisable from across a room, and until this file existed **it stopped
/// at the edge of the apps** — the pages a traveller actually meets first,
/// arriving from a QR on the side of a coach, were a white sheet with a green
/// rectangle on it.
///
/// The geometry is a transcription of `KilaPattern._kuba`, not an
/// approximation: tile 34, insets 0.20/0.40/0.60, height 0.62 of the width,
/// the keying dot at ±0.3 of the tile. Two tiles square, because one tile
/// cannot express the inversion that is the whole motif — a field of chevrons
/// all pointing the same way reads as bunting.
///
/// Inlined as a `data:` URI rather than served as a file: the reader is on a
/// phone on a 2G connection and half of them arrived from a link in WhatsApp,
/// so the page is one request or it is nothing (the same rule the landing and
/// follower pages already keep).
abstract final class Weave {
  /// A `background-image` value drawing the weave in [ink].
  ///
  /// [ink] is any CSS colour the URI can carry literally — a hex is safest,
  /// since `#` has to be escaped and `rgba(...)` brings commas and brackets
  /// that some proxies mangle. Control the strength with [opacity] rather
  /// than by making the colour transparent.
  ///
  /// [strokeWidth] is in the tile's own 68-unit space. The default draws the
  /// hairline the landing page wants across a whole screen; a band 20 mm tall
  /// on a printed ticket needs a heavier line, because the tile there is a
  /// tenth the size and the stroke scales down with it.
  static String image(
    String ink, {
    double opacity = 0.06,
    double strokeWidth = 1.4,
  }) {
    // Not pre-encoded: `_uri` below escapes the `#`, and doing it twice
    // produces `%2523` and a tile that never loads.
    final hex = ink;
    final svg =
        '<svg xmlns="http://www.w3.org/2000/svg" width="68" height="68" '
        'viewBox="0 0 68 68" opacity="$opacity">'
        '<g fill="none" stroke="$hex" stroke-width="$strokeWidth" '
        'stroke-linecap="round" stroke-linejoin="round">'
        '<path d="$_chevrons"/></g>'
        '<g fill="$hex">$_dots</g></svg>';
    return "url('data:image/svg+xml;utf8,${_uri(svg)}')";
  }

  /// The three nested chevrons of each of the four cells, alternating.
  static const _chevrons =
      'M10.20 19.11L17.00 14.89L23.80 19.11 '
      'M3.40 21.22L17.00 12.78L30.60 21.22 '
      'M-3.40 23.32L17.00 10.68L37.40 23.32 '
      'M44.20 14.89L51.00 19.11L57.80 14.89 '
      'M37.40 12.78L51.00 21.22L64.60 12.78 '
      'M30.60 10.68L51.00 23.32L71.40 10.68 '
      'M10.20 48.89L17.00 53.11L23.80 48.89 '
      'M3.40 46.78L17.00 55.22L30.60 46.78 '
      'M-3.40 44.68L17.00 57.32L37.40 44.68 '
      'M44.20 53.11L51.00 48.89L57.80 53.11 '
      'M37.40 55.22L51.00 46.78L64.60 55.22 '
      'M30.60 57.32L51.00 44.68L71.40 57.32';

  static const _dots =
      '<circle cx="17.00" cy="6.80" r="1.5"/>'
      '<circle cx="51.00" cy="27.20" r="1.5"/>'
      '<circle cx="17.00" cy="61.20" r="1.5"/>'
      '<circle cx="51.00" cy="40.80" r="1.5"/>';

  /// Only what a `url(...)` in a stylesheet cannot carry raw. Percent-encoding
  /// the whole string would triple the size of every page this appears on.
  ///
  /// The double quotes around the SVG's own attributes are **left alone**, and
  /// the `url()` is wrapped in single ones. Swapping them the other way round
  /// closes the CSS string at the first attribute and the browser resolves the
  /// whole declaration to `none` — a tile that silently does not exist, which
  /// is exactly the kind of failure a stylesheet reports nowhere.
  static String _uri(String svg) => svg
      .replaceAll('%', '%25')
      .replaceAll('#', '%23')
      .replaceAll('<', '%3C')
      .replaceAll('>', '%3E');
}
