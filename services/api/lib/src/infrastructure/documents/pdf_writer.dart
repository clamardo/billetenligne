import 'dart:convert';
import 'dart:typed_data';

/// A very small PDF writer: enough for a one-page financial statement, and
/// deliberately nothing more.
///
/// **Why not a package.** The Dart PDF packages are layout engines — widgets,
/// flex, page breaks, font subsetting — and they carry a font embedder and a
/// zlib dependency to do it. What `04-payments.md` §6.2 asks for is one page
/// of left-aligned labels and right-aligned figures, and that is a hundred
/// lines of the PDF object model. A statement is a **commercial document**
/// that has to be readable in ten years by whatever an accountant has
/// installed, so the smaller and more boring the file, the better.
///
/// Three decisions the format forces, each taken the conservative way:
///
///   * **Standard fonts, never embedded.** Helvetica and Courier are two of
///     the fourteen fonts every conforming reader has had since 1993.
///     Embedding a TrueType face would add a few hundred kilobytes to a
///     three-kilobyte document and a font-licensing question to a statement
///     nobody should have to think about.
///   * **WinAnsiEncoding, and figures in Courier.** WinAnsi covers French,
///     which is what §6.2 requires. Courier is fixed-pitch at 600/1000 em, so
///     an amount column can be right-aligned by *counting characters* — no
///     font metrics table, and no risk of a misaligned money column, which on
///     a financial document reads as carelessness about the numbers
///     themselves.
///   * **No compression.** A statement is a few kilobytes. An uncompressed
///     content stream can be read with `strings` when somebody disputes what
///     we sent them, and that is worth more than the bytes.
final class PdfDocument {
  PdfDocument({this.width = 595, this.height = 842});

  /// A4 in points, which is what Congo prints on.
  final double width;
  final double height;

  final _content = StringBuffer();

  /// Points from the top of the page. PDF's own origin is the bottom-left;
  /// converting here means every caller can lay a page out downwards, which
  /// is how a statement is read and written.
  double y = 0;

  static const helvetica = 'F1';
  static const helveticaBold = 'F2';
  static const courier = 'F3';

  /// Courier is 600/1000 of an em wide, per character, at every size.
  static const _courierWidth = 0.6;

  void text(
    String value, {
    required double x,
    required double size,
    String font = helvetica,
    double? at,
  }) {
    final top = at ?? y;
    _content
      ..writeln('BT')
      ..writeln('/$font ${_num(size)} Tf')
      ..writeln('${_num(x)} ${_num(height - top)} Td')
      ..writeln('(${_escape(value)}) Tj')
      ..writeln('ET');
  }

  /// Right-aligns at [right]. Fixed-pitch only, and asserted rather than
  /// silently approximated: a proportional font measured by character count
  /// would drift by a few points per line, which on a column of figures is
  /// exactly the sort of thing that makes somebody distrust the totals.
  void amount(
    String value, {
    required double right,
    required double size,
    double? at,
  }) => text(
    value,
    x: right - value.length * _courierWidth * size,
    size: size,
    font: courier,
    at: at,
  );

  /// A hairline. The mock in §6.2 draws these with box characters; a real
  /// document draws them, because `─` is not in WinAnsi and a run of hyphens
  /// looks like a fax.
  void rule({
    required double from,
    required double to,
    double thickness = 0.5,
    double? at,
  }) {
    final top = at ?? y;
    _content
      ..writeln('${_num(thickness)} w')
      ..writeln('${_num(from)} ${_num(height - top)} m')
      ..writeln('${_num(to)} ${_num(height - top)} l')
      ..writeln('S');
  }

  /// A filled band, for the header. Grey levels only — a statement printed on
  /// an agency's mono laser must not lose a line to a colour that renders as
  /// black on black.
  void band({
    required double from,
    required double to,
    required double top,
    required double depth,
    double grey = 0.92,
  }) => _content
    ..writeln('${_num(grey)} g')
    ..writeln(
      '${_num(from)} ${_num(height - top - depth)} '
      '${_num(to - from)} ${_num(depth)} re',
    )
    ..writeln('f')
    ..writeln('0 g');

