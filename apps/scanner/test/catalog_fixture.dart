import 'package:bel_localization/bel_localization.dart';

/// Loads the catalog from disk for tests.
///
/// The app loads the same YAML from the asset bundle at runtime; a widget test
/// has a filesystem and no bundle worth mocking, so it reads the source
/// directly. Same files either way — `i18n_freshness_test` is what guarantees
/// the bundled copy has not drifted from them.
Future<TranslationCatalog> loadTestCatalog() async =>
    CatalogLoader.fromDirectory('assets/i18n');
