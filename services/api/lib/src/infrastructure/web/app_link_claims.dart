import 'dart:convert';

/// The two files that let a link open the app instead of a page (ADR-0026).
///
/// `blt.cg/b/{token}` is one URL with two renderings: the app when it is
/// installed, the page when it is not. That is a deliberate refusal of the
/// alternative — an interstitial asking somebody to install something, in
/// front of a boarding pass, at a coach door.
///
/// Both platforms decide it the same way: the app declares the domain, the
/// domain declares the app, and the operating system checks the pair before it
/// will hand a link over. **The declaration has to be served by us**, which is
/// why these are here rather than in a static bucket somebody forgets to
/// deploy.
///
/// **Written against no signing certificate.** There is no Play Store listing
/// and no Apple team for this deployment yet, so the fingerprints and the team
/// id come from configuration and default to nothing — and *nothing is a
/// supported state*: the file is served, well-formed, with an empty
/// fingerprint list, so a deployment without credentials answers honestly
/// rather than 404ing and leaving somebody debugging DNS. The day the keys
/// exist it is two environment variables and no code.
///
/// The claim is scoped to `/b/*` on Android and iOS alike. The follower page
/// at `/t/` is deliberately *not* claimed: it is opened by strangers with no
/// account and no app, and an operating system that offered to install one
/// would be answering a question nobody asked.
final class AppLinkIdentity {
  const AppLinkIdentity({
    required this.androidPackage,
    required this.androidFingerprints,
    required this.appleAppId,
  });

  /// Read from the environment, and blank is supported: a deployment with no
  /// store listing serves a well-formed file with nothing in it rather than a
  /// 404 that sends somebody looking at DNS.
  factory AppLinkIdentity.from(Map<String, String> env) => AppLinkIdentity(
    androidPackage:
        env['BEL__ANDROIDPACKAGE'] ?? 'cg.billetenligne.bel_traveller',
    androidFingerprints: [
      for (final print in (env['BEL__ANDROIDFINGERPRINTS'] ?? '').split(','))
        if (print.trim().isNotEmpty) print.trim().toUpperCase(),
    ],
    // `TEAMID.bundleid`. There is no Apple team for this deployment yet.
    appleAppId: env['BEL__APPLEAPPID'] ?? '',
  );

  final String androidPackage;
  final List<String> androidFingerprints;
  final String appleAppId;

  /// True when a store listing actually exists. The files are served either
  /// way; this is what the health of the claim depends on.
  bool get isClaimed => androidFingerprints.isNotEmpty || appleAppId.isNotEmpty;
}

abstract final class AppLinkClaims {
  /// `https://blt.cg/.well-known/assetlinks.json` — Android App Links.
  ///
  /// One statement per signing certificate, because a release build and an
  /// upload key are two fingerprints for one app and forgetting the second is
  /// how links stop opening the day a store re-signs the bundle.
  static String assetLinks({
    required String androidPackage,
    required List<String> fingerprints,
  }) => const JsonEncoder.withIndent('  ').convert([
    {
      'relation': ['delegate_permission/common.handle_all_urls'],
      'target': {
        'namespace': 'android_app',
        'package_name': androidPackage,
        'sha256_cert_fingerprints': fingerprints,
      },
    },
  ]);

  /// `https://blt.cg/.well-known/apple-app-site-association` — Universal
  /// Links.
  ///
  /// Served as JSON with **no `.json` extension and no signature**, which is
  /// what Apple has required since iOS 9 and is the single most common way
  /// this file is got wrong.
  static String appleAppSiteAssociation({required String appleAppId}) =>
      const JsonEncoder.withIndent('  ').convert({
        'applinks': {
          'details': [
            {
              'appIDs': [appleAppId],
              'components': [
                {'/': '/b/*', 'comment': 'a ticket, opened in the app'},
              ],
            },
          ],
        },
      });
}
