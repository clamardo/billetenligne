import 'package:bel_contracts/bel_contracts.dart';

/// An operator's storefront: what they configure, and what a stranger sees.
///
/// One port for both directions, and the two callers could hardly be further
/// apart — an operator's own staff on `/console/v1`, an anonymous traveller on
/// `/public/v1`. They are one port because they are one *record*, and the
/// live preview in the editor is only honest if the thing it previews is the
/// thing the public page reads (`03-operator-lifecycle.md` §2.4).
///
/// Every scope boundary is in the adapter, not here: [forOperator] and [save]
/// run under the tenant's own scope, [byCode] under the public one, and no
/// method takes a tenant id it could be lied to about.
abstract interface class Storefronts {
  /// The operator's own vitrine, for the editor.
  Future<VitrineDto?> forOperator(String operatorId);

  /// Saves what the operator changed, and answers with the stored row.
  ///
  /// Answers with what was *stored* rather than echoing the request, because
  /// the accent and the pattern are both bounded — a value this layer refuses
  /// must come back as the value that is actually live, not as the one that
  /// was rejected.
  Future<VitrineDto?> save({
    required String operatorId,
    required SaveVitrineRequest edit,
  });

  /// The public page for `blt.cg/o/<code>`.
  ///
  /// Null for an operator who is not selling. That is deliberate and it is not
  /// a 404 for tidiness: a suspended operator's storefront is a page that
  /// invites somebody to book from a company we have stopped, and a
  /// storefront that outlives the right to sell is worse than a dead link.
  Future<StorefrontDto?> byCode(String code);
}
