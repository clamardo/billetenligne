import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../application/ports/file_saver.dart';

/// A download, in a browser.
///
/// An anchor with a `download` attribute pointed at a blob URL, clicked
/// programmatically — which is how every web application saves a file it
/// already holds in memory. A plugin would wrap exactly these twelve lines.
///
/// **The URL is revoked afterwards.** A blob URL pins its bytes in the tab
/// for as long as the document lives, and a console somebody leaves open all
/// week while downloading statements would hold every one of them.
///
/// It cannot be a plain link to the API either: the route needs a bearer
/// token, and a `<a href>` sends no headers. The bytes come down through the
/// same authenticated client as everything else and are handed to the browser
/// here.
final class WebFileSaver implements FileSaver {
  const WebFileSaver();

  @override
  Future<void> save({
    required String filename,
    required List<int> bytes,
    required String mimeType,
  }) async {
    final blob = web.Blob(
      [Uint8List.fromList(bytes).toJS].toJS,
      web.BlobPropertyBag(type: mimeType),
    );
    final url = web.URL.createObjectURL(blob);

    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = filename
      ..style.display = 'none';

    web.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
  }
}
