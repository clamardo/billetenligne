import 'dart:io';

import '../application/ports/notification_gateway.dart';

/// What you get when no connection string is configured (ADR-0019).
///
/// **Blank is a supported state**, and this is why: a fresh clone runs, and
/// the sign-in code a developer needs is in the log rather than on somebody's
/// handset. Nobody's phone receives an SMS from someone else's laptop and no
/// test run costs money.
///
/// The code is printed in full, on purpose. It is a `demo-` emulator loop with
/// no real accounts in it; the alternative is a developer who cannot sign in.
/// The guard is that this adapter is selected by the *absence* of a real
/// connection string, so it cannot be the one running in production without
/// somebody having deleted the configuration first.
final class LoggingNotificationGateway implements NotificationGateway {
  const LoggingNotificationGateway();

  @override
  Future<NotifyFailure?> send(OutboundMessage message) async {
    final channel = message.channel.name.toUpperCase();
    stdout.writeln(
      '[$channel → ${message.to}] '
      '${message.subject == null ? '' : '${message.subject}: '}'
      '${message.body}',
    );
    return null;
  }
}

/// Records everything and asserts on it. Tests only.
final class FakeNotificationGateway implements NotificationGateway {
  FakeNotificationGateway({this.failWith});

  final List<OutboundMessage> sent = [];

  /// Set to make every send fail, which is how the "we could not reach you"
  /// path gets exercised at all.
  NotifyFailure? failWith;

  OutboundMessage get last => sent.last;

  OutboundMessage? lastTo(String recipient) {
    for (final m in sent.reversed) {
      if (m.to == recipient) return m;
    }
    return null;
  }

  @override
  Future<NotifyFailure?> send(OutboundMessage message) async {
    if (failWith != null) return failWith;
    sent.add(message);
    return null;
  }
}
