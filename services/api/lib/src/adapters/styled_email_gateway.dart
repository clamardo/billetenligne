import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_localization/bel_localization.dart';

import '../application/ports/notification_gateway.dart';
import '../infrastructure/web/email_shell.dart';

/// Draws the house chrome around every e-mail on its way out.
///
/// **A decorator rather than fourteen call sites.** The outbox composes a
/// dozen kinds of message and the sign-in path composes one more; giving each
/// its own template would mean fourteen places a palette can drift and
/// fourteen chances to forget. Every one of them already produces a subject
/// and a body in the recipient's language, which is all the chrome needs.
///
/// **It never invents a word.** The heading is the subject that was already
/// rendered from the catalog and the paragraphs are the plain-text body split
/// where it was already split; the only prose this adds is the footer, which
/// is itself a catalog key. So the styled message and the plain one say
/// exactly the same thing, and the plain one is still the message.
///
/// **A message that already has HTML passes through untouched.** The ticket
/// builds its own, because a boarding pass is a layout rather than a letter.
final class StyledEmailGateway implements NotificationGateway {
  const StyledEmailGateway(this._inner, {required TranslationCatalog catalog})
    : _catalog = catalog;

  final NotificationGateway _inner;
  final TranslationCatalog _catalog;

  @override
  Future<NotifyFailure?> send(OutboundMessage message) {
    if (message.channel != SignInChannel.email || message.html != null) {
      return _inner.send(message);
    }

    final paragraphs = EmailShell.paragraphsOf(message.body);

    // Nothing to draw a letter around. A body that is one line with no
    // subject is a message the chrome would make longer without making it
    // clearer, so it goes as it is.
    if (paragraphs.isEmpty) return _inner.send(message);

    // The code appears in the first paragraph as well — the plain text has to
    // read on its own — so highlighting it here would print it twice. The
    // sentence that carries it is the one worth dropping, and only that one.
    final highlight = message.highlight;
    final rest = highlight == null
        ? paragraphs
        : [
            for (final p in paragraphs)
              if (!p.contains(highlight)) p,
          ];

    return _inner.send(
      message.withHtml(
        EmailShell.render(
          catalog: _catalog,
          language: message.language,
          heading: message.heading ?? message.subject ?? paragraphs.first,
          // With no heading and no subject the first paragraph became the
          // heading, so printing it again underneath would say it twice.
          paragraphs: message.heading == null && message.subject == null
              ? rest.skip(1).toList()
              : rest,
          highlight: highlight,
        ),
      ),
    );
  }
}
