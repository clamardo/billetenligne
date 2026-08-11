import 'dart:async';
import 'dart:convert';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A scripted transport, so the tests exercise the client rather than a
/// server. Records every request, which is where most of the assertions are:
/// what the client *sent* is the interesting half.
final class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._responses);

  final List<Object> _responses;
  final List<http.BaseRequest> requests = [];
  final List<String> bodies = [];
  var _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(request is http.Request ? request.body : '');

    final next = _responses[_index.clamp(0, _responses.length - 1)];
    _index++;

    if (next is Exception) throw next;
    if (next is Duration) {
      await Future<void>.delayed(next);
      return http.StreamedResponse(const Stream.empty(), 200);
    }

    // A triple carries response headers — only the download tests need
    // them, and every other case stays a readable pair.
    if (next is (int, String, Map<String, String>)) {
      final (status, body, headers) = next;
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        status,
        headers: headers,
        request: request,
      );
    }

    final (status, body) = next as (int, String);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

/// One query, reused. These tests are about headers, retries and parsing —
/// which route is being searched is never the interesting part.
final _anyQuery = SearchDeparturesQuery(
  originCity: 'BZV',
  destinationCity: 'PNR',
  date: DateTime.utc(2026, 8, 15),
);

void main() {
  final base = Uri.parse('http://localhost:8080');

  BelApiClient clientFor(
    _ScriptedClient transport, {
    RetryPolicy retry = RetryPolicy.none,
    String? token,
    Duration timeout = const Duration(seconds: 20),
  }) => BelApiClient(
    baseUrl: base,
    httpClient: transport,
    retry: retry,
    timeout: timeout,
    token: token == null ? null : () => token,
  );

  const holdJson = '''
  {"id":"h1","departureId":"d1","seatLabels":["1A"],
   "expiresAt":"2026-08-09T06:15:00Z",
   "total":{"minor":12300,"currency":"XAF"},
   "fare":{"minor":12000,"currency":"XAF"},
   "serviceFee":{"minor":300,"currency":"XAF"},
   "state":"active"}''';

  group('what the client sends', () {
    test('a language header on every request', () async {
      final transport = _ScriptedClient([(200, '{"items":[]}')]);
      await clientFor(transport).searchTrips(
        SearchDeparturesQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          date: DateTime.utc(2026, 8, 15),
        ),
      );

      expect(transport.requests.single.headers['X-Language'], 'fr');
    });

    test(
      'a bearer token when there is one, and nothing when there is not',
      () async {
        final anonymous = _ScriptedClient([(200, '{"items":[]}')]);
        await clientFor(anonymous).searchTrips(_anyQuery);

        // Browsing is deliberately open. An Authorization header on a public
        // read is not harmless: it makes the server resolve a token it does not
        // need, and turns an expired session into a failed search.
        expect(
          anonymous.requests.single.headers,
          isNot(contains('Authorization')),
        );

        final signedIn = _ScriptedClient([(201, holdJson)]);
        await clientFor(signedIn, token: 'tok').createHold(
          const CreateHoldRequest(departureId: 'd1', seatLabels: ['1A']),
        );
        expect(signedIn.requests.single.headers['Authorization'], 'Bearer tok');
      },
    );

    test('an idempotency key on a hold, and none on a search', () async {
      final transport = _ScriptedClient([(201, holdJson)]);
      await clientFor(transport, token: 'tok').createHold(
        const CreateHoldRequest(departureId: 'd1', seatLabels: ['1A']),
      );

      expect(transport.requests.single.headers['Idempotency-Key'], isNotEmpty);

      final search = _ScriptedClient([(200, '{"items":[]}')]);
      await clientFor(search).searchTrips(_anyQuery);
      expect(
        search.requests.single.headers,
        isNot(contains('Idempotency-Key')),
      );
    });

    test('the caller can supply the key, to resume a lost attempt', () async {
      final transport = _ScriptedClient([(201, holdJson)]);
      await clientFor(transport, token: 'tok').createHold(
        const CreateHoldRequest(departureId: 'd1', seatLabels: ['1A']),
        idempotencyKey: 'resumed-attempt',
      );

      // The connection dropped, the app never saw the answer, and this is the
      // retry. Same key, so the server hands back the hold that already
      // exists instead of creating a second one.
      expect(
        transport.requests.single.headers['Idempotency-Key'],
        'resumed-attempt',
      );
    });

    test('search parameters land in the query string', () async {
      final transport = _ScriptedClient([(200, '{"items":[]}')]);
      await clientFor(transport).searchTrips(
        SearchDeparturesQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          date: DateTime.utc(2026, 8, 15),
          passengers: 3,
        ),
      );

      final uri = transport.requests.single.url;
      expect(uri.path, '/public/v1/trips');
      expect(uri.queryParameters['from'], 'BZV');
      expect(uri.queryParameters['to'], 'PNR');
      expect(uri.queryParameters['date'], '2026-08-15');
      expect(uri.queryParameters['passengers'], '3');
    });
  });

  group('what the client makes of the answer', () {
    test('parses a hold, money and all', () async {
      final transport = _ScriptedClient([(201, holdJson)]);
      final hold = await clientFor(transport, token: 'tok').createHold(
        const CreateHoldRequest(departureId: 'd1', seatLabels: ['1A']),
      );

      expect(hold.id, 'h1');
      expect(hold.total.minor, 12300);
      expect(hold.total.currency.code, 'XAF');
    });

    test('a refusal keeps its code, params and trace id', () async {
      final transport = _ScriptedClient([
        (
          409,
          '{"error":{"code":"hold.seat_unavailable",'
              '"params":{"seats":"1A"},"traceId":"abc123"}}',
        ),
      ]);

      final failure = await clientFor(transport, token: 'tok')
          .createHold(
            const CreateHoldRequest(departureId: 'd1', seatLabels: ['1A']),
          )
          .then<ApiFailure?>(
            (_) => null,
            onError: (Object e) => e as ApiFailure,
          );

      final refused = failure! as ServerRefused;
      expect(refused.status, 409);
      expect(refused.code, 'hold.seat_unavailable');
      expect(refused.params['seats'], '1A');
      // The one string a support agent needs. Throwing it away on the failure
      // path is throwing it away on the only path where it matters.
      expect(refused.traceId, 'abc123');
      expect(refused.messageKey, 'errors.hold.seat_unavailable');
    });

    test('a 204 is success, not an empty-body error', () async {
      final transport = _ScriptedClient([(204, '')]);
      await expectLater(
        clientFor(transport, token: 'tok').releaseHold('h1'),
        completes,
      );
    });

    test('an error with no body still gets a typed code', () async {
      final transport = _ScriptedClient([(503, '')]);

      final failure = await clientFor(transport)
          .searchTrips(_anyQuery)
          .then<ApiFailure?>(
            (_) => null,
            onError: (Object e) => e as ApiFailure,
          );

      expect((failure! as ServerRefused).code, 'server.unavailable');
    });

    test('unparseable JSON says "update the app", not "try again"', () async {
      final transport = _ScriptedClient([(200, 'not json at all')]);

      final failure = await clientFor(transport)
          .searchTrips(_anyQuery)
          .then<ApiFailure?>(
            (_) => null,
            onError: (Object e) => e as ApiFailure,
          );

      expect(failure, isA<UnreadableResponse>());
      // Retrying produces the identical unparseable answer. Offering "try
      // again" would be advice that cannot possibly work.
      expect(failure!.retryable, isFalse);
    });
  });

  group('a bad connection', () {
    test('a dropped read is retried and can succeed', () async {
      final transport = _ScriptedClient([
        const SocketishException(),
        (200, '{"items":[]}'),
      ]);

      final trips =
          await clientFor(
            transport,
            retry: const RetryPolicy(
              maxAttempts: 2,
              initialDelay: Duration(milliseconds: 1),
              jitter: 0,
            ),
          ).searchTrips(
            SearchDeparturesQuery(
              originCity: 'BZV',
              destinationCity: 'PNR',
              date: DateTime.utc(2026, 8, 15),
            ),
          );

      expect(trips, isEmpty);
      expect(transport.requests, hasLength(2));
    });

    test('a retried hold reuses the same key', () async {
      final transport = _ScriptedClient([
        const SocketishException(),
        (201, holdJson),
      ]);

      await clientFor(
        transport,
        token: 'tok',
        retry: const RetryPolicy(
          maxAttempts: 2,
          initialDelay: Duration(milliseconds: 1),
          jitter: 0,
        ),
      ).createHold(
        const CreateHoldRequest(departureId: 'd1', seatLabels: ['1A']),
      );

      final keys = transport.requests
          .map((r) => r.headers['Idempotency-Key'])
          .toSet();

      // The whole point. Two requests, one key, so the server creates one
      // hold — a retry that minted a fresh key would hold two different seats
      // for somebody who asked for one.
      expect(transport.requests, hasLength(2));
      expect(keys, hasLength(1));
    });

    test('a refusal is not retried', () async {
      final transport = _ScriptedClient([
        (409, '{"error":{"code":"hold.seat_unavailable"}}'),
        (201, holdJson),
      ]);

      await clientFor(
            transport,
            token: 'tok',
            retry: const RetryPolicy(
              maxAttempts: 2,
              initialDelay: Duration(milliseconds: 1),
              jitter: 0,
            ),
          )
          .createHold(
            const CreateHoldRequest(departureId: 'd1', seatLabels: ['1A']),
          )
          .then<void>((_) {}, onError: (Object _) {});

      // The seat is taken. Asking again cannot change that and burns the
      // traveller's data allowance finding out.
      expect(transport.requests, hasLength(1));
    });

    test('a timeout is reported as its own thing', () async {
      final transport = _ScriptedClient([const Duration(milliseconds: 50)]);

      final failure =
          await clientFor(transport, timeout: const Duration(milliseconds: 5))
              .searchTrips(_anyQuery)
              .then<ApiFailure?>(
                (_) => null,
                onError: (Object e) => e as ApiFailure,
              );

      // "We never heard back" is a different story from "the server said no",
      // and demands different words on screen.
      expect(failure, isA<RequestTimedOut>());
      expect(failure!.retryable, isTrue);
    });
  });

  group('retry timing', () {
    test('backs off, and never past the ceiling', () {
      const policy = RetryPolicy(
        maxAttempts: 6,
        initialDelay: Duration(milliseconds: 400),
        maxDelay: Duration(seconds: 8),
        jitter: 0,
      );

      expect(policy.delayFor(1).inMilliseconds, 400);
      expect(policy.delayFor(2).inMilliseconds, 800);
      expect(policy.delayFor(3).inMilliseconds, 1600);
      expect(policy.delayFor(9).inMilliseconds, 8000);
    });

    test('jitter spreads handsets that lost signal together', () {
      const policy = RetryPolicy(
        maxAttempts: 4,
        initialDelay: Duration(milliseconds: 1000),
        jitter: 0.5,
      );

      final delays = [for (var i = 1; i <= 4; i++) policy.delayFor(i)];

      // Every handset leaving the same tunnel must not retry in the same
      // millisecond. Distinct delays are the evidence that they will not.
      expect(delays.toSet(), hasLength(delays.length));
    });
  });

  group('downloading a document', () {
    test(
      'the bytes come back untouched and the server names the file',
      () async {
        final transport = _ScriptedClient([
          (
            200,
            '%PDF-1.7\nhello',
            {
              'content-type': 'application/pdf',
              'content-disposition':
                  'attachment; filename="releve-ocean-du-nord-2026-08-01.pdf"',
            },
          ),
        ]);

        final file = await clientFor(transport).statementPdf('run-1');

        // A PDF decoded as JSON would be an UnreadableResponse for a response
        // that was perfectly readable — which is why this path does not decode.
        expect(utf8.decode(file.bytes), startsWith('%PDF-1.7'));
        expect(file.contentType, 'application/pdf');
        expect(file.filename, 'releve-ocean-du-nord-2026-08-01.pdf');
        expect(transport.requests.single.headers['Accept'], 'application/pdf');
      },
    );

    test(
      'a server that names nothing leaves the naming to the caller',
      () async {
        final transport = _ScriptedClient([
          (200, '%PDF-1.7', {'content-type': 'application/pdf'}),
        ]);

        final file = await clientFor(transport).statementPdf('run-1');

        // Null rather than a guess: a download called `attachment;` is how a
        // half-parsed header shows up on somebody's desktop.
        expect(file.filename, isNull);
      },
    );

    test('a refusal is still JSON, and is still typed', () async {
      final transport = _ScriptedClient([
        (404, '{"error":{"code":"resource.not_found"}}'),
      ]);

      // Another operator's statement id. The route answers a typed 404 the
      // same way every other route does, so the download path parses the
      // failure even though it does not parse the success.
      await expectLater(
        clientFor(transport).statementPdf('somebody-elses'),
        throwsA(isA<ServerRefused>().having((f) => f.status, 'status', 404)),
      );
    });

    test(
      'the back office reads the same document from its own route',
      () async {
        final transport = _ScriptedClient([
          (200, '%PDF-1.7', {'content-type': 'application/pdf'}),
        ]);

        await clientFor(transport).payoutPdf('run-1');

        expect(
          transport.requests.single.url.path,
          '/admin/v1/payouts/run-1/pdf',
        );
      },
    );
  });

  group('idempotency keys', () {
    test('are unique across calls', () {
      final keys = {for (var i = 0; i < 1000; i++) IdempotencyKey.generate()};
      expect(keys, hasLength(1000));
    });
  });
}

/// Stands in for whatever the platform throws when a socket dies. The client
/// must treat *any* transport exception as "we never heard back" rather than
/// enumerating the ones it has seen before.
final class SocketishException implements Exception {
  const SocketishException();
  @override
  String toString() => 'connection closed before full header was received';
}
