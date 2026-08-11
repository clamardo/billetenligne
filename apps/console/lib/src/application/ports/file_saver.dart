/// Handing somebody a file the server produced.
///
/// A port for the same reason [FilePicker] is one: there is no way to trigger
/// a browser download in a widget test, and this one call is the only thing
/// the download flow does that a test cannot. Behind it the console has an
/// anchor and a blob URL; behind it a test has a list.
///
/// The **server names the file**. A statement is a commercial document and
/// the name is part of it — `releve-ocean-du-nord-2026-08-01.pdf` is what an
/// accountant searches a folder for — so the name arrives with the bytes
/// rather than being composed here.
abstract interface class FileSaver {
  Future<void> save({
    required String filename,
    required List<int> bytes,
    required String mimeType,
  });
}
