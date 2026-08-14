import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which language the person chose, across launches.
///
/// **Why it is stored at all.** The device's locale is a good first guess and
/// a bad permanent answer. On a handset, plenty of phones in this market are
/// secondhand and arrive set to a language their owner does not read. In a
/// browser it is whatever the machine was installed with, which on a shared
/// agency laptop is nobody's choice in particular. The guess is right often
/// enough to be the default and wrong often enough to need overriding — and
/// an override that lasts until the tab is closed is not an override.
///
/// One key in the platform's own preference store, beside the theme and for
/// the same reasons: a language is not a secret, losing it costs a tap, and it
/// must never be a reason the session vault or the ticket database fails to
/// open.
///
/// Copied rather than shared, following `theme_preference.dart`: the alternative
/// is a Flutter package under `packages/` that exists to hold two functions,
/// and each app owning its own storage is what keeps one app's key from
/// becoming another app's migration.
const _key = 'bel.language';

/// The stored choice, or null when nobody has chosen.
///
/// Null is the honest answer rather than a default, because "follow the
/// device" is a real state and one the caller resolves differently — it wants
/// the platform's own locales, not French.
Future<String?> loadLanguage() async {
  try {
    return (await SharedPreferences.getInstance()).getString(_key);
  } on Object {
    return null;
  }
}

/// Never throws. A device that refuses to give us a preference store is a
/// device that should still switch language for this run.
Future<void> saveLanguage(String code) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_key, code);
  } on Object {
    // Nothing to do and nothing worth telling anybody: the choice holds for
    // this launch, and the next one falls back to the device.
  }
}
