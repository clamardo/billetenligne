import 'package:bel_design/bel_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which theme the person chose, across launches.
///
/// One key in the platform's own preference store. It is deliberately not in
/// the session vault or the ticket database: a theme is not a secret and
/// losing it costs nobody anything, so it must never be a reason either of
/// those fails to open.
const _key = 'bel.theme';

/// Reads the stored choice and returns a controller that writes back.
///
/// Never throws. A handset that refuses to give us a preference store is a
/// handset that should still open the app, following the system theme — which
/// is the default anybody who has not chosen would get anyway.
Future<KiloModeController> loadThemeMode() async {
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } on Object {
    return KiloModeController();
  }
  return KiloModeController(
    initial: KiloMode.byName(prefs.getString(_key)),
    onChanged: (mode) => prefs?.setString(_key, mode.name),
  );
}
