import 'package:bel_api/src/adapters/styled_email_gateway.dart';
import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:test/test.dart';

final class _Capture implements NotificationGateway {
  OutboundMessage? last;

  @override
  Future<NotifyFailure?> send(OutboundMessage message) async {
    last = message;
    return null;
  }
}

void main() {
  final catalog = CatalogLoader.fromDirectory('packages/bel_localization/i18n');
  late _Capture inner;
  late StyledEmailGateway gateway;

  setUp(() {
    inner = _Capture();
    gateway = StyledEmailGateway(inner, catalog: catalog);
  });

  group('the chrome', () {
    test('a sign-in code is set once, large, under its own heading', () async {
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'a@b.cg',
          subject: 'Votre code BilletEnLigne : 436338',
          heading: 'Votre code de connexion',
          highlight: '436338',
          body:
              'Votre code de connexion BilletEnLigne est 436338.\n\n'
              'Il expire dans 5 minutes.\n\n'
              'Si vous n\'avez pas demandé ce code, ignorez ce message.',
        ),
      );

      final html = inner.last!.html!;
      expect(html, contains('Votre code de connexion</h1>'));

      // The subject carries the code so the inbox list is useful. Repeating it
      // above a copy set in 32px is how one short message says six digits
      // three times.
      expect(html, isNot(contains('Votre code BilletEnLigne : 436338')));

      // Once in the highlight, and not again in a paragraph underneath.
      expect('436338'.allMatches(html).length, 1);

      // The sentence carrying the code goes; the two that do not, stay.
      expect(html, contains('Il expire dans 5 minutes.'));
      expect(html, contains('ignorez ce message'));
    });

    test('the catalog wraps its own lines and the HTML unwraps them', () async {
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'a@b.cg',
          subject: 'Subject',
          // Hard-wrapped at seventy columns, exactly as every `body:` in the
          // catalog is, because the plain text is read in a terminal.
          body:
              'Il expire dans 5 minutes. Ne le communiquez à personne — nous ne\n'
              'vous le demanderons jamais.',
        ),
      );

      final html = inner.last!.html!;
      expect(html, contains('personne — nous ne vous le demanderons jamais.'));
      // The break belongs to the plain text and stays there.
      expect(html, isNot(contains('nous ne<br>')));
      expect(inner.last!.body, contains('\n'));
    });

    test('the plain text is never replaced, only added to', () async {
      const body = 'Votre place est confirmée.\n\nBZV–PNR le 15/08.';
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'a@b.cg',
          subject: 'Votre billet',
          body: body,
        ),
      );

      expect(inner.last!.body, body);
      expect(inner.last!.html, contains('Votre billet</h1>'));
      expect(inner.last!.html, contains('BZV–PNR le 15/08.'));
    });

    test('a message that brought its own layout is left alone', () async {
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'a@b.cg',
          subject: 'Votre billet',
          body: 'text',
          html: '<html>the boarding pass</html>',
        ),
      );

      expect(inner.last!.html, '<html>the boarding pass</html>');
    });

    test('an SMS is never dressed up', () async {
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.phone,
          to: '242069000001',
          body: 'Paiement confirmé.',
        ),
      );

      expect(inner.last!.html, isNull);
    });

    test('the footer speaks the language the body was rendered in', () async {
      for (final (language, expected) in [
        ('fr', 'Merci de ne pas y répondre'),
        ('en', 'Please do not reply'),
      ]) {
        await gateway.send(
          OutboundMessage(
            channel: SignInChannel.email,
            to: 'a@b.cg',
            subject: 'Subject',
            body: 'One line.',
            language: language,
          ),
        );
        expect(inner.last!.html, contains(expected));
      }
    });

    test('a body with nothing in it is not wrapped in chrome', () async {
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'a@b.cg',
          subject: 'Subject',
          body: '   ',
        ),
      );

      expect(inner.last!.html, isNull);
    });

    test('markup in a name cannot escape into the message', () async {
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'a@b.cg',
          subject: 'Bonjour <script>alert(1)</script>',
          body: 'Une ligne.',
        ),
      );

      expect(inner.last!.html, isNot(contains('<script>')));
      expect(inner.last!.html, contains('&lt;script&gt;'));
    });
  });
}
