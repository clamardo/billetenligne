import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:http/http.dart' as http;

import '../../application/ports/object_store.dart';

/// Azure Blob Storage, over its REST API.
///
/// REST rather than the SDK, for the same three reasons `FirebaseIdentityClient`
/// is: it is pure Dart, it needs no platform configuration, and it is testable
/// — this adapter runs against **Azurite** in `tool/storage.sh`, which is the
/// only way to find out that a string-to-sign is subtly wrong.
///
/// Shared Key signing is fiddly and unforgiving: one header out of order, one
/// missing newline, and the service answers 403 with no hint about which of
/// the thirteen lines was wrong. It is written out longhand below rather than
/// built with a loop, because the *order* is the specification.
final class AzureBlobStore implements ObjectStore {
  AzureBlobStore({
    required this.account,
    required List<int> accountKey,
    required this.container,
    required Uri endpoint,
    this.publicRead = true,
    http.Client? httpClient,
    DateTime Function()? now,
  }) : _key = accountKey,
       _endpoint = endpoint,
       _http = httpClient ?? http.Client(),
       _now = now ?? (() => DateTime.now().toUtc());

  /// Reads `STORAGE__*` and hands back null when the deployment has no
  /// storage, rather than a client that throws on first use. The caller
  /// substitutes the in-memory store and `/health` says so.
  static AzureBlobStore? fromEnvironment(
    Map<String, String> env, {
    http.Client? httpClient,
  }) {
    final account = env['STORAGE__ACCOUNT'] ?? '';
    final key = env['STORAGE__KEY'] ?? '';
    if (account.isEmpty || key.isEmpty) return null;

    final List<int> decoded;
    try {
      decoded = base64.decode(key);
    } on FormatException {
      // A key that is not base64 is a typo, and failing at startup with a
      // named variable beats a 403 on the first upload three weeks later.
      throw ArgumentError('STORAGE__KEY is not valid base64');
    }

    return AzureBlobStore(
      account: account,
      accountKey: decoded,
      container: env['STORAGE__CONTAINER'] ?? 'brand',
      // The brand container. Logos and covers are public by design; the
      // container KYB documents will land in is a different one, constructed
      // with `publicRead: false`.
      publicRead: true,
      endpoint: Uri.parse(
        env['STORAGE__ENDPOINT'] ?? 'https://$account.blob.core.windows.net',
      ),
      httpClient: httpClient,
    );
  }

  final String account;
  final String container;

  /// Whether a blob in this container is readable by anyone holding its URL.
  ///
  /// True for brand assets — a logo is on a poster and in a cached page, and a
  /// signature that expires would break an image nobody was protecting. It
  /// must be **false** for the container KYB documents will land in, where a
  /// short-lived signature is the entire control. One store per container
  /// rather than one store with a per-call flag: a boolean argument in the
  /// wrong place would publish a passport.
  final bool publicRead;
  final List<int> _key;
  final Uri _endpoint;
  final http.Client _http;
  final DateTime Function() _now;

  /// The version whose signing rules this implements. Pinned rather than
  /// tracking latest: the string-to-sign layout is versioned, and a service
  /// that silently accepted a newer one would leave this signing for a
  /// contract it no longer holds.
  static const apiVersion = '2020-10-02';

  @override
  bool get isConfigured => true;

  /// Creates the container if it is not there.
  ///
  /// When [publicRead], access is granted at **blob** level and never at
  /// container level: a blob is readable by whoever has its URL, and the
  /// container cannot be listed. The difference matters — a listable container
  /// hands an attacker every key, and the keys here name operators.
  ///
  /// Awaited lazily by the first write rather than at startup, and memoised.
  /// A container check on boot would make the API's readiness depend on a
  /// storage account it does not need to serve a single search.
  Future<void> ensureContainer() => _ensured ??= _createContainer();

  Future<void>? _ensured;

  Future<void> _createContainer() async {
    final response = await _send(
      'PUT',
      _blobUrl('').replace(queryParameters: {'restype': 'container'}),
      extraHeaders: {if (publicRead) 'x-ms-blob-public-access': 'blob'},
    );

    // 409 is "already there", which is the expected answer on every restart
    // after the first.
    if (response.statusCode != 201 && response.statusCode != 409) {
      _ensured = null;
      throw StateError(
        'could not create container $container: '
        '${response.statusCode} ${response.body}',
      );
    }
  }

  @override
  Future<StoredObject> put({
    required String key,
    required List<int> bytes,
    required String contentType,
  }) async {
    await ensureContainer();

    final response = await _send(
      'PUT',
      _blobUrl(key),
      body: bytes,
      contentType: contentType,
      extraHeaders: {
        'x-ms-blob-type': 'BlockBlob',
        // A logo changes when an operator changes it, which is roughly never,
        // and it is on every search row. A day of caching with revalidation
        // afterwards is the difference between one request and one per
        // traveller per session on a metered bundle (ADR-0009).
        'x-ms-blob-cache-control': 'public, max-age=86400, must-revalidate',
      },
    );

    if (response.statusCode != 201) {
      throw StateError(
        'could not store $key: ${response.statusCode} ${response.body}',
      );
    }

    return StoredObject(
      key: key,
      contentType: contentType,
      bytes: bytes.length,
    );
  }

  @override
  Future<void> delete(String key) async {
    final response = await _send('DELETE', _blobUrl(key));
    // 404 is success here. Deleting a logo that is already gone is the state
    // the caller wanted, and turning it into an error would make "remove my
    // logo" fail for somebody who clicked twice.
    if (response.statusCode != 202 && response.statusCode != 404) {
      throw StateError(
        'could not delete $key: ${response.statusCode} ${response.body}',
      );
    }
  }

