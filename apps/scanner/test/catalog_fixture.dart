import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_scanner/src/presentation/l10n.dart';
import 'package:flutter/material.dart';

/// Loads the catalog from disk for tests.
///
/// **The source tree, not the bundle.** A widget test has a filesystem and no
/// asset bundle worth mocking, and the bundle is flattened on the way in —
/// `pages/travel.yaml` arriving as `fr__pages__travel.yaml`, because a Flutter
/// `assets:` entry names one directory and does not recurse. Reading the
/// source is the same YAML by a shorter road, and `i18n_freshness_test` is
/// what guarantees the bundled copy has not drifted from it.
Future<TranslationCatalog> loadTestCatalog() async =>
    CatalogLoader.fromDirectory('../../packages/bel_localization/i18n');

/// Mounts one screen the way the app mounts it.
///
/// Every string a conductor sees now comes from the catalog, so a screen
/// pumped without a `Localized` ancestor no longer renders French — it
/// asserts. That is the correct trade: the alternative was a hundred literals
/// that could never be anything but French.
///
/// [language] is what makes the same test readable twice, which is the only
/// honest way to check a translation exists.
Widget scannerHarness(
  TranslationCatalog catalog,
  Widget screen, {
  String language = 'fr',
}) => Localized(
  catalog: catalog,
  initialLanguage: language,
  child: MaterialApp(
    // `plein soleil` here too, because it is the theme the app ships with and
    // a test that renders in another one is testing a screen nobody sees.
    theme: KiloTheme.materialTheme(brightness: KiloBrightness.pleinSoleil),
    home: screen,
  ),
);
