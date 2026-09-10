import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The console rail must survive a laptop.
///
/// It carries eleven destinations and a foot of controls, and at 900 px of
/// height it overflowed by 36 px — the yellow-and-black band across the
/// bottom of the walkthrough screenshot, and a last tab nobody could reach.
/// A `trailing: Expanded` inside `NavigationRail` is the cause: the rail
/// lays its column out with `IntrinsicHeight`, so `Expanded` is handed
/// negative space the moment the destinations alone are taller than the
/// viewport.
///
/// Asserted on the source rather than by pumping the shell: the shell needs
/// a signed-in workspace, a gateway and a catalog to build at all, and this
/// is a layout contract, not a behaviour. The guard is that the three
/// widgets that make the rail scrollable are still wrapped around it.
void main() {
  test('the rail scrolls rather than overflowing on a short screen', () {
    final source = File(
      'lib/src/presentation/widgets/console_shell.dart',
    ).readAsStringSync();

    final rail = source.indexOf('NavigationRail(');
    expect(rail, greaterThan(0));

    for (final wrapper in const [
      'LayoutBuilder(',
      'SingleChildScrollView(',
      'ConstrainedBox(',
      'minHeight: constraints.maxHeight',
      'IntrinsicHeight(',
    ]) {
      final at = source.indexOf(wrapper);
      expect(at, greaterThan(0), reason: '$wrapper is gone from the rail');
      expect(
        at,
        lessThan(rail),
        reason: '$wrapper must wrap the rail, not sit after it',
      );
    }
  });
}
