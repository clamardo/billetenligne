import 'dart:io';

import 'package:bel_api/src/infrastructure/web/artwork.g.dart';
import 'package:test/test.dart';

/// The API's copy of the artwork.
///
/// One folder of SVG under `packages/bel_design/assets/` feeds two consumers
/// with nothing in common — the Flutter apps and this server. Both embed it
/// rather than loading it, which means both can silently drift from the
/// folder. `bel_design`'s `art_test.dart` guards the other side.
String? _assets() {
  for (final up in ['..', '../..', '../../..', '.']) {
    final candidate = '$up/packages/bel_design/assets';
    if (Directory(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  group('artwork', () {
    test('the embedded copy matches the folder it was generated from', () {
      final assets = _assets();
      if (assets == null) {
        // Running from a tree without the design package. Nothing to compare
        // against, and failing here would fail for the wrong reason.
        return;
      }

      String minify(String svg) => svg
          .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
          .replaceAll(RegExp(r'>\s+<'), '><')
          .trim();

      final onDisk = {
        for (final dir in ['illustrations', 'scenes'])
          for (final file in Directory(
            '$assets/$dir',
          ).listSync().whereType<File>().where((f) => f.path.endsWith('.svg')))
            file.uri.pathSegments.last.replaceAll('.svg', ''): minify(
              file.readAsStringSync(),
            ),
      };

      // Named individually rather than reflected over, so adding a drawing
      // and forgetting to regenerate fails here rather than passing an
      // emptier comparison.
      expect(onDisk['journey'], Artwork.journey);
      expect(onDisk['no-trips'], Artwork.noTrips);
      expect(onDisk['search-empty'], Artwork.searchEmpty);
      expect(onDisk['route'], Artwork.route);
      expect(onDisk.length, greaterThanOrEqualTo(14));
    });

    test('every sentinel becomes a custom property, and none is left', () {
      // A sentinel that survives is bright magenta on a company's shop
      // window. The failure is loud, but only if somebody looks.
      for (final svg in [
        Artwork.journey,
        Artwork.noTrips,
        Artwork.searchEmpty,
        Artwork.route,
      ]) {
        final painted = Artwork.css(svg);
        expect(painted, isNot(contains('#FF00E')));
        expect(painted, contains('var(--art-'));
      }
    });

    test('the brand slot falls back to the operator accent', () {
      // On the storefront hero the accent is already the background, so the
      // hero overrides `--art-brand` and the drawing becomes a silhouette.
      // Everywhere else it has to resolve to the company's own colour.
      expect(Artwork.palette['#FF00E2'], 'var(--art-brand,var(--accent))');
    });

    test('the drawings are self-contained — no request leaves the page', () {
      // The whole reason this is inlined: a storefront must be a shop window
      // in the first response, and a follower is on a borrowed handset on 2G.
      for (final svg in [Artwork.journey, Artwork.route, Artwork.noTrips]) {
        // `xmlns="http://www.w3.org/2000/svg"` is a namespace name, not an
        // address — nothing fetches it. These are the things that would.
        expect(svg, isNot(contains('<image')));
        expect(svg, isNot(contains('xlink:href')));
        expect(svg, isNot(contains('url(http')));
        expect(svg, isNot(contains('@import')));
        expect(svg, isNot(contains('<script')));
      }
    });
  });
}
