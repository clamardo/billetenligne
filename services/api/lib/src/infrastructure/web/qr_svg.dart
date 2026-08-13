import 'package:qr/qr.dart';

/// A QR code as inline SVG, drawn on the server (ADR-0026).
///
/// The traveller app draws its QR with `qr_flutter` on a canvas it owns. The
/// link page has no canvas and no Flutter, and the person reading it is at a
/// coach door — so the code has to be **in the response**, not fetched by a
/// script and not linked to an image endpoint.
///
/// Three decisions, and each of them is about the handset holding it up:
///
///   * **SVG rather than a PNG data URI.** A QR is a grid of squares, which is
///     what a vector is good at: it is a couple of kilobytes, it is sharp at
///     whatever size the browser lays it out at, and generating a raster on
///     the server would mean an image codec in the API for one screen.
///   * **Black on white, always.** A dark-theme QR is a QR many cheap scanners
///     refuse, and the conductor's handset is exactly that scanner. The card
///     around it is white in both themes for the same reason.
///   * **Error correction M and a four-module quiet zone**, matching the app's
///     own ticket exactly (ADR-0007). Higher correction is denser, and density
///     is what kills a scan on a cracked screen in the sun; no quiet zone is
///     what leaves a decoder nothing to lock onto.
///
/// One `<path>` for every dark module rather than one `<rect>` each: a version
/// 6 code is about a thousand modules, and a thousand elements is a document a
/// cheap browser lays out slowly for no benefit.
abstract final class QrSvg {
  /// The quiet zone the specification asks for, in modules.
  static const int quietZone = 4;

  /// [payload] as an `<svg>` element, sized by CSS rather than by attribute so
  /// the page decides how big a ticket is.
  ///
  /// [label] becomes the accessible name — a screen reader announcing "code
  /// QR, siège 12A" is the difference between a passenger finding their own
  /// seat's code among three and guessing.
  static String render(String payload, {required String label}) {
    final image = QrImage(
      QrCode.fromData(data: payload, errorCorrectLevel: QrErrorCorrectLevel.M),
    );

    final side = image.moduleCount + quietZone * 2;
    final path = StringBuffer();

    for (var row = 0; row < image.moduleCount; row++) {
      // Runs, not modules: a row of eight dark squares is one rectangle in the
      // path rather than eight, which roughly halves the bytes on the wire.
      var start = -1;
      for (var col = 0; col <= image.moduleCount; col++) {
        final dark = col < image.moduleCount && image.isDark(row, col);
        if (dark && start < 0) start = col;
        if (!dark && start >= 0) {
          path.write(
            'M${start + quietZone} ${row + quietZone}'
            'h${col - start}v1h-${col - start}z',
          );
          start = -1;
        }
      }
    }

    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $side $side" '
        'role="img" aria-label="${_attr(label)}" class="qr">'
        '<rect width="$side" height="$side" fill="#fff"/>'
        '<path fill="#000" d="$path"/>'
        '</svg>';
  }

  static String _attr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
