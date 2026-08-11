import 'dart:convert';
import 'dart:io';

import 'package:bel_api/src/application/ports/payout_desk.dart';
import 'package:bel_api/src/infrastructure/documents/pdf_writer.dart';
import 'package:bel_api/src/infrastructure/documents/statement_pdf.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:test/test.dart';

/// The catalog the server actually ships. Loaded from disk rather than
/// stubbed, because half of what this document has to get right is whether
/// the sentence exists at all — a missing key renders as a key, on a page an
/// accountant files.
final _catalog = CatalogLoader.fromDirectory(_i18nDirectory());

String _i18nDirectory() {
  for (final up in ['..', '../..', '../../..', '.']) {
    final candidate = '$up/packages/bel_localization/i18n';
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('i18n directory not found from ${Directory.current.path}');
}

PayoutRun _run({
  String state = 'approved',
  int onlineGross = 3708000,
  int cashGross = 1692000,
  int commission = 185400,
  int serviceFees = 42000,
  int refunds = 126000,
  int payable = 5121600,
  int tills = 1692000,
  String? destination = 'MoMo Business ****4471',
  DateTime? paidAt,
  String? reference,
  String operatorName = 'Océan du Nord',
}) => PayoutRun(
  id: 'a1b2c3d4-0000-0000-0000-000000000001',
  operatorName: operatorName,
  state: state,
  preparedAt: DateTime.utc(2026, 8, 8, 7),
  destination: destination,
  paidAt: paidAt,
  reference: reference,
  statement: PayoutStatement(
    operatorId: 'op-1',
    from: DateTime.utc(2026, 7, 31, 23),
    to: DateTime.utc(2026, 8, 7, 23),
    onlineSalesCount: 412,
    onlineGross: Money.xaf(onlineGross),
    cashSalesCount: 188,
    cashGross: Money.xaf(cashGross),
    commission: Money.xaf(commission),
    serviceFees: Money.xaf(serviceFees),
    refunds: Money.xaf(refunds),
    payable: Money.xaf(payable),
    tills: Money.xaf(tills),
  ),
);

/// The content stream, as text. The whole file is WinAnsi bytes and nothing is
/// compressed on purpose, so this is exactly what a reader would draw.
String _text(List<int> bytes) => latin1.decode(bytes);

void main() {
  group('the PDF a reader has to be able to open', () {
    test('it is a structurally complete PDF, not a byte soup', () {
      final bytes = StatementPdf.render(
        run: _run(),
        catalog: _catalog,
        operatorName: 'Océan du Nord',
      );
      final text = _text(bytes);

      // A reader that cannot parse the trailer shows nothing at all, rather
      // than showing the text it could find — so these four are the whole
      // difference between a document and a download that fails to open.
      expect(text, startsWith('%PDF-1.7'));
      expect(text, contains('/Type /Catalog'));
      expect(text, contains('xref'));
      expect(text, endsWith('%%EOF\n'));
      expect(text, contains('startxref'));
    });

    test('the xref offsets point at the objects they claim to', () {
      final bytes = StatementPdf.render(
        run: _run(),
        catalog: _catalog,
        operatorName: 'Océan du Nord',
      );
      final text = _text(bytes);

      final offsets = RegExp(
        r'^(\d{10}) 00000 n $',
        multiLine: true,
      ).allMatches(text).map((m) => int.parse(m.group(1)!)).toList();

      expect(offsets, hasLength(8));
      for (var i = 0; i < offsets.length; i++) {
        // Every offset must land exactly on `N 0 obj`. This is the check that
        // catches the classic mistake — counting a stream's length in UTF-8
        // while writing it in Latin-1 — which shifts every later object and
        // renders as a blank page rather than as an error.
        expect(
          text.substring(offsets[i], offsets[i] + '${i + 1} 0 obj'.length),
          '${i + 1} 0 obj',
        );
      }
    });

    test('the declared stream length is the bytes actually written', () {
      final bytes = StatementPdf.render(
        run: _run(),
        catalog: _catalog,
        operatorName: 'Océan du Nord',
      );
      final text = _text(bytes);

      final declared = int.parse(
        RegExp(r'<< /Length (\d+) >>').firstMatch(text)!.group(1)!,
      );
      final start = text.indexOf('stream\n') + 'stream\n'.length;
      final end = text.indexOf('\nendstream');

      expect(end - start, declared);
    });
  });

  group('what the statement says', () {
    test('the figures of §6.2 are on the page, as money', () {
      final text = _text(
        StatementPdf.render(
          run: _run(),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );

      // Gross online and cash, both counts, the commission as a deduction,
      // and the net. Read out of the content stream, which is what a reader
      // draws — asserting on the model would prove nothing about the page.
      expect(text, contains('412 billets'));
      expect(text, contains('188 billets'));
      expect(text, contains('3'));
      expect(text, contains('Ventes en ligne'));
      expect(text, contains('Ventes guichet'));
      expect(text, contains('Net à payer'));
    });

    test('the commission rate is derived from these sales, not from a row', () {
      // 185 400 of 3 708 000 is exactly 5%.
      final text = _text(
        StatementPdf.render(
          run: _run(),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );

      // Escaped, because that is how a PDF literal string carries a
      // parenthesis — asserting on the unescaped form would pass on a file
      // no reader can open.
      expect(text, contains(r'Commission \(5 % en ligne\)'));
    });

    test('a rate that is not whole is not rounded into one', () {
      final text = _text(
        StatementPdf.render(
          run: _run(onlineGross: 1000000, commission: 42500),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );

      expect(text, contains('4.25 %'));
    });

    test('the cash question is answered on the document', () {
      final text = _text(
        StatementPdf.render(
          run: _run(),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );

      // §6.2 names this as the number-one operator question. Answering it in
      // a footnote costs one line and saves a phone call every week.
      expect(text, contains('ne donnent lieu'));
      expect(text, contains('rapprochement'));
    });

    test('a week of nothing but cash is a debt, and says so', () {
      final text = _text(
        StatementPdf.render(
          // Sold nothing online, took cash all week: the service fees are
          // owed to us, and the net is negative.
          run: _run(
            onlineGross: 0,
            commission: 0,
            payable: 54000,
            tills: 96000,
          ),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );

      // A heading that says who owes whom, and a positive number under it —
      // rather than a "net à payer" of minus forty-two thousand, which is
      // read as a payment by everybody who is not an accountant.
      expect(text, contains('Solde dû à BilletEnLigne'));
      expect(text, isNot(contains('Net à payer')));
      expect(text, contains('reporté sur le relevé suivant'));
    });

    test('the state of the payout is on the page', () {
      final draft = _text(
        StatementPdf.render(
          run: _run(state: 'draft'),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );
      final paid = _text(
        StatementPdf.render(
          run: _run(
            state: 'paid',
            paidAt: DateTime.utc(2026, 8, 12, 9),
            reference: 'MOMO-99213',
          ),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );

      // The same figures mean entirely different things, and a document that
      // does not say which is one somebody will read as the wrong one.
      expect(draft, contains('Brouillon'));
      expect(paid, contains('Vers'));
      expect(paid, contains('12/08/2026'));
      expect(paid, contains('MOMO-99213'));
    });

    test('the destination is named when there is one', () {
      final text = _text(
        StatementPdf.render(
          run: _run(),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );
      expect(text, contains('MoMo Business ****4471'));
    });

    test('English renders from the same catalog', () {
      final text = _text(
        StatementPdf.render(
          run: _run(),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
          language: 'en',
        ),
      );

      expect(text, contains('Payout statement'));
      expect(text, contains('Online sales'));
      // Day-first in both languages: two different orders on two prints of
      // the same statement is worse than one ambiguous date.
      expect(text, contains('01/08/2026'));
    });

    test('no line is invented for something the ledger does not hold', () {
      final text = _text(
        StatementPdf.render(
          run: _run(),
          catalog: _catalog,
          operatorName: 'Océan du Nord',
        ),
      );

      // §6.2's mock shows change fees and dispute adjustments; neither
      // exists yet. A `0 FCFA` row for something we never compute would be a
      // more convincing lie than leaving it out.
      expect(text, isNot(contains('Ajustements')));
      expect(text, isNot(contains('modification')));
    });
  });

  group('the writer itself', () {
    test('accented French survives as WinAnsi rather than as UTF-8', () {
      final pdf = PdfDocument()
        ..text('Été à Pointe-Noire', x: 10, at: 10, size: 10);
      final text = _text(pdf.build());

      // Two bytes per accent would be two glyphs on the page — `Ã©` is the
      // classic rendering of this bug, and it is only visible on the printed
      // document.
      expect(text, contains('(Été à Pointe-Noire)'));
    });

    test('a narrow no-break space becomes one the encoding has', () {
      // What `Money.format` puts between the thousands. Dropping it renders
      // 3429600, a different-looking number on a page somebody is checking.
      final pdf = PdfDocument()
        ..text('3 429 600 FCFA', x: 10, at: 10, size: 10);
      final text = _text(pdf.build());

      expect(text, contains('3 429 600 FCFA'));
    });

    test('a deduction keeps its minus sign', () {
      // `Money.format` uses U+2212, which WinAnsi does not have. Rendering it
      // as `?` turns `-185 400` into `?185 400` on a page of figures, and a
      // missing minus sign on a statement is not a cosmetic bug.
      final pdf = PdfDocument()
        ..amount(
          (-const Money.xaf(185400)).format(locale: 'fr'),
          right: 500,
          size: 10,
        );
      final text = _text(pdf.build());

      // Every space in there is a no-break space in WinAnsi: the narrow one
      // between the thousands and the one before the symbol both map to
      // U+00A0, which is the byte a reader draws as a space.
      expect(text, contains('(-185\u00a0400\u00a0FCFA)'));
    });

    test('parentheses in a name cannot break the file', () {
      final pdf = PdfDocument()
        ..text('Transports (Congo) SARL', x: 10, at: 10, size: 10);
      final text = _text(pdf.build());

      // An unescaped `)` ends the string early and everything after it is
      // read as operators — a company name is the likeliest place for one.
      expect(text, contains(r'(Transports \(Congo\) SARL)'));
    });

    test('a character the encoding has no room for is visible, not silent', () {
      final pdf = PdfDocument()..text('Компания', x: 10, at: 10, size: 10);
      final text = _text(pdf.build());

      // A visible `?` in an operator's name is a support call. A silent drop
      // is a document that quietly names the wrong company.
      expect(text, contains('(????????)'));
    });

    test('a figure column is right-aligned by its own width', () {
      final pdf = PdfDocument()
        ..amount('9 300 FCFA', right: 500, size: 10)
        ..amount('3 708 000 FCFA', right: 500, size: 10, at: 20);
      final text = _text(pdf.build());

      final xs = RegExp(
        r'^([\d.]+) [\d.]+ Td$',
        multiLine: true,
      ).allMatches(text).map((m) => double.parse(m.group(1)!)).toList();

      // The longer figure starts further left, and both end at 500.
      expect(xs, hasLength(2));
      expect(xs[1], lessThan(xs[0]));
      expect(xs[0] + '9 300 FCFA'.length * 6, closeTo(500, 0.5));
    });
  });
}
