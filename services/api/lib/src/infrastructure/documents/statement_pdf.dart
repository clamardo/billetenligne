import 'dart:typed_data';

import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';

import '../../application/ports/payout_desk.dart';
import 'pdf_writer.dart';

/// The payout statement as a commercial document (`04-payments.md` §6.2).
///
/// The console already renders these numbers on a screen. This exists because
/// a screen is not a document: an operator's accountant files a statement, a
/// bank asks for one, and a dispute six months from now is settled by what we
/// sent rather than by what a page renders today.
///
/// Four things it does that the screen does not have to:
///
///   * **It says what it is, once, at the top** — who, which period, which
///     statement number — because a printed page with no header is a page
///     nobody can file.
///   * **It states the state of the payout.** A draft statement and a paid one
///     contain the same figures and mean entirely different things, and a
///     document that does not say which is a document somebody will read as
///     the wrong one.
///   * **It answers the cash question on the page.** §6.2 names it as the
///     number-one operator question: cash sales appear in full and pay out
///     nothing, because the operator is already holding the money. Answering
///     it in a footnote costs one line and saves a phone call every week.
///   * **It never invents a line.** The mock in §6.2 shows change fees and
///     dispute adjustments; neither exists in the ledger yet, and a `0 FCFA`
///     row for something we do not compute would be a more convincing lie
///     than leaving it out.
///
/// Rendered server-side, in the reader's language, because the server is the
/// only place prose is produced (ADR-0008). French is the fallback and the
/// default: §6.2 asks for a French commercial document, and this is a market
/// where the tax authority reads French.
abstract final class StatementPdf {
  static const _margin = 48.0;
  static const _right = 547.0;

  static Uint8List render({
    required PayoutRun run,
    required TranslationCatalog catalog,
    required String operatorName,
    String language = 'fr',
  }) {
    final t = CatalogTranslator(catalog, language);
    final s = run.statement;
    final pdf = PdfDocument();

    pdf.band(from: 0, to: pdf.width, top: 0, depth: 96);

    pdf.text(
      t('statement.title'),
      x: _margin,
      at: 44,
      size: 18,
      font: PdfDocument.helveticaBold,
    );
    pdf.text(operatorName, x: _margin, at: 66, size: 12);
    pdf.text(
      t('statement.reference', {'id': _shortId(run.id)}),
      x: _margin,
      at: 84,
      size: 8,
    );

    // The period, right-aligned against the header, because it is the second
    // thing anybody checks and the first thing they look for when a stack of
    // these is on a desk.
    pdf.text(
      t('statement.period', {
        'from': _date(s.from, language),
        'to': _date(s.to.subtract(const Duration(days: 1)), language),
      }),
      x: 300,
      at: 66,
      size: 10,
    );
    pdf.text(
      t('statement.preparedAt', {'date': _date(run.preparedAt, language)}),
      x: 300,
      at: 84,
      size: 8,
    );

    pdf.y = 140;

    _heading(pdf, t('statement.sections.sales'));

    _line(
      pdf,
      label: t('statement.onlineSales'),
      note: t('statement.tickets', {'count': s.onlineSalesCount}),
      amount: _money(s.onlineGross, language),
    );
    _line(
      pdf,
      label: t('statement.cashSales'),
      note: t('statement.tickets', {'count': s.cashSalesCount}),
      amount: _money(s.cashGross, language),
    );

    pdf.y += 12;
    _heading(pdf, t('statement.sections.deductions'));

    // Signed on the page rather than described as a deduction: a column of
    // figures where some are taken away and none carry a minus sign is a
    // column somebody adds up wrongly.
    _line(
      pdf,
      label: t('statement.commission', {'rate': _rate(s)}),
      amount: _money(-s.commission, language),
    );
    _line(
      pdf,
      label: t('statement.serviceFees'),
      amount: _money(-s.serviceFees, language),
    );
    _line(
      pdf,
      label: t('statement.refunds'),
      amount: _money(-s.refunds, language),
    );
    _line(pdf, label: t('statement.tills'), amount: _money(-s.tills, language));

    pdf.y += 8;
    pdf.rule(from: _margin, to: _right, at: pdf.y);
    pdf.y += 20;

    final owed = s.operatorOwesUs;
    pdf.text(
      t(owed ? 'statement.owed' : 'statement.net'),
      x: _margin,
      size: 13,
      font: PdfDocument.helveticaBold,
    );
    pdf.amount(
      _money(owed ? s.owedToUs : s.net, language),
      right: _right,
      size: 13,
    );

    pdf.y += 12;
    pdf.rule(from: _margin, to: _right, thickness: 1, at: pdf.y);
    pdf.y += 26;

    pdf.text(
      t('statement.payout', {'state': t('statement.state.${run.state}')}),
      x: _margin,
      size: 10,
      font: PdfDocument.helveticaBold,
    );
    pdf.y += 16;

    if (run.destination case final destination?) {
      pdf.text(
        t('statement.destination', {'destination': destination}),
        x: _margin,
        size: 9,
      );
      pdf.y += 14;
    }
    if (run.paidAt case final paidAt?) {
      pdf.text(
        t('statement.paidOn', {'date': _date(paidAt, language)}),
        x: _margin,
        size: 9,
      );
      pdf.y += 14;
    }
    if (run.reference case final reference?) {
      pdf.text(
        t('statement.paidRef', {'reference': reference}),
        x: _margin,
        size: 9,
      );
      pdf.y += 14;
    }

    pdf.y += 14;
    _paragraph(pdf, t('statement.cashNote'), size: 8);
    if (owed) {
      pdf.y += 6;
      _paragraph(pdf, t('statement.owedNote'), size: 8);
    }

    pdf.rule(from: _margin, to: _right, at: 790);
    pdf.text(t('statement.issuedBy'), x: _margin, at: 804, size: 7);
    pdf.text(
      t('statement.page', {'page': 1, 'total': 1}),
      x: 480,
      at: 804,
      size: 7,
    );

    return pdf.build(title: '${t('statement.title')} — $operatorName');
  }

