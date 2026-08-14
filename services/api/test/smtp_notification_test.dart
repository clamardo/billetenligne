import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bel_api/src/adapters/smtp_notification_gateway.dart';
import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:test/test.dart';

/// The local mail catcher's sender (ADR-0020).
///
/// Tested against a socket that speaks SMTP rather than against a mock,
/// because everything that can go wrong here is on the wire: a reply code
/// read from the wrong line, a boundary that eats the body, an accented
/// subject that arrives as mojibake. A fake with a `send()` method would
/// prove none of it.
void main() {
  late _FakeSmtp server;

  setUp(() async => server = await _FakeSmtp.start());
  tearDown(() async => server.close());

  SmtpNotificationGateway gatewayTo(
    _FakeSmtp server, {
    NotificationGateway fallback = const LoggingSink(),
  }) => SmtpNotificationGateway(
    host: '127.0.0.1',
    port: server.port,
    emailFrom: 'no-reply@billetenligne.local',
    fallback: fallback,
  );

  group('an email on the wire', () {
    test('arrives with its envelope, its subject and its body', () async {
      final failure = await gatewayTo(server).send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'angele@demo.billetenligne.cg',
          subject: 'Votre code BilletEnLigne',
          body: 'Votre code est 123456.',
        ),
      );

      expect(failure, isNull);
      final mail = await server.received;
      expect(mail.from, 'no-reply@billetenligne.local');
      expect(mail.to, 'angele@demo.billetenligne.cg');
      // Base64, because the body is French and a bare accent on the wire is
      // a question mark in somebody's inbox.
      expect(mail.textBody, 'Votre code est 123456.');
    });

    test('an accented subject is encoded, not sent raw', () async {
      await gatewayTo(server).send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'a@b.cg',
          subject: 'Réservation confirmée',
          body: 'x',
        ),
      );

      final mail = await server.received;
      // RFC 2047. Without it this is the line an operator sees in their
      // inbox list, and it is the one place mojibake is unmissable.
      expect(mail.header('Subject'), startsWith('=?UTF-8?B?'));
      expect(mail.subjectDecoded, 'Réservation confirmée');
    });

    test('a statement travels with its PDF', () async {
      await gatewayTo(server).send(
        OutboundMessage(
          channel: SignInChannel.email,
          to: 'prosper@demo.billetenligne.cg',
          subject: 'Votre relevé',
          body: 'Le relevé est en pièce jointe.',
          attachments: [
            OutboundAttachment(
              name: 'releve-2026-08.pdf',
              contentType: 'application/pdf',
              bytes: List<int>.generate(3000, (i) => i % 256),
            ),
          ],
        ),
      );

      final mail = await server.received;
      // The point of the whole adapter: until it existed a statement was a
      // line of log saying a PDF had existed somewhere.
      expect(mail.raw, contains('multipart/mixed'));
      expect(mail.raw, contains('filename="releve-2026-08.pdf"'));
      expect(mail.raw, contains('Content-Type: application/pdf'));
      expect(mail.textBody, 'Le relevé est en pièce jointe.');
      // No line on the wire exceeds what SMTP tolerates. A 20 KB QR on one
      // line is a message some servers truncate and others refuse.
      // The fake reassembles the payload one wire line per `\n`, so this is
      // the length of what was actually written to the socket.
      expect(mail.raw.split('\n').every((l) => l.length <= 998), isTrue);
    });
  });

  group('what it refuses to pretend', () {
    test('an SMS is not mailed anywhere', () async {
      final log = _Recording();
      final failure = await gatewayTo(server, fallback: log).send(
        const OutboundMessage(
          channel: SignInChannel.phone,
          to: '+242069000001',
          body: 'Paiement confirmé.',
        ),
      );

      expect(failure, isNull);
      // There is no such thing as SMS over SMTP. Mailing the text somewhere
      // would be a channel that looks delivered and is not.
      expect(log.sent, hasLength(1));
      expect(server.connections, 0);
    });

    test('a mail catcher that is not running does not break sign-in', () async {
      final log = _Recording();
      final closed = await _FakeSmtp.start();
      final port = closed.port;
      await closed.close();

      final failure =
          await SmtpNotificationGateway(
            host: '127.0.0.1',
            port: port,
            emailFrom: 'no-reply@billetenligne.local',
            fallback: log,
            timeout: const Duration(milliseconds: 300),
          ).send(
            const OutboundMessage(
              channel: SignInChannel.email,
              to: 'a@b.cg',
              subject: 's',
              body: 'the code is 424242',
            ),
          );

      // A stopped container is a fact about this laptop, not about the
      // address. The developer still gets their code.
      expect(failure, isNull);
      expect(log.sent.single.body, contains('424242'));
    });

    test(
      'a server that refuses the recipient falls back rather than lies',
      () async {
        final log = _Recording();
        final rude = await _FakeSmtp.start(rejectRecipient: true);
        addTearDown(rude.close);

        final failure = await gatewayTo(rude, fallback: log).send(
          const OutboundMessage(
            channel: SignInChannel.email,
            to: 'nobody@nowhere',
            subject: 's',
            body: 'b',
          ),
        );

        expect(failure, isNull);
        expect(log.sent, hasLength(1));
      },
    );
  });

  group('choosing it at all', () {
    test('no host means no adapter, so composition falls through', () {
      expect(SmtpNotificationGateway.tryParse(null, emailFrom: 'a@b'), isNull);
      expect(SmtpNotificationGateway.tryParse('  ', emailFrom: 'a@b'), isNull);
    });

    test('a port nobody can parse is a refusal, not a default', () {
      // Silently falling back to 1025 would send mail to whatever happens to
      // be on that port on a machine somebody configured deliberately.
      expect(
        SmtpNotificationGateway.tryParse(
          'localhost',
          port: 'eleven',
          emailFrom: 'a@b',
        ),
        isNull,
      );
      expect(
        SmtpNotificationGateway.tryParse(
          'localhost',
          port: '2525',
          emailFrom: 'a@b',
        )!.port,
        2525,
      );
      expect(
        SmtpNotificationGateway.tryParse('localhost', emailFrom: 'a@b')!.port,
        1025,
      );
    });
  });
}

