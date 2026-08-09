/// Case-insensitive header lookup.
///
/// HTTP header names are case-insensitive per RFC 9110, and the server
/// normalises them to lowercase — so reading `headers['If-None-Match']`
/// silently returns null and the caller concludes the client sent nothing.
///
/// That bug is invisible in unit tests (which build the map by hand) and only
/// shows up against a real server: our conditional-GET support quietly
/// returned a full body every time, which on a metered prepaid bundle is the
/// exact cost we were trying to avoid (ADR-0003). One helper, used everywhere,
/// so the mistake cannot recur per endpoint.
extension HeaderLookup on Map<String, String> {
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// True when the client already holds this exact representation.
  ///
  /// Handles the `W/` weak prefix and a comma-separated list, both of which
  /// real clients and proxies send.
  bool matchesEtag(String etag) {
    final provided = header('If-None-Match');
    if (provided == null || provided.isEmpty) return false;
    if (provided.trim() == '*') return true;

    String normalise(String s) {
      var v = s.trim();
      if (v.startsWith('W/')) v = v.substring(2);
      return v;
    }

    final wanted = normalise(etag);
    return provided.split(',').map(normalise).any((v) => v == wanted);
  }
}
