/// Where a stranger goes to actually get the app, and where an operator goes
/// to run their company.
///
/// Three URLs that are **not** in the code because none of them is a property
/// of the software: a Play Store listing id belongs to an account nobody has
/// opened yet, and the console answers on `localhost:5000` for a developer and
/// on a real host in production.
///
/// **Empty is the supported state, and it changes what the page says.** There
/// is no listing today. A landing page that shows a *Get it on Google Play*
/// button pointing at nothing is worse than one that says the app is not out
/// yet: the first loses somebody at the first tap, the second gives them a
/// reason to come back. So the page asks whether a URL was configured rather
/// than rendering a button unconditionally, and the day the listings exist it
/// is two environment variables and no code — the same bargain
/// [AppLinkIdentity] makes for the claim files next door.
final class StoreListings {
  const StoreListings({
    this.playStoreUrl = '',
    this.appStoreUrl = '',
    this.consoleUrl = '',
  });

  factory StoreListings.from(Map<String, String> env) => StoreListings(
    playStoreUrl: (env['BEL__PLAYSTOREURL'] ?? '').trim(),
    appStoreUrl: (env['BEL__APPSTOREURL'] ?? '').trim(),
    consoleUrl: (env['BEL__CONSOLEURL'] ?? '').trim(),
  );

  /// `https://play.google.com/store/apps/details?id=…`, or blank.
  final String playStoreUrl;

  /// `https://apps.apple.com/…`, or blank.
  final String appStoreUrl;

  /// Where the operator console is served from, or blank when this deployment
  /// does not serve one.
  final String consoleUrl;

  /// True when at least one store can actually be linked to.
  bool get isPublished => playStoreUrl.isNotEmpty || appStoreUrl.isNotEmpty;
}
