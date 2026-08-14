import 'dart:io';
import 'dart:ui' as ui;

import 'package:bel_console/src/application/console_workspace.dart';
import 'package:bel_console/src/presentation/app.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog_fixture.dart';
import '../scripted_console.dart';

/// Writes the console's own screens to `build/design/` so they can be looked
/// at, at the width an agency laptop actually has.
///
/// Asserts nothing, like the other contact sheets. The console is the surface
/// an operator spends their whole working day in, and it is the one nobody
/// has seen: every screen here was written blind and reviewed by reading it.
void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  /// Pumps the whole app — rail, header and all — because the rail is most of
  /// what the screen looks like and shooting a bare screen would flatter it.
  Future<void> shootSection(
    WidgetTester tester,
    String name,
    ScriptedConsole gateway,
    ConsoleSection section, {
    KiloBrightness brightness = KiloBrightness.light,
  }) async {
    const size = Size(1280, 820);
    const ratio = 2.0;
    tester.view
      ..physicalSize = size * ratio
      ..devicePixelRatio = ratio;
    addTearDown(tester.view.reset);

    final workspace = ConsoleWorkspace(gateway: gateway);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MediaQuery(
          data: MediaQueryData(
            platformBrightness: brightness == KiloBrightness.dark
                ? Brightness.dark
                : Brightness.light,
          ),
          child: ConsoleApp(catalog: catalog, workspace: workspace),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Opened through the workspace rather than by tapping the rail: a shot
    // that fails because a label moved is a shot nobody re-runs.
    if (section != ConsoleSection.today) {
      workspace.openSection(section);
      await tester.pumpAndSettle();
    }

    // The same alternation the other harnesses use: flutter_svg decodes off
    // the fake async zone, so a settle loop would spin forever on artwork.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 32));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data;
    });

    final dir = Directory('build/design')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  // Everything on the rail, because the rail is drawn from capabilities and a
  // shot of a half-empty one is a shot of a vendor's console, not an owner's.
  ScriptedConsole owner() => ScriptedConsole(
    capabilities: const [
      'booking.read',
      'booking.sell',
      'fleet.manage',
      'route.manage',
      'departure.manage',
      'refund.approve',
      'payout.read',
      'vitrine.manage',
      'policy.manage',
      'protection.manage',
    ],
  );

  // A day with coaches on it. The empty state is worth a shot of its own,
  // but shooting only that would review a screen nobody works in.
  ScriptedConsole busyDay() => owner()
    ..boardList = [
      _board('dep-1', 5, sold: 49, held: 0, available: 0),
      _board('dep-2', 8, sold: 31, held: 4, available: 17),
      _board(
        'dep-3',
        11,
        sold: 12,
        held: 2,
        available: 38,
        disruption: DisruptionDto(
          id: 'dis-1',
          kind: DisruptionKind.breakdownEnRoute,
          cause: DisruptionCause.mechanical,
          declaredAt: DateTime.utc(2026, 8, 10, 11, 40),
          marksInvoluntary: true,
        ),
      ),
      _board('dep-4', 14, sold: 3, held: 0, available: 49, status: 'cancelled'),
    ];

  testWidgets("the dispatcher's day", (tester) async {
    await shootSection(
      tester,
      'console-today-light',
      busyDay(),
      ConsoleSection.today,
    );
  });

  testWidgets("the dispatcher's day, before anything is scheduled", (
    tester,
  ) async {
    await shootSection(
      tester,
      'console-today-empty',
      owner(),
      ConsoleSection.today,
    );
  });

  testWidgets("the dispatcher's day, dark", (tester) async {
    await shootSection(
      tester,
      'console-today-dark',
      busyDay(),
      ConsoleSection.today,
      brightness: KiloBrightness.dark,
    );
  });

  testWidgets('the fleet, with coaches on it', (tester) async {
    final gateway = owner()
      ..vehicleList = const [
        VehicleDto(
          id: 'v-1',
          registration: '01-AB-42',
          layoutId: 'lay-1',
          layoutName: 'Yutong 52 places',
          capacity: 52,
          status: 'active',
          sellable: true,
          model: 'Yutong ZK6118',
          amenities: ['clim', 'wifi'],
        ),
        VehicleDto(
          id: 'v-2',
          registration: '02-CD-07',
          layoutId: 'lay-1',
          layoutName: 'Yutong 52 places',
          capacity: 49,
          status: 'maintenance',
          sellable: false,
          nickname: 'La Doyenne',
          model: 'Higer KLQ6122',
        ),
        VehicleDto(
          id: 'v-3',
          registration: '03-EF-19',
          layoutId: 'lay-2',
          layoutName: 'Coaster 29 places',
          capacity: 29,
          status: 'out_of_service',
          sellable: false,
          model: 'Toyota Coaster',
        ),
      ];
    await shootSection(
      tester,
      'console-fleet-light',
      gateway,
      ConsoleSection.fleet,
    );
  });

  testWidgets('the fleet, with nothing on it', (tester) async {
    await shootSection(
      tester,
      'console-fleet-empty',
      owner(),
      ConsoleSection.fleet,
    );
  });

  testWidgets('the counter, before anybody has typed', (tester) async {
    await shootSection(
      tester,
      'console-counter-light',
      owner(),
      ConsoleSection.counter,
    );
  });

  testWidgets('the vitrine', (tester) async {
    await shootSection(
      tester,
      'console-vitrine-light',
      owner(),
      ConsoleSection.vitrine,
    );
  });
}

DepartureBoardDto _board(
  String id,
  int hour, {
  required int sold,
  required int held,
  required int available,
  String status = 'scheduled',
  DisruptionDto? disruption,
}) => DepartureBoardDto(
  id: id,
  routeCode: 'BZV-PNR',
  departsAt: DateTime.utc(2026, 8, 10, hour),
  status: status,
  capacity: 49,
  sold: sold,
  held: held,
  available: available,
  vehicle: '01-AB-42',
  disruption: disruption,
);
