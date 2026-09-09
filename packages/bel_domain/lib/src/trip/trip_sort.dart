library;

/// How a results list is ordered (`18-…-can-join.md` §6.1).
///
/// Three, and no more. Earliest is what somebody standing at a station wants,
/// cheapest is what somebody planning a month out wants, and fastest is the
/// only one of the three a traveller cannot work out for themselves from a
/// list — a road with fewer stops arrives sooner from the same yard at the
/// same minute, and nothing on the row says so.
///
/// **The sort is part of the cursor, not a decoration on the request**
/// (§6.2). Search pagination here is a keyset, and a keyset is defined
/// *against* an order: a cursor minted under `earliest` means nothing under
/// `cheapest`. Re-sorting a page on the client is not the same feature — it
/// orders twenty rows out of two hundred — and silently re-sorting on the
/// server produces duplicate and missing rows across a page boundary, which
/// reads to everybody involved as the inventory being wrong.
enum TripSort {
  /// `(departs, id)`. The default, and the order the list has always had.
  earliest,

  /// `(fare, departs, id)`. Ties on price are common — two companies on one
  /// road usually match each other — so the second key is what a traveller
  /// would expect next.
  cheapest,

  /// `(duration, departs, id)`. The arrival time minus the boarding time for
  /// the leg actually asked for, so a Dolisie–Pointe-Noire row is ranked on
  /// the piece of road the traveller is buying.
  fastest;

  /// Null on anything else, so an unknown value is a refusal rather than a
  /// silent fall back to `earliest`. A client asking for a sort we removed
  /// should find out.
  static TripSort? byName(String? raw) {
    for (final sort in values) {
      if (sort.name == raw) return sort;
    }
    return null;
  }

  String get labelKey => 'enum.TripSort.$name';

  /// Whether a row's position under this order depends on anything but its
  /// departure time — which is exactly when the cursor has to carry a second
  /// number for the keyset to be complete.
  bool get needsValue => this != earliest;
}
