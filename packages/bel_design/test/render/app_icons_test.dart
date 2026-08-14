import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// Puts the four brand marks on the four launchers.
///
/// The marks have been SVGs in `brand/icons/` since the brand was drawn, and
/// every app has shipped Flutter's default blue-and-white beachball — which
/// is what an operator's customers would have been asked to find on a home
/// screen full of other apps.
///
/// **Rasterised here rather than by a tool nobody has.** ImageMagick,
/// `rsvg-convert` and the icon generators all mean a second thing to install
/// and a second renderer whose output nobody compares to the app's own. This
/// repository already draws these files: `flutter_svg` renders the same
/// artwork on every screen, and a `RepaintBoundary` turns what it drew into
/// pixels. The icon on the launcher is then, by construction, the icon the
/// app draws.
///
/// Writing is opt-in — `BEL_WRITE_ICONS=1` — so an ordinary `flutter test`
/// changes nothing on disk. Without it every file is rendered anyway and
/// **compared to what is committed**, which is what keeps the two in step: an
/// edited mark that nobody re-rendered fails here rather than shipping a home
/// screen that disagrees with the brand.
///
/// The comparison is a tolerance rather than a byte match, and that is
/// deliberate. Skia's antialiasing moves by a shade between engine versions,
/// so `git diff --exit-code` on a PNG would turn every Flutter upgrade into a
/// red build about an icon nobody touched. A changed *drawing* moves whole
/// regions, not edge pixels, and a mean error of six counts as changed while
/// a re-rendered identical mark does not.
void main() {
  final root = _repositoryRoot();
  final write = Platform.environment['BEL_WRITE_ICONS'] == '1';

  for (final app in _apps) {
    testWidgets('${app.name} — the mark, at every size a launcher asks for', (
      tester,
    ) async {
      final svg = File(
        '${root.path}/brand/icons/${app.name}.svg',
      ).readAsStringSync();
      final background = _backgroundOf(svg);
      // The adaptive icon's two layers. Android draws the foreground over a
      // flat colour and masks the pair, so the background rectangle has to
      // come *out* of the artwork — leave it in and a launcher that crops to
      // a circle crops a square that was already there.
      final foreground = svg.replaceFirst(
        RegExp(r'<rect width="108" height="108" fill="#[0-9A-Fa-f]{6}"/>'),
        '',
      );
      expect(
        foreground,
        isNot(contains('<rect width="108" height="108" fill="$background"/>')),
        reason: 'the background rectangle did not come out of the foreground',
      );

      final dir = Directory('${root.path}/apps/${app.name}');
      expect(dir.existsSync(), isTrue, reason: 'no such app');

      if (app.android) {
        const res = 'android/app/src/main/res';
        for (final entry in _densities.entries) {
          final density = entry.key;
          final scale = entry.value;
          await _shoot(
            tester,
            svg,
            (48 * scale).round(),
            into: '${dir.path}/$res/mipmap-$density/ic_launcher.png',
            write: write,
          );
          await _shoot(
            tester,
            foreground,
            (108 * scale).round(),
            into: '${dir.path}/$res/mipmap-$density/ic_launcher_foreground.png',
            write: write,
          );
        }
        if (write) {
          _writeAdaptive(dir.path, res, background);
        }
      }

      if (app.ios) {
        final set = Directory(
          '${dir.path}/ios/Runner/Assets.xcassets/AppIcon.appiconset',
        );
        expect(set.existsSync(), isTrue);
        for (final file in set.listSync().whereType<File>()) {
          final name = file.uri.pathSegments.last;
          final side = _iosSideOf(name);
          if (side == null) continue;
          await _shoot(
            tester,
            svg,
            side,
            into: file.path,
            write: write,
            // Apple refuses an icon with an alpha channel at submission —
            // the one platform-specific thing about these files, and the one
            // that is found at the very end.
            opaque: true,
          );
        }
      }

      if (app.web) {
        for (final size in const [192, 512]) {
          for (final name in ['Icon-$size', 'Icon-maskable-$size']) {
            await _shoot(
              tester,
              svg,
              size,
              into: '${dir.path}/web/icons/$name.png',
              write: write,
            );
          }
        }
        // Maskable and ordinary are the same image on purpose: this mark was
        // drawn on Android's 108-unit canvas with everything inside the safe
        // zone, so there is nothing for a mask to take.
        await _shoot(
          tester,
          svg,
          16,
          into: '${dir.path}/web/favicon.png',
          write: write,
        );
      }
    });
  }
}

final class _App {
  const _App(
    this.name, {
    this.android = false,
    this.ios = false,
    this.web = false,
  });

  final String name;
  final bool android;
  final bool ios;
  final bool web;
}

const _apps = [
  _App('traveller', android: true, ios: true),
  _App('scanner', android: true, ios: true),
  _App('console', web: true),
  _App('admin', web: true),
];

/// mdpi is the unit. Every other density is a multiple of it, and Android
/// picks by device rather than by name.
const _densities = {
  'mdpi': 1.0,
  'hdpi': 1.5,
  'xhdpi': 2.0,
  'xxhdpi': 3.0,
  'xxxhdpi': 4.0,
};