  @override
  Uri publicUrl(String key) => _blobUrl(key);

  /// A service SAS, signed here rather than fetched.
  ///
  /// Read-only, minutes long, and scoped to one blob. The clock is skewed five
  /// minutes into the past deliberately: Azure compares against *its* clock,
  /// and a server a few seconds fast issues URLs that are not valid yet — a
  /// failure that appears only in production and only sometimes.
  @override
  Uri signedUrl(String key, {Duration ttl = const Duration(minutes: 10)}) {
    final now = _now();
    final start = _iso(now.subtract(const Duration(minutes: 5)));
    final expiry = _iso(now.add(ttl));

    const permissions = 'r';
    final resource = '/blob/$account/$container/$key';

    // Fifteen lines, in this order, for sv=2020-10-02. The trailing empties
    // are not padding: an omitted line changes the meaning of every line after
    // it, and an *extra* one does the same. There is no
    // `signedEncryptionScope` here — that field arrived in 2020-12-06, and
    // including it under this version is a signature the service silently
    // refuses with a 403 that names nothing. Azurite found that; review did
    // not.
    final toSign = [
      permissions,
      start,
      expiry,
      resource,
      '', // signed identifier
      '', // signed IP
      '', // signed protocol
      apiVersion,
      'b', // signed resource: a single blob
      '', // signed snapshot time
      '', // rscc — cache-control override
      '', // rscd — content-disposition override
      '', // rsce — content-encoding override
      '', // rscl — content-language override
      '', // rsct — content-type override
    ].join('\n');

    return _blobUrl(key).replace(
      queryParameters: {
        'sv': apiVersion,
        'sr': 'b',
        'sp': permissions,
        'st': start,
        'se': expiry,
        'sig': _sign(toSign),
      },
    );
  }

  void close() => _http.close();

  // ── Signing ───────────────────────────────────────────────────────────────

  Uri _blobUrl(String key) {
    final path = key.isEmpty
        ? '${_endpoint.path}/$container'
        : '${_endpoint.path}/$container/$key';
    return _endpoint.replace(path: path);
  }

  Future<http.Response> _send(
    String method,
    Uri url, {
    List<int>? body,
    String? contentType,
    Map<String, String> extraHeaders = const {},
  }) async {
    final headers = <String, String>{
      'x-ms-date': _rfc1123(_now()),
      'x-ms-version': apiVersion,
      ...extraHeaders,
    };

    final signature = sharedKeySignature(
      method: method,
      url: url,
      contentLength: body?.length ?? 0,
      contentType: contentType ?? '',
      headers: headers,
    );

    final request = http.Request(method, url)
      ..headers.addAll({
        ...headers,
        if (contentType != null) 'Content-Type': contentType,
        'Authorization': 'SharedKey $account:$signature',
      });
    if (body != null) request.bodyBytes = List<int>.from(body);

    return http.Response.fromStream(await _http.send(request));
  }

  /// The Shared Key string-to-sign, longhand.
  ///
  /// Every empty line below is a header we do not send, and each one still
  /// occupies its position. This is the part that answers 403 with no
  /// explanation when it is wrong, which is why it reads as the specification
  /// rather than as code — and why [stringToSign] is visible to tests.
  String sharedKeySignature({
    required String method,
    required Uri url,
    required int contentLength,
    required String contentType,
    required Map<String, String> headers,
  }) => _sign(
    stringToSign(
      account: account,
      method: method,
      url: url,
      contentLength: contentLength,
      contentType: contentType,
      headers: headers,
    ),
  );

  static String stringToSign({
    required String account,
    required String method,
    required Uri url,
    required int contentLength,
    required String contentType,
    required Map<String, String> headers,
  }) {
    final canonicalHeaders =
        (headers.entries
                .where((e) => e.key.startsWith('x-ms-'))
                .map((e) => '${e.key.toLowerCase()}:${e.value.trim()}')
                .toList()
              ..sort())
            .join('\n');

    final query =
        url.queryParameters.entries
            .map((e) => MapEntry(e.key.toLowerCase(), e.value))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));

    final canonicalResource = StringBuffer('/$account${url.path}');
    for (final parameter in query) {
      canonicalResource.write('\n${parameter.key}:${parameter.value}');
    }

    return [
      method,
      '', // Content-Encoding
      '', // Content-Language
      // Zero is written as empty, not as "0". A literal zero here is the most
      // common reason a DELETE signs wrong while a PUT signs right.
      contentLength == 0 ? '' : '$contentLength',
      '', // Content-MD5
      contentType,
      '', // Date — superseded by x-ms-date, and must be blank when it is
      '', // If-Modified-Since
      '', // If-Match
      '', // If-None-Match
      '', // If-Unmodified-Since
      '', // Range
      canonicalHeaders,
      canonicalResource.toString(),
    ].join('\n');
  }

  String _sign(String value) =>
      base64.encode(c.Hmac(c.sha256, _key).convert(utf8.encode(value)).bytes);

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// RFC 1123, in English, always. A locale-aware formatter would sign "lun."
  /// and be refused — a bug that only appears on a machine configured in
  /// French, which is every machine in this project's target market.
  static String _rfc1123(DateTime time) {
    final t = time.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${_days[t.weekday - 1]}, ${two(t.day)} ${_months[t.month - 1]} '
        '${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} GMT';
  }

  /// Seconds precision, no fraction. Azure refuses a SAS whose timestamps
  /// carry milliseconds.
  static String _iso(DateTime time) =>
      '${time.toUtc().toIso8601String().split('.').first}Z';
}
