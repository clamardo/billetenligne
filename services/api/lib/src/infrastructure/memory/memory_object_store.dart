import 'dart:typed_data';

import '../../application/ports/object_store.dart';

/// Files in a map, for tests and the fakes composition.
///
/// A fake is honest here in a way it is not for the console: an object store
/// is a key, some bytes and a content type, and there is no second definition
/// of the world hiding in it. What it cannot reproduce is the *signature* on a
/// URL, so [signedUrl] returns something visibly fake — a URL that looks
/// signed but is not would be worse than one that admits it.
final class MemoryObjectStore implements ObjectStore {
  MemoryObjectStore({Uri? baseUrl})
    : _base = baseUrl ?? Uri.parse('http://localhost:8080/dev-storage');

  final Uri _base;
  final Map<String, StoredObject> _objects = {};
  final Map<String, Uint8List> _bytes = {};

  @override
  bool get isConfigured => false;

  Uint8List? read(String key) => _bytes[key];

  @override
  Future<StoredObject> put({
    required String key,
    required List<int> bytes,
    required String contentType,
  }) async {
    _bytes[key] = Uint8List.fromList(bytes);
    return _objects[key] = StoredObject(
      key: key,
      contentType: contentType,
      bytes: bytes.length,
    );
  }

  @override
  Future<void> delete(String key) async {
    _objects.remove(key);
    _bytes.remove(key);
  }

  @override
  Uri publicUrl(String key) => _base.replace(path: '${_base.path}/$key');

  @override
  Uri signedUrl(String key, {Duration ttl = const Duration(minutes: 10)}) =>
      publicUrl(key).replace(query: 'dev=unsigned');
}
