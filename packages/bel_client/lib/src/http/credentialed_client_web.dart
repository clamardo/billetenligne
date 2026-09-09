import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// The default transport on the web, with **credentials on** (J11).
///
/// A browser does not attach a cookie to a cross-origin request unless the
/// request asks it to — `credentials: 'include'`, which `package:http` spells
/// `withCredentials`. Without this the console signs itself out on the first
/// request after a page load, and the failure looks like the server refusing
/// a session it is in fact never shown.
///
/// The API answers `Access-Control-Allow-Credentials: true` for the exact
/// origins on its allow-list, and the session cookie is `SameSite=Lax`, so a
/// page on somebody else's site never carries it whatever this says.
http.Client credentialedClient() => BrowserClient()..withCredentials = true;
