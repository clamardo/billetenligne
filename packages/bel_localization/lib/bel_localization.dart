/// BilletEnLigne translation catalog (ADR-0008).
///
/// One YAML catalog serves every surface *and* the server: the Flutter apps
/// load it from the asset bundle, the API and workers load it from disk, and
/// an SMS, a push notification, a PDF ticket and a screen all draw from the
/// same reviewed French sentence.
///
/// French is the source and fallback language. Lookups never throw.
library;

export 'src/catalog_loader_io.dart';
export 'src/catalog_translator.dart';
export 'src/interpolation.dart';
export 'src/plural_rules.dart';
export 'src/supported_language.dart';
export 'src/translation_catalog.dart';