  /// Serialises the document. Objects are written in order and their byte
  /// offsets recorded as they go, because the cross-reference table at the end
  /// is what makes a PDF readable at all — a reader that cannot parse `xref`
  /// shows nothing rather than showing the text it could find.
  Uint8List build({String? title}) {
    final stream = _content.toString();

    final objects = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R '
          '/MediaBox [0 0 ${_num(width)} ${_num(height)}] '
          '/Resources << /Font << '
          '/$helvetica 5 0 R /$helveticaBold 6 0 R /$courier 7 0 R '
          '>> >> '
          '/Contents 4 0 R >>',
      // Latin-1, not UTF-8: the whole file is written as WinAnsi bytes, and a
      // /Length counted in UTF-8 would overrun by one byte per accented
      // character — a stream length that lies is a page that renders blank.
      '<< /Length ${latin1.encode(stream).length} >>\n'
          'stream\n$stream\nendstream',
      _font('Helvetica'),
      _font('Helvetica-Bold'),
      _font('Courier'),
      '<< /Title (${_escape(title ?? '')}) /Producer (BilletEnLigne) >>',
    ];

    final out = BytesBuilder();
    // 1.7 rather than 2.0: every reader in an agency office opens 1.7, and
    // nothing here needs anything newer.
    out.add(latin1.encode('%PDF-1.7\n'));
    // A binary comment, which is how every tool that handles PDFs decides the
    // file is not text and must not be line-ending-converted in transit.
    out.add([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final offsets = <int>[];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(out.length);
      out.add(latin1.encode('${i + 1} 0 obj\n${objects[i]}\nendobj\n'));
    }

    final xref = out.length;
    final table = StringBuffer()
      ..writeln('xref')
      ..writeln('0 ${objects.length + 1}')
      ..writeln('0000000000 65535 f ');
    for (final offset in offsets) {
      table.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
    }
    table
      ..writeln('trailer')
      ..writeln(
        '<< /Size ${objects.length + 1} /Root 1 0 R '
        '/Info ${objects.length} 0 R >>',
      )
      ..writeln('startxref')
      ..writeln('$xref')
      ..write('%%EOF\n');

    out.add(latin1.encode(table.toString()));
    return out.toBytes();
  }

  static String _font(String base) =>
      '<< /Type /Font /Subtype /Type1 /BaseFont /$base '
      '/Encoding /WinAnsiEncoding >>';

  /// Trims the trailing zeros PDF does not need. Cosmetic, and it keeps the
  /// content stream legible to anybody who opens the file in an editor.
  static String _num(double value) {
    final fixed = value.toStringAsFixed(2);
    return fixed.endsWith('.00') ? fixed.substring(0, fixed.length - 3) : fixed;
  }

  /// To a WinAnsi literal string.
  ///
  /// Two spaces need naming. The **narrow no-break space** is what
  /// `Money.format` puts between the thousands of `3 429 600` — it is
  /// U+202F, it is not in WinAnsi, and dropping it would render the amount as
  /// `3429600`, which is a different-looking number on a document somebody is
  /// checking. It maps to WinAnsi's own no-break space. Anything else outside
  /// the encoding becomes `?` rather than vanishing: a visible substitution in
  /// an operator's name is a support call, a silent one is a document that
  /// quietly names the wrong company.
  static String _escape(String value) {
    final out = StringBuffer();

    for (final rune in value.runes) {
      final mapped = switch (rune) {
        0x202F || 0x2009 || 0x00A0 => 0x00A0, // narrow / thin / no-break space
        0x2019 => 0x92, // ’
        0x2018 => 0x91,
        0x201C => 0x93,
        0x201D => 0x94,
        // U+2212 is what `Money.format` puts in front of a deduction. It is
        // not in WinAnsi, and rendering it as `?` turns `−185 400` into
        // `?185 400` on a page of figures — a minus sign is not decoration.
        0x2212 || 0x2010 => 0x2D, // − ‐  →  -
        0x2013 => 0x96, // –
        0x2014 => 0x97, // —
        0x2026 => 0x85, // …
        0x20AC => 0x80, // €
        final r when r < 0x100 => r,
        _ => 0x3F, // ?
      };

      if (mapped == 0x28 || mapped == 0x29 || mapped == 0x5C) out.write(r'\');
      out.writeCharCode(mapped);
    }

    return out.toString();
  }
}
