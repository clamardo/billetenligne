import 'dart:io';
import 'dart:ui' as ui;

import 'package:bel_admin/src/application/admin_workspace.dart';
import 'package:bel_admin/src/presentation/app.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog_fixture.dart';
import '../scripted_admin.dart';

/// Writes the back office's screens to `build/design/` so they can be looked
/// at, at the width the people who use it actually have.
///
/// Asserts nothing, like the console's. This is the surface where somebody
/// suspends a company and approves other people's money, and until now it was
/// reviewed entirely by reading the widgets that build it.
void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  Future<void> shootSection(
    WidgetTester tester,
    String name,
    ScriptedAdmin gateway,
    AdminSection section, {
    KiloBrightness brightness = KiloBrightness.light,
  }) async {
    const size = Size(1440, 900);
    const ratio = 2.0;
    tester.view
      ..physicalSize = size * ratio
      ..devicePixelRatio = ratio;
    addTearDown(tester.view.reset);

    final workspace = AdminWorkspace(gateway: gateway);
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
          child: AdminApp(catalog: catalog, workspace: workspace),
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (section != AdminSection.queue) {
      workspace.openSection(section);
      await tester.pumpAndSettle();
    }

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

  ScriptedAdmin staff() => ScriptedAdmin(
    capabilities: const [
      'platform.operator.review',
      'platform.operator.suspend',
      'platform.operator.offboard',
      'platform.payment.reconcile',
    ],
  );

  testWidgets('the queue, with dossiers waiting', (tester) async {
    final gateway = staff()
      ..roster = [
        adminOperator(),
        adminOperator(
          status: 'active',
          riskBand: 'elevated',
          riskReasons: const ['chargeback_rate', 'new_operator'],
        ),
        adminOperator(status: 'suspended', commissionBps: 800),
      ];
    await shootSection(
      tester,
      'admin-queue-light',
      gateway,
      AdminSection.queue,
    );
  });

  testWidgets('the queue, with nothing waiting', (tester) async {
    await shootSection(
      tester,
      'admin-queue-empty',
      staff(),
      AdminSection.queue,
    );
  });

  testWidgets('the payouts nobody has approved yet', (tester) async {
    final gateway = staff()
      ..runs = [payoutRun(), payoutRun(reference: 'PAY-2026-32')];
    await shootSection(
      tester,
      'admin-payouts-light',
      gateway,
      AdminSection.payouts,
    );
  });

  testWidgets('the payments that did not reconcile', (tester) async {
    final gateway = staff()..queue = [unresolvedPayment()];
    await shootSection(
      tester,
      'admin-payments-light',
      gateway,
      AdminSection.payments,
    );
  });

  testWidgets('the queue, dark', (tester) async {
    final gateway = staff()..roster = [adminOperator()];
    await shootSection(
      tester,
      'admin-queue-dark',
      gateway,
      AdminSection.queue,
      brightness: KiloBrightness.dark,
    );
  });
}
