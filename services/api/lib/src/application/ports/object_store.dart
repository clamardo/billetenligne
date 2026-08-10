/// Where a file lives once we have accepted it.
final class StoredObject {
  const StoredObject({
    required this.key,
    required this.contentType,
    required this.bytes,
  });

  /// The path inside the container — `operators/<id>/logo.png`. Stored in the
  /// database rather than a URL, because a URL embeds the account, the
  /// container and the CDN in front of it, and every one of those changes
  /// without the file changing.
  final String key;

  final String contentType;
  final int bytes;
}

/// Files, behind one port.
///
/// Two very different callers eventually share this, and the difference is the
/// reason [publicUrl] and [signedUrl] are separate methods rather than one
/// with a flag:
///
///   * an operator's **logo** is on a public storefront, printed on posters
///     and read by every traveller. A signed URL for it would expire in a
///     cached page and break an image nobody was protecting;
///   * a **KYB document** is a scan of somebody's registration certificate. It
///     must never be readable by URL alone, and a short-lived signature is the
///     whole control.
///
/// Making that a boolean would let one wrong argument publish a passport.
abstract interface class ObjectStore {
  /// Writes, overwriting whatever was at [key].
  ///
  /// Overwriting on purpose: the key is derived from the operator and the kind
  /// of asset, so a second logo replaces the first. Versioned keys would leave
  /// the old file readable forever by anyone who had ever seen its URL.
  Future<StoredObject> put({
    required String key,
    required List<int> bytes,
    required String contentType,
  });

  Future<void> delete(String key);

  /// A stable, unauthenticated URL. Only ever for things that are genuinely
  /// public.
  Uri publicUrl(String key);

  /// A URL that stops working. For anything that is not.
  Uri signedUrl(String key, {Duration ttl = const Duration(minutes: 10)});

  /// Whether this deployment can actually store a file.
  ///
  /// The upload route reads it and answers `503 storage.unavailable` when it
  /// is false, rather than accepting bytes into a map that dies with the
  /// process. "The upload worked" and "the upload worked against real
  /// storage" are different claims, and an operator who saw the first and got
  /// the second would find their logo gone after a deploy.
  bool get isConfigured;
}
