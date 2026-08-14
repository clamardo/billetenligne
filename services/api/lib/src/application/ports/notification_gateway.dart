import 'package:bel_contracts/bel_contracts.dart';

/// One outbound message.
///
/// The **body is already rendered**, in the recipient's stored language, from
/// the shared YAML catalog (ADR-0008 / ADR-0019 rule 3). Nothing below this
/// port chooses words: an adapter that reached for a template would be an
/// adapter that has to know a language, and there would then be two places
/// prose can come from.
final class OutboundMessage {
  const OutboundMessage({
    required this.channel,
    required this.to,
    required this.body,
    this.subject,
    this.html,
    this.attachments = const [],
    this.eventId,
    this.language = 'fr',
    this.heading,
    this.highlight,
  });

  final SignInChannel channel;
  final String to;

  /// Always present, and always readable on its own. The HTML below is an
  /// improvement on this, never a replacement for it: a client that shows
  /// plain text must still be able to board somebody.
  final String body;

  /// Email only. Null on SMS, where there is no such thing.
  final String? subject;

  /// Email only, and optional. Null means the plain text is the whole message,
  /// which is what almost everything here sends.
  final String? html;

  /// Files that travel with the message.
  ///
  /// One case so far and it is the point of ADR-0026: the ticket's QR, as a
  /// PNG, so the code is on the handset rather than behind a link. An inbox
  /// works with the radio off; a link does not.
  final List<OutboundAttachment> attachments;

  /// Idempotency for the outbox: `(eventId, channel, recipient)` is unique, so
  /// a retried drain cannot double-send (ADR-0019 rule 2). Null means "send
  /// once, now" — which is honest for a sign-in code, whose whole value is
  /// that it is fresh.
  final String? eventId;

  /// The language [body] was already rendered in.
  ///
  /// Carried rather than re-derived because the chrome around the words needs
  /// it too — a footer in French under a Lingala body would be a second place
  /// language is decided, which is exactly what this port exists to prevent.
  final String language;

  /// The sentence at the top of the styled message, when the subject would
  /// make a poor one.
  ///
  /// Usually null, and then the subject is used — for most messages the line
  /// that made somebody open it is the right line to open with. A sign-in
  /// code is the exception: its subject carries the code so the inbox list is
  /// useful, and repeating it above a copy of it set in 32px is how a short
  /// message ends up saying the same six digits three times.
  final String? heading;

  /// One short string worth setting in large type: the sign-in code.
  ///
  /// **A hint about emphasis, not a second copy of the message.** It always
  /// appears in [body] as well, because the plain text has to stand alone —
  /// this only tells the chrome which few characters somebody is squinting
  /// for. Null for every message whose point is a sentence rather than a
  /// value.
  final String? highlight;

  OutboundMessage withHtml(String html) => OutboundMessage(
    channel: channel,
    to: to,
    body: body,
    subject: subject,
    html: html,
    attachments: attachments,
    eventId: eventId,
    language: language,
    heading: heading,
    highlight: highlight,
  );
}

/// A file travelling with a message.
final class OutboundAttachment {
  const OutboundAttachment({
    required this.name,
    required this.contentType,
    required this.bytes,
  });

  /// What the recipient sees in their mail client, so it says which seat:
  /// `BEL-4KQ2M9-12A.png` is a passenger finding their own code among three.
  final String name;
  final String contentType;
  final List<int> bytes;
}

/// Why a send did not happen. Coarse on purpose: the useful distinction is
/// "the address is wrong" (the user must fix it) versus "the rail is down"
/// (we must retry), and a taxonomy finer than that goes stale.
enum NotifyFailure { invalidRecipient, railUnavailable, rejected }

/// SMS and transactional email, behind one port (ADR-0019).
///
/// Adapters: ACS in production and shared dev, a logging one when no
/// connection string is configured — **blank is a supported state**, so a new
/// engineer clones the repo and everything runs, writing messages to the log
/// instead of a real handset — and a recording fake in tests.
abstract interface class NotificationGateway {
  /// Null on success, a reason on failure. Deliberately not a thrown
  /// exception: a message that did not send is an expected outcome on this
  /// rail, and the caller has to decide what to tell the user either way.
  Future<NotifyFailure?> send(OutboundMessage message);
}
