@Tags(['storage'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:bel_api/src/infrastructure/azure/azure_blob_store.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// The object store, against a real blob service.
///
/// The interesting half of this adapter is a **signature**, and a signature is
/// exactly the thing a fake cannot check. Shared Key signing is thirteen lines
/// in a fixed order with empty lines that carry meaning, and a service that
/// answers 403 with no indication of which line was wrong. Every test below
/// would pass against a mock that agreed with the code; none of them would
/// prove anything.
///
///   ./tool/storage.sh
void main() {
  final account = Platform.environment['STORAGE__ACCOUNT'];

  if (account == null || account.isEmpty) {
    test('storage suite', () {}, skip: 'run via tool/storage.sh');
    return;
  }

  late AzureBlobStore store;

  /// The container KYB documents will land in: no public access at all, where
  /// a signature is the entire control rather than a formality on top of a
  /// blob anyone could already read.
  late AzureBlobStore vault;
  late http.Client client;

  setUpAll(() async {
    client = http.Client();
    store = AzureBlobStore.fromEnvironment(
      Platform.environment,
      httpClient: client,
    )!;
    vault = AzureBlobStore(
      account: store.account,
      accountKey: base64.decode(Platform.environment['STORAGE__KEY']!),
      container: 'vault',
      endpoint: Uri.parse(Platform.environment['STORAGE__ENDPOINT']!),
      publicRead: false,
      httpClient: client,
    );
    await store.ensureContainer();
    await vault.ensureContainer();
  });

  tearDownAll(() {
    store.close();
    vault.close();
    client.close();
  });

  var seq = 0;
  String key() => 'operators/it-${++seq}/logo.png';

  final png = utf8.encode('not really a png, but bytes are bytes');

  test('a blob goes up and comes back byte for byte', () async {
    final at = key();
    final stored = await store.put(
      key: at,
      bytes: png,
      contentType: 'image/png',
    );

    expect(stored.key, at);
    expect(stored.bytes, png.length);

    final fetched = await client.get(store.publicUrl(at));
    expect(fetched.statusCode, 200);
    expect(fetched.bodyBytes, png);
    // Sniffed from the bytes at the route, and honoured here — a browser that
    // guesses the type of an "image" upload is a browser we have handed a
    // choice we should have made.
    expect(fetched.headers['content-type'], 'image/png');
  });

  // A logo is on every search row and changes roughly never. Serving it
  // uncached would be one request per traveller per session on a metered
  // bundle (ADR-0009).
  test('it is served with a cache header', () async {
    final at = key();
    await store.put(key: at, bytes: png, contentType: 'image/png');

    final fetched = await client.get(store.publicUrl(at));
    expect(fetched.headers['cache-control'], contains('max-age=86400'));
  });

  // The container is public at *blob* level, not container level: a blob is
  // readable by whoever has its URL, and the container cannot be listed. A
  // listable container would hand an attacker every key, and the keys name
  // operators.
  test('the container cannot be listed anonymously', () async {
    final listing = await client.get(
      store
          .publicUrl('')
          .replace(queryParameters: {'restype': 'container', 'comp': 'list'}),
    );
    expect(listing.statusCode, isNot(200));
  });

  test('a second upload replaces the first', () async {
    final at = key();
    await store.put(key: at, bytes: png, contentType: 'image/png');

    final replacement = utf8.encode('the new logo');
    await store.put(key: at, bytes: replacement, contentType: 'image/png');

    final fetched = await client.get(store.publicUrl(at));
    expect(fetched.bodyBytes, replacement);
  });

  test('a deleted blob is gone, and deleting it twice is fine', () async {
    final at = key();
    await store.put(key: at, bytes: png, contentType: 'image/png');
    await store.delete(at);

    expect((await client.get(store.publicUrl(at))).statusCode, 404);

    // "Remove my logo" must not fail for somebody who clicked twice.
    await expectLater(store.delete(at), completes);
  });

  // Signed URLs are for KYB documents rather than logos, and none of those are
  // built yet — so the signature is proven here, against the service that will
  // one day be asked to honour it, rather than left until it is load-bearing.
  // Signed URLs are for KYB documents rather than logos, and none of those are
  // built yet — so the signature is proven here, against the service that will
  // one day be asked to honour it, rather than left until it is load-bearing.
  //
  // Every test in this group runs against the **private** container. Against
  // the brand one they would all pass without a signature ever being checked,
  // which is the trap this group was written into once already.
  group('the SAS signature', () {
    test('a private blob is not readable without one', () async {
      final at = key();
      await vault.put(key: at, bytes: png, contentType: 'image/png');

      // Azure answers 404 here to avoid confirming the blob exists; Azurite
      // answers 403. Either is a refusal, and pinning one would make this
      // test a statement about which emulator is running.
      expect(
        (await client.get(vault.publicUrl(at))).statusCode,
        isIn([403, 404]),
      );
    });

    test('a signed URL reads it', () async {
      final at = key();
      await vault.put(key: at, bytes: png, contentType: 'image/png');

      final signed = await client.get(vault.signedUrl(at));
      expect(signed.statusCode, 200);
      expect(signed.bodyBytes, png);
    });

    test('a tampered signature is refused', () async {
      final at = key();
      await vault.put(key: at, bytes: png, contentType: 'image/png');

      final url = vault.signedUrl(at);
      final forged = url.replace(
        queryParameters: {...url.queryParameters, 'sig': 'not-a-signature'},
      );

      expect((await client.get(forged)).statusCode, 403);
    });

    test('an expired signature is refused', () async {
      final at = key();
      await vault.put(key: at, bytes: png, contentType: 'image/png');

      // The store skews five minutes into the past to survive clock drift, so
      // an expiry further back than that is already behind us.
      final stale = vault.signedUrl(at, ttl: const Duration(minutes: -10));
      expect((await client.get(stale)).statusCode, 403);
    });

    test('a signature for one blob does not read another', () async {
      final mine = key();
      final theirs = key();
      await vault.put(key: mine, bytes: png, contentType: 'image/png');
      await vault.put(key: theirs, bytes: png, contentType: 'image/png');

      final url = vault.signedUrl(mine);
      final swapped = vault
          .publicUrl(theirs)
          .replace(queryParameters: url.queryParameters);

      expect((await client.get(swapped)).statusCode, 403);
    });
  });
}
