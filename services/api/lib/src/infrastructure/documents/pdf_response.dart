import 'dart:io';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:dart_frog/dart_frog.dart';

import '../../application/ports/payout_desk.dart';
import 'statement_pdf.dart';

/// One statement, as a downloadable document.
///
/// Shared by the console and the back office because it is the *same
/// document*: a platform reviewer looking at a payout and the operator being
/// paid must not be able to produce two different pages from one run, or a
/// dispute becomes an argument about which print is real.
///
/// Three headers do the work:
///
///   * `Content-Disposition: attachment` with a filename built from the
///     operator and the period, because a browser's default is `pdf.pdf` and
///     a folder of those is unusable.
///   * `no-store`, like every other authenticated read here. A statement in a
///     shared browser's cache is somebody's revenue.
///   * `Content-Length`, so a download shows a progress bar and a truncated
///     transfer is detectable rather than a silently short document.
Response statementResponse({
  required PayoutRun run,
  required TranslationCatalog catalog,
  required String operatorName,
  required String language,
  required String trace,
}) {
  final bytes = StatementPdf.render(
    run: run,
    catalog: catalog,
    operatorName: operatorName,
    language: language,
  );

  return Response.bytes(
    body: bytes,
    headers: {
      HttpHeaders.contentTypeHeader: 'application/pdf',
      HttpHeaders.contentLengthHeader: '${bytes.length}',
      HttpHeaders.contentDisposition:
          'attachment; filename="${statementFilename(run, operatorName)}"',
      HttpHeaders.cacheControlHeader: 'private, no-store',
      BelHeaders.traceId: trace,
    },
  );
}

/// `releve-ocean-du-nord-2026-08-01.pdf`.
///
/// ASCII only, and deliberately: a filename with accents in it survives most
/// of the way and then arrives mangled through one proxy or one mail client,
/// and the operator who cannot open the attachment is the one who most needs
/// to.
String statementFilename(PayoutRun run, String operatorName) {
  final slug = _slug(operatorName);
  final from = run.statement.from;
  final date =
      '${from.year}-'
      '${from.month.toString().padLeft(2, '0')}-'
      '${from.day.toString().padLeft(2, '0')}';
  return 'releve-$slug-$date.pdf';
}

String _slug(String value) {
  const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyy';

  final out = StringBuffer();
  var lastWasDash = true;

  for (final rune in value.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final index = from.indexOf(char);
    final mapped = index >= 0 ? to[index] : char;

    if (RegExp('[a-z0-9]').hasMatch(mapped)) {
      out.write(mapped);
      lastWasDash = false;
    } else if (!lastWasDash) {
      out.write('-');
      lastWasDash = true;
    }
  }

  final slug = out.toString();
  return slug.endsWith('-')
      ? slug.substring(0, slug.length - 1)
      : (slug.isEmpty ? 'operateur' : slug);
}
