import 'package:http/http.dart' as http;

/// The default transport off the web: an ordinary client.
///
/// Nothing here needs cookies — the handset apps and the scanner authenticate
/// with a bearer they hold themselves, in the Keychain and the Android
/// Keystore.
http.Client credentialedClient() => http.Client();
