import 'dart:convert';
import 'dart:io';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// One line per request, so a deployed API can be asked what happened.
///
/// Until this existed the server wrote **nothing at all** unless something
/// threw. A cluster full of green pods and a traveller saying "it didn't
/// work" had no meeting point: no status, no latency, no count, and no way to
/// tell a quiet morning from an outage. The error boundary logged the
/// failures, which is the smallest possible fraction of what happened.
///
/// **The shape is Cloud Logging's, not ours.** A JSON object on stdout with
/// `severity`, `httpRequest` and `logging.googleapis.com/trace` is rendered by
/// GCP as a real request entry — filterable by status and latency, and joined
/// to the trace id the client was handed in a header and quotes in a support
/// message. Inventing our own field names would mean a log we can read and a
/// console that cannot.
///
/// **What is deliberately not in it.** No headers, so no `Authorization`. No
/// query string at all: on this API the query carries where somebody is
/// travelling and on what date, and an access log is read by more people than
/// the database is. And no response body, which also means no second copy of
/// every response in memory to measure one.
Middleware accessLog({
  bool structured = true,
  void Function(String line)? write,
}) {
  final sink = write ?? stdout.writeln;
  return (handler) => (context) async {
    final watch = Stopwatch()..start();
    final request = context.request;
    final response = await handler(context);
    watch.stop();

    final status = response.statusCode;
    final path = LoggedPath.of(request.uri.path);

    // A liveness probe every few seconds is not news. Logged the moment it
    // stops being fine, which is the only moment anybody wants it.
    if (status < HttpStatus.badRequest &&
        (path == '/health' || path == '/ready')) {
      return response;
    }

    final line = AccessLogLine(
      method: request.method.value,
      path: path,
      status: status,
      milliseconds: watch.elapsedMilliseconds,
      trace: context.read<String>(),
      // The first hop only. Behind a Google load balancer this header is a
      // list the client can prepend to, so anything past the first entry is
      // whatever the caller felt like writing.
      ip: request.headers['x-forwarded-for']?.split(',').first.trim(),
      bytes: response.headers[HttpHeaders.contentLengthHeader],
    );

    sink(structured ? line.json : line.text);
    return response;
  };
}

/// A request path with nothing secret and nothing unique left in it.
///
/// Two separate reasons, and the first one matters more than it looks.
///
/// **`/b/{token}` is a credential.** That path is the ticket link sent to a
/// traveller by email: whoever holds the token opens the boarding pass, seat
/// number and passenger names included. Logging the path as it arrived would
/// copy a live credential into a log that far more people can read than can
/// reach the database — including, in a deployment, whoever has Cloud Logging
/// on the project. The token is replaced before anything is written.
///
/// **And an id is not a route.** `/public/v1/departures/{uuid}/seatmap` logged
/// literally is a million distinct paths, which is a log nobody can group,
/// count or alert on. Templating them is what turns lines into traffic.
abstract final class LoggedPath {
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final _digits = RegExp(r'^\d+$');
  static final _reference = RegExp(r'^BEL-[A-Z0-9]+$');

  static String of(String path) {
    final segments = path.split('/');
    for (var i = 1; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.isEmpty) continue;
      // The ticket link, and the trip share beside it. Whole segment, by
      // position rather than by shape: a token is opaque, so there is nothing
      // in it to recognise, and "it did not look like a token" is exactly how
      // one ends up in a log.
      if (i == 2 && (segments[1] == 'b' || segments[1] == 't')) {
        segments[i] = '{token}';
      } else if (_uuid.hasMatch(segment)) {
        segments[i] = '{id}';
      } else if (_digits.hasMatch(segment)) {
        segments[i] = '{id}';
      } else if (_reference.hasMatch(segment)) {
        segments[i] = '{ref}';
      }
    }
    return segments.join('/');
  }
}

/// One request, as it will be written down.
///
/// Public because it is the part worth testing on its own: the middleware
/// around it is three lines and a stopwatch, and what actually has to be right
/// is what ends up in the string.
final class AccessLogLine {
  const AccessLogLine({
    required this.method,
    required this.path,
    required this.status,
    required this.milliseconds,
    required this.trace,
    required this.ip,
    required this.bytes,
  });

  final String method;
  final String path;
  final int status;
  final int milliseconds;
  final String trace;
  final String? ip;
  final String? bytes;

  /// A server error is somebody's night; a 4xx is usually the client's own
  /// doing. Sending both at the same level is how alerting on the log becomes
  /// impossible.
  String get severity {
    if (status >= HttpStatus.internalServerError) return 'ERROR';
    if (status >= HttpStatus.badRequest) return 'WARNING';
    return 'INFO';
  }

  String get text =>
      '$severity $method $path $status ${milliseconds}ms '
      '[$trace]';

  String get json => jsonEncode({
    'severity': severity,
    'message': '$method $path $status ${milliseconds}ms',
    // The field Cloud Logging joins entries on, and the same value the client
    // was handed in `X-Trace-Id` — so a traveller quoting one string in a
    // support message finds their own request and the stack trace behind it.
    'logging.googleapis.com/trace': trace,
    BelHeaders.traceId: trace,
    'httpRequest': {
      'requestMethod': method,
      'requestUrl': path,
      'status': status,
      'latency': '${(milliseconds / 1000).toStringAsFixed(3)}s',
      if (ip != null) 'remoteIp': ip,
      if (bytes != null) 'responseSize': bytes,
    },
  });
}