/// Records what it was asked to send. The log, without the noise.
final class _Recording implements NotificationGateway {
  final List<OutboundMessage> sent = [];

  @override
  Future<NotifyFailure?> send(OutboundMessage message) async {
    sent.add(message);
    return null;
  }
}

/// Enough of an SMTP server to answer one conversation.
final class _FakeSmtp {
  _FakeSmtp._(this._socket, {required this.rejectRecipient}) {
    _socket.listen(_handle);
  }

  static Future<_FakeSmtp> start({bool rejectRecipient = false}) async =>
      _FakeSmtp._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        rejectRecipient: rejectRecipient,
      );

  final ServerSocket _socket;
  final bool rejectRecipient;
  final _mail = Completer<_Mail>();

  var connections = 0;

  int get port => _socket.port;
  Future<_Mail> get received =>
      _mail.future.timeout(const Duration(seconds: 5));

  void _handle(Socket client) {
    connections++;
    var from = '';
    var to = '';
    var inData = false;
    final data = StringBuffer();

    client.write('220 fake ESMTP\r\n');

    // Buffered because a DATA payload arrives in packets that do not line up
    // with lines — the bug this fake exists to be able to catch.
    var buffer = '';
    client.listen(
      (bytes) {
        buffer += utf8.decode(bytes);
        while (buffer.contains('\r\n')) {
          final i = buffer.indexOf('\r\n');
          final line = buffer.substring(0, i);
          buffer = buffer.substring(i + 2);

          if (inData) {
            if (line == '.') {
              inData = false;
              client.write('250 queued\r\n');
              if (!_mail.isCompleted) {
                _mail.complete(_Mail(from: from, to: to, raw: data.toString()));
              }
              continue;
            }
            data.writeln(line.replaceAll('\r', ''));
            continue;
          }

          if (line.startsWith('EHLO')) {
            // Multi-line, on purpose: a reader that took the first line as the
            // reply would break here and nowhere else.
            client.write('250-fake\r\n250 SIZE 10485760\r\n');
          } else if (line.startsWith('MAIL FROM:')) {
            from = _address(line);
            client.write('250 ok\r\n');
          } else if (line.startsWith('RCPT TO:')) {
            to = _address(line);
            client.write(
              rejectRecipient ? '550 no such user\r\n' : '250 ok\r\n',
            );
          } else if (line == 'DATA') {
            inData = true;
            client.write('354 go ahead\r\n');
          } else if (line == 'QUIT') {
            client.write('221 bye\r\n');
            client.destroy();
          }
        }
      },
      onError: (_) {},
      cancelOnError: true,
    );
  }

  static String _address(String line) {
    final open = line.indexOf('<');
    final close = line.indexOf('>');
    return open < 0 || close < 0 ? '' : line.substring(open + 1, close);
  }

  Future<void> close() => _socket.close();
}

/// One received message, parsed just far enough to assert on.
final class _Mail {
  const _Mail({required this.from, required this.to, required this.raw});

  final String from;
  final String to;
  final String raw;

  String? header(String name) {
    for (final line in raw.split('\n')) {
      if (line.toLowerCase().startsWith('${name.toLowerCase()}: ')) {
        return line.substring(name.length + 2).trim();
      }
    }
    return null;
  }

  String get subjectDecoded {
    final value = header('Subject') ?? '';
    if (!value.startsWith('=?UTF-8?B?')) return value;
    return utf8.decode(base64.decode(value.substring(10, value.length - 2)));
  }

  /// The first `text/plain` part, decoded.
  String get textBody {
    final lines = raw.split('\n');
    final start = lines.indexWhere((l) => l.contains('text/plain'));
    if (start < 0) return '';
    var i = start;
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      i++;
    }
    final encoded = StringBuffer();
    for (var j = i + 1; j < lines.length; j++) {
      final line = lines[j].trim();
      if (line.isEmpty || line.startsWith('--')) break;
      encoded.write(line);
    }
    return utf8.decode(base64.decode(encoded.toString()));
  }
}
