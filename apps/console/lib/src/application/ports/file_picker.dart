/// A file somebody chose, already in memory.
///
/// Bytes rather than a path or a handle: the console is a web build, where a
/// "file" is a browser object with no path at all, and the API takes a request
/// body. A logo is capped at 40 KB, so holding it whole costs nothing.
final class PickedFile {
  const PickedFile({
    required this.name,
    required this.bytes,
    required this.mimeType,
  });

  final String name;
  final List<int> bytes;

  /// What the browser guessed, forwarded as a courtesy to proxies. The server
  /// sniffs the bytes and ignores this — it is a claim, not a fact.
  final String mimeType;
}

/// Asking somebody for a file.
///
/// A port because there is no way to open a file dialog in a widget test, and
/// because the *only* thing the upload flow does that a test cannot is this
/// one call. Behind it the console has a `package:web` input element; behind
/// it a test has a constant.
abstract interface class FilePicker {
  /// Null when the dialog was dismissed, which is the common case and is not
  /// an error.
  Future<PickedFile?> pick({List<String> accept = const []});
}
