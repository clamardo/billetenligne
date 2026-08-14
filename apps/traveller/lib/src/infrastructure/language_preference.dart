import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which language the person chose, across launches.
///
/// **Why it is stored at all.** The handset's locale is a good first guess and
/// a bad permanent answer: plenty of phones in this market are secondhand and
/// arrive set to a language their owner does not read, and until this existed
/// the app had no way to be told otherwise — `setLanguage` was wired through
/// the whole widget tree and called from nowhere.
///
/// One key in the platform's own preference store, beside the theme and for
/// the same reasons: a language is not a secret, losing it costs a tap, and it
/// must never be a reason the session vault or the ticket database fails to
/// open.
const _key = 'bel.language';

/// The stored choice, or null when nobody has chosen.
///
/// Null is the honest answer rather than a default, because "follow the
/// handset" is a real state and one the caller resolves differently — it wants
/// the device locale, not French.
Future<String?> loadLanguage() async {
  try {
    return (await SharedPreferences.getInstance()).getString(_key);
  } on Object {
    return null;
  }
}

/// Never throws. A handset that refuses to give us a preference store is a
/// handset that should still switch language for this run.
Future<void> saveLanguage(String code) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_key, code);
  } on Object {
    // Nothing to do and nothing worth telling anybody: the choice holds for
    // this launch, and the next one falls back to the handset.
  }
}
