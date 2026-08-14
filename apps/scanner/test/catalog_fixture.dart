import 'package:bel_localization/bel_localization.dart';

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
