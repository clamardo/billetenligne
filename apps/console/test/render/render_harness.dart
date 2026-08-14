import 'dart:io';
import 'dart:ui' as ui;

import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders a widget to a real PNG on disk.
///
/// Not a golden test — nothing here asserts. This exists so the design can be
/// *looked at*: a component written blind and reviewed only by reading its
/// source is a component nobody has seen, and that is how a product ends up
/// flat while every test passes.
///
/// Output goes under `build/design/`, which is gitignored.
Future<void> shoot(
  WidgetTester tester,
  String name,
  Widget child, {
  Size size = const Size(420, 900),
  KiloBrightness brightness = KiloBrightness.light,
  double pixelRatio = 2,
}) async {
  tester.view
    ..physicalSize = size * pixelRatio
    ..devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);

  final key = GlobalKey();

  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KiloTheme.materialTheme(brightness: brightness),
        home: child,
      ),
    ),
  );
  // Not `pumpAndSettle`: flutter_svg decodes off the test's fake async zone,
  // so a settle loop spins forever waiting on work the test clock will never
  // advance. Pump and give the real event loop a slice, alternately, until
  // the pictures have arrived.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 32));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data;
  });

  final dir = Directory('build/design')..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}
