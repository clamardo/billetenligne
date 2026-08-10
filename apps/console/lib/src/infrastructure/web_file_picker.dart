import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../application/ports/file_picker.dart';

/// A file dialog, in a browser.
///
/// A hidden `<input type="file">` clicked programmatically, which is the only
/// way any web application opens this dialog — there is no Flutter API for it
/// and a plugin would wrap exactly these fifteen lines.
///
/// The element is created per call and removed afterwards. A long-lived one
/// would remember the previous selection, and "choose the same file again"
/// would fire no `change` event at all — a bug that looks like the upload
/// silently failing.
final class WebFilePicker implements FilePicker {
  const WebFilePicker();

  @override
  Future<PickedFile?> pick({List<String> accept = const []}) {
    final completer = Completer<PickedFile?>();

    final input = web.document.createElement('input') as web.HTMLInputElement
      ..type = 'file'
      ..accept = accept.join(',')
      ..style.display = 'none';

    // `change` never fires on cancel, so a dismissed dialog would otherwise
    // leave this future hanging forever and the button spinning. `cancel` is
    // supported everywhere the console runs; where it is not, the worst case
    // is the element lingering until the next pick.
    input.oncancel = ((web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
      input.remove();
    }).toJS;

    input.onchange = ((web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        input.remove();
        return;
      }

      final file = files.item(0)!;
      final reader = web.FileReader();
      reader.onload = ((web.Event _) {
        final buffer = reader.result as JSArrayBuffer?;
        if (!completer.isCompleted) {
          completer.complete(
            buffer == null
                ? null
                : PickedFile(
                    name: file.name,
                    bytes: buffer.toDart.asUint8List(),
                    mimeType: file.type,
                  ),
          );
        }
        input.remove();
      }).toJS;
      reader.readAsArrayBuffer(file);
    }).toJS;

    web.document.body!.append(input);
    input.click();

    return completer.future;
  }
}
