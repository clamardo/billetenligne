import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/web/boarding_pass_page.dart';
import 'package:bel_api/src/infrastructure/web/printed_ticket_page.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /b/{token}` — the ticket, as a page (ADR-0026).
///
/// Off `/public/v1` for the same reason `/t/` is: this URL is read out at a
/// counter, typed off a printed slip, and previewed in a WhatsApp bubble.
/// `blt.cg/b/xxxx` survives all three. Everything under `/public/v1` is JSON
/// for a client; this is HTML for a person.
///
/// **`/b/` and not `/t/`** — `/t/` follows a coach and deliberately shows no
/// seat, no price and no name; this one is the seat and the name. Two URLs
/// with two audiences and two privacy rules; one prefix serving both is how a
/// follower link eventually renders a boarding pass.
///
/// **The page 404s on a dead token, and renders the same words for all three
/// reasons.** The follower page never 404s because it fetches its data and
/// cannot know; this one resolves the token server-side, so it has to answer —
/// and revoked, expired and never-issued being one answer is what stops a
/// dead link from telling its holder it was once real.
///
/// The **app claims this URL** (App Links / Universal Links). A traveller with
/// the app installed lands in the app; everybody else lands here. Same link
/// either way — an interstitial in front of a boarding pass would be the worst
/// screen in this product.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final services = context.read<Services>();
  final requested = context.request.uri.queryParameters['lang'] ?? 'fr';
  final language = requested.startsWith('en') ? 'en' : 'fr';

  final ticket = await services.ticketLinks.open(
    token: token,
    now: services.clock.now(),
  );

  if (ticket == null) {
    return Response(
      statusCode: HttpStatus.notFound,
      body: BoardingPassPage.renderGone(
        catalog: Services.translations,
        language: language,
      ),
      headers: _headers,
    );
  }

  // `?format=` turns the same link into the printable ticket. One URL, not
  // two: a vendor at a counter, a customer forwarding it to the cousin doing
  // the collecting, and a passenger opening it at the door are all holding
  // the same address, and a second one would be a second thing to lose.
  //
  // The format is a query parameter rather than an operator setting applied
  // silently, because the choice is made at the printer: the same agency
  // prints three-to-a-page all morning and one full page for the customer
  // who asked for a receipt.
  final format = _format(context.request.uri.queryParameters['format']);
  if (format != null) {
    return Response(
      body: PrintedTicketPage.render(
        ticket: ticket,
        design: _designFor(format),
        catalog: Services.translations,
        language: language,
        autoPrint: context.request.uri.queryParameters['auto'] == '1',
      ),
      headers: _headers,
    );
  }

  return Response(
    body: BoardingPassPage.render(
      ticket: ticket,
      catalog: Services.translations,
      language: language,
    ),
    headers: _headers,
  );
}

/// Null means "not a print request" — an unknown value is treated as absent
/// rather than defaulted, so a mistyped link renders the page the reader
/// expected instead of silently sending them to a printer.
TicketFormat? _format(String? raw) {
  for (final format in TicketFormat.values) {
    if (format.name == raw) return format;
  }
  return null;
}

/// The operator's own design, once they have saved one. Until then the
/// starter, in their hue: a counter must be able to print on its first day
/// without anybody having opened a builder.
TicketDesign _designFor(TicketFormat format) => switch (format) {
  TicketFormat.boardingPass => TicketStarters.classicPass,
  TicketFormat.a4 => TicketStarters.fullPageReceipt,
};

const Map<String, Object> _headers = {
  HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
  // A ticket, with names on it and a QR that boards a coach. No cache but the
  // reader's own screen — and no cache at all rather than a private one,
  // because the handset this opens on is often shared.
  HttpHeaders.cacheControlHeader: 'private, no-store',
  // A boarding pass is exactly the thing somebody would wrap in an ad page,
  // and the referrer of this URL *is* the credential.
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
};