  static void _heading(PdfDocument pdf, String label) {
    pdf.text(label, x: _margin, size: 9, font: PdfDocument.helveticaBold);
    pdf.y += 6;
    pdf.rule(from: _margin, to: _right, thickness: 0.25, at: pdf.y);
    pdf.y += 18;
  }

  static void _line(
    PdfDocument pdf, {
    required String label,
    required String amount,
    String? note,
  }) {
    pdf.text(label, x: _margin, size: 10);
    if (note != null) pdf.text(note, x: 300, size: 9);
    pdf.amount(amount, right: _right, size: 10);
    pdf.y += 18;
  }

  /// Wraps on words at a width the fixed page can hold. Crude on purpose:
  /// two sentences of explanatory text do not justify a line-breaking engine,
  /// and Helvetica at 8pt fits comfortably inside the estimate below.
  static void _paragraph(PdfDocument pdf, String text, {required double size}) {
    const perLine = 108;
    final words = text.split(' ');
    var line = StringBuffer();

    void flush() {
      if (line.isEmpty) return;
      pdf.text(line.toString(), x: _margin, size: size);
      pdf.y += size + 3;
      line = StringBuffer();
    }

    for (final word in words) {
      if (line.length + word.length + 1 > perLine) flush();
      if (line.isNotEmpty) line.write(' ');
      line.write(word);
    }
    flush();
  }

  /// The commission rate as it was actually applied, derived from the figures
  /// on the statement rather than read from the operator's row.
  ///
  /// The row can be renegotiated tomorrow; what this document has to say is
  /// what was taken from *these* sales. A statement that reprints today's rate
  /// over last month's money is the kind of small dishonesty that ends an
  /// operator relationship.
  static String _rate(PayoutStatement s) {
    if (s.onlineGross.minor == 0) return '—';
    final bps = (s.commission.minor * 10000 / s.onlineGross.minor).round();
    final percent = bps / 100;
    final text = percent == percent.roundToDouble()
        ? percent.round().toString()
        : percent.toStringAsFixed(2);
    return '$text %';
  }

  static String _money(Money amount, String language) =>
      amount.format(locale: language);

  /// `07/08/2026`. Numeric on purpose: a document filed in an accounts folder
  /// is scanned for a date, not read for one, and `sam. 7 août` is slower to
  /// find in a stack.
  /// Day-first in both languages, which is what Congo writes and what the
  /// English half of this catalog is read by — an operator's bookkeeper, not
  /// an American one. An ambiguous 07/08 is worth avoiding; two different
  /// orders on two prints of the same statement is worse.
  static String _date(DateTime instant, String language) {
    // The window is stored as an instant; a statement is read in the market's
    // own day. One hour is Africa/Brazzaville's offset and it has no daylight
    // saving, which is why this is a constant rather than a zone database.
    final local = instant.add(const Duration(hours: 1));
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    return '$d/$m/${local.year}';
  }

  /// The first segment of the uuid. A whole one wraps and nobody reads it
  /// aloud; eight characters is enough to find the row.
  static String _shortId(String id) =>
      id.length <= 8 ? id : id.substring(0, 8).toUpperCase();
}