/// `Icon-App-83.5x83.5@2x.png` is 167 pixels. The point size can be
/// fractional; the file never is.
int? _iosSideOf(String name) {
  final match = RegExp(
    r'Icon-App-([0-9.]+)x[0-9.]+@([0-9]+)x\.png',
  ).firstMatch(name);
  if (match == null) return null;
  return (double.parse(match.group(1)!) * int.parse(match.group(2)!)).round();
}

/// The flat colour behind the mark, which is also the adaptive icon's
/// background layer.
String _backgroundOf(String svg) {
  final match = RegExp(
    r'<rect width="108" height="108" fill="(#[0-9A-Fa-f]{6})"/>',
  ).firstMatch(svg);
  if (match == null) throw StateError('no background rectangle in the mark');
  return match.group(1)!;
}

/// Renders [svg] at [side] pixels square and, if asked, writes it.
Future<void> _shoot(
  WidgetTester tester,
  String svg,
  int side, {
  required String into,
  required bool write,
  bool opaque = false,
}) async {
  tester.view
    ..physicalSize = Size(side.toDouble(), side.toDouble())
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: SvgPicture.string(
        svg,
        width: side.toDouble(),
        height: side.toDouble(),
      ),
    ),
  );
  // Not `pumpAndSettle`: flutter_svg decodes off the test's fake async zone,
  // so a settle loop spins forever waiting on work the test clock will never
  // advance.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pump();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    expect(image.width, side);
    final format = opaque ? ui.ImageByteFormat.rawRgba : ui.ImageByteFormat.png;
    final data = await image.toByteData(format: format);
    image.dispose();
    return data!.buffer.asUint8List();
  });

  final png = opaque ? _opaquePng(bytes!, side) : bytes!;
  // Cheap proof it drew something: a mark that failed to parse renders as an
  // empty box, and an empty box is a small file.
  expect(png.length, greaterThan(200), reason: '$into is empty');

  final file = File(into);
  if (write) {
    file
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png);
    return;
  }

  expect(
    file.existsSync(),
    isTrue,
    reason: '$into was never rendered — BEL_WRITE_ICONS=1 flutter test',
  );
  final drift = await tester.runAsync(
    () => _difference(png, file.readAsBytesSync()),
  );
  expect(
    drift,
    lessThan(6),
    reason:
        '$into no longer matches the mark it came from '
        '(mean error $drift) — BEL_WRITE_ICONS=1 flutter test',
  );
}

/// Mean absolute difference per channel between two PNGs of the same size.
Future<double> _difference(Uint8List a, Uint8List b) async {
  final left = await _pixels(a);
  final right = await _pixels(b);
  if (left.length != right.length) return 255;
  var total = 0;
  for (var i = 0; i < left.length; i++) {
    total += (left[i] - right[i]).abs();
  }
  return total / left.length;
}

Future<Uint8List> _pixels(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  return data!.buffer.asUint8List();
}

/// The adaptive icon, which is the only part of this that is markup.
void _writeAdaptive(String app, String res, String background) {
  File('$app/$res/mipmap-anydpi-v26/ic_launcher.xml')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by packages/bel_design/test/render/app_icons_test.dart. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
  File('$app/$res/values/ic_launcher_background.xml')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by packages/bel_design/test/render/app_icons_test.dart. -->
<resources>
    <color name="ic_launcher_background">$background</color>
</resources>
''');
}

/// A PNG with no alpha channel at all.
///
/// `toByteData(format: png)` always writes RGBA, and App Store validation
/// refuses an icon that has an alpha channel — a rejection that arrives at
/// submission, months after the file was made, with a message about a
/// transparency nobody put there. So the iOS set is written from raw pixels
/// as PNG colour type 2: three bytes to the pixel, one filter byte to the
/// scanline, and zlib doing the compression it exists for.
Uint8List _opaquePng(Uint8List rgba, int side) {
  final raw = Uint8List(side * (side * 3 + 1));
  var at = 0;
  for (var y = 0; y < side; y++) {
    raw[at++] = 0; // filter: none
    for (var x = 0; x < side; x++) {
      final from = (y * side + x) * 4;
      raw[at++] = rgba[from];
      raw[at++] = rgba[from + 1];
      raw[at++] = rgba[from + 2];
    }
  }

  final png = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(
      _chunk('IHDR', [
        ..._be32(side), ..._be32(side),
        8, // bits per channel
        2, // truecolour, no alpha
        0, 0, 0, // deflate, no filter, no interlace
      ]),
    )
    ..add(_chunk('IDAT', ZLibEncoder().convert(raw)))
    ..add(_chunk('IEND', const []));
  return png.toBytes();
}

List<int> _chunk(String type, List<int> data) {
  final head = [...type.codeUnits, ...data];
  return [..._be32(data.length), ...head, ..._be32(_crc32(head))];
}

List<int> _be32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}();

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// The repository root, from wherever `flutter test` was started.
Directory _repositoryRoot() {
  var dir = Directory.current;
  while (!Directory('${dir.path}/brand/icons').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('no repository root');
    dir = parent;
  }
  return dir;
}
