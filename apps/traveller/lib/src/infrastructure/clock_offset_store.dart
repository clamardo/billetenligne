import 'dart:convert';

import 'package:bel_platform/bel_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers how far this handset's clock sits from the server's, across
/// launches.
///
/// It has to survive a launch to be worth anything. The measurement is taken
/// when the traveller has signal — buying, or any request at all — and it is
/// needed hours later at a coach door with none, very possibly after the app
/// has been killed for memory on a 2 GB handset. A measurement held only in
/// memory would be gone at precisely the moment it mattered.
///
/// One key in the platform's own preference store, beside the theme, and
/// deliberately **not** in the session vault or the ticket database: a clock
/// offset is not a secret and losing it costs nothing — the app falls back to
/// the device clock, which is where it was before this existed — so it must
/// never be a reason either of those fails to open.
const _key = 'bel.clockOffset';

final class ClockOffsetStore {
  ClockOffsetStore._(this._prefs, this._value);

  final SharedPreferences? _prefs;
  ClockOffset? _value;

  /// The last measurement, or null when there has never been one.
  ///
  /// Read through a getter rather than handed out as a value, because it is
  /// replaced by every response the client receives and a caller holding a
  /// copy would keep using the stale one.
  ClockOffset? get value => _value;

  /// Never throws. A handset that refuses to give us a preference store is a
  /// handset that should still show a ticket, on its own clock.
  static Future<ClockOffsetStore> open() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object {
      return ClockOffsetStore._(null, null);
    }

    ClockOffset? stored;
    try {
      final raw = prefs.getString(_key);
      if (raw != null) {
        stored = ClockOffset.fromJson(jsonDecode(raw) as Map<String, Object?>);
      }
    } on Object {
      // A row written by an older build, or a truncated write. Reading it as
      // nothing is right: there is no safe guess about what time it is, and a
      // wrong offset moves every code the traveller is shown.
      stored = null;
    }
    return ClockOffsetStore._(prefs, stored);
  }

  /// Records a fresh measurement. Best-effort, like the read.
  void write(ClockOffset offset) {
    _value = offset;
    try {
      _prefs?.setString(_key, jsonEncode(offset.toJson()));
    } on Object {
      // In memory it still helps for the rest of this launch.
    }
  }
}
