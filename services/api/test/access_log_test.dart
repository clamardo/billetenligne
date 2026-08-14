import 'dart:convert';

import 'package:bel_api/src/middleware/access_log.dart';
import 'package:test/test.dart';

/// The line a deployed API writes about a request.
///
/// Two things are being protected here, and only one of them is about
/// logging. The first is that a log is *useful*: a status, a latency and a
/// trace id that joins to the one the client was handed. The second is that a
/// log is a place secrets end up, and this API has a path that **is** a
/// credential — `/b/{token}` opens somebody's boarding pass, with their seat
/// and their name on it, to whoever holds the string.
void main() {
  group('the path that gets written down', () {
    test('a ticket token never appears', () {
      expect(
        LoggedPath.of('/b/9f3a2c7e1d5b4a8096e2f1c3d4b5a6f7'),
        '/b/{token}',
      );
    });

    test('nor does a trip share', () {
      expect(LoggedPath.of('/t/abcdef0123456789'), '/t/{token}');
    });

    test(
      'the token is replaced by where it sits, not by what it looks like',
      () {
        // A token is opaque. There is nothing in one to recognise, and "it did
        // not look like a token" is exactly how one ends up in a log — so the
        // rule is the position, and a short unlucky-looking token is caught by
        // the same rule as a long one.
        expect(LoggedPath.of('/b/BEL'), '/b/{token}');
        expect(LoggedPath.of('/b/1'), '/b/{token}');
      },
    );

    test('an id becomes a route, so lines can be counted', () {
      expect(
        LoggedPath.of(
          '/public/v1/departures/3f2504e0-4f89-11d3-9a0c-0305e82c3301/seatmap',
        ),
        '/public/v1/departures/{id}/seatmap',
      );
    });

    test('and so does a booking reference', () {
      expect(
        LoggedPath.of('/console/v1/bookings/BEL-4KQ2M9/refund'),
        '/console/v1/bookings/{ref}/refund',
      );
    });

    test('an operator code is public and stays legible', () {
      // It is on a poster. Templating it would cost the one thing this line
      // is good for: which storefront somebody actually opened.
      expect(LoggedPath.of('/o/TRANSCONGO01'), '/o/TRANSCONGO01');
    });

    test('a route with nothing in it is left alone', () {
      expect(LoggedPath.of('/public/v1/trips'), '/public/v1/trips');
      expect(LoggedPath.of('/'), '/');
    });
  });

  group('the shape Cloud Logging reads', () {
    final line = AccessLogLine(
      method: 'GET',
      path: '/b/{token}',
      status: 200,
      milliseconds: 1234,
      trace: 'kx91abc',
      ip: '41.223.0.7',
      bytes: '5120',
    );

    test('the trace id is on the field the console joins entries on', () {
      final json = jsonDecode(line.json) as Map<String, dynamic>;
      expect(json['logging.googleapis.com/trace'], 'kx91abc');
      // And on ours as well, so the same line is searchable by the string a
      // traveller quotes out of a support message.
      expect(json['X-Trace-Id'], 'kx91abc');
    });

    test('latency is seconds with an s, which is what the field expects', () {
      final request =
          (jsonDecode(line.json) as Map<String, dynamic>)['httpRequest']
              as Map<String, dynamic>;
      expect(request['latency'], '1.234s');
      expect(request['status'], 200);
      expect(request['remoteIp'], '41.223.0.7');
      expect(request['responseSize'], '5120');
    });

    test('nothing that was not asked for is in it', () {
      // No headers means no Authorization, and no body means no second copy
      // of every response in memory to measure one.
      expect(line.json, isNot(contains('uthorization')));
      expect(line.json, isNot(contains('Bearer')));
    });

    test('the readable form is one line', () {
      expect(line.text, 'INFO GET /b/{token} 200 1234ms [kx91abc]');
      expect(line.text, isNot(contains('\n')));
    });
  });

  group('severity', () {
    test('a server error is not the same news as a bad request', () {
      // Alerting on a log where a 404 and a 500 arrive at the same level is
      // alerting nobody can tune.
      expect(_severityOf(200), 'INFO');
      expect(_severityOf(304), 'INFO');
      expect(_severityOf(400), 'WARNING');
      expect(_severityOf(404), 'WARNING');
      expect(_severityOf(500), 'ERROR');
      expect(_severityOf(503), 'ERROR');
    });
  });
}

/// The severity a line of a given status carries, read back out of the JSON.
String _severityOf(int status) {
  final line = AccessLogLine(
    method: 'GET',
    path: '/public/v1/trips',
    status: status,
    milliseconds: 4,
    trace: 'kx91abc',
    ip: null,
    bytes: null,
  );
  return (jsonDecode(line.json) as Map<String, dynamic>)['severity'] as String;
}
