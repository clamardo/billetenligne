import 'dart:typed_data';

import 'package:qr/qr.dart';

import 'qr_svg.dart';

/// The same QR, as a PNG, for the one place an SVG does not work: an inbox.
///
/// The page draws inline SVG because a browser renders it and a vector is
/// sharp at any size. **An email client is not a browser.** Gmail strips
/// `data:` image URIs, Outlook renders SVG as nothing at all, and an `<img>`
/// pointing back at us is an image that vanishes the moment somebody reads
/// their mail on a plane or in a village with no signal — which is precisely
/// the reader this whole feature exists for.
///
/// So the QR travels as a file attached to the message. It is in their inbox,
/// on their handset, and it works with the radio off. That is the honest
/// answer to "what if there is no network at the coach door", and it is why
/// the page tells them to keep the message.
///
/// **Written here rather than pulled in.** A PNG of a QR code is two colours
/// and no photography: one-bit greyscale, no filtering, and a zlib stream of
/// *stored* blocks — which is a legal deflate stream that every decoder in the
/// world reads, and about sixty lines rather than a compression library in the
/// API for one attachment. It costs bytes we do not care about: the file is a
/// few kilobytes either way, and it is sent once.
abstract final class QrPng {
  /// [payload] as a PNG, [scale] pixels to the module.
  ///
  /// Eight is not arbitrary: below about four, a mail client that scales the
  /// image to fit a phone screen interpolates the edges, and a blurred module
  /// boundary is a code the scanner at the door cannot lock onto.
  static Uint8List render(String payload, {int scale = 8}) {
    final image = QrImage(
      QrCode.fromData(data: payload, errorCorrectLevel: QrErrorCorrectLevel.M),
    );

    final modules = image.moduleCount + QrSvg.quietZone * 2;
    final side = modules * scale;
    final rowBytes = (side + 7) ~/ 8;

    // One filter byte (0 — none) per scanline, then the row packed one bit to
    // the pixel, most significant bit leftmost. 0 is black, 1 is white.
    final raw = Uint8List((rowBytes + 1) * side);
    var at = 0;

    for (var y = 0; y < side; y++) {
      final row = y ~/ scale - QrSvg.quietZone;
      raw[at++] = 0;
      final start = at;
      // White first, then punch the dark modules out of it: a QR is mostly
      // light, and this way the quiet zone costs nothing.
      for (var i = 0; i < rowBytes; i++) {
        raw[start + i] = 0xFF;
      }
      if (row >= 0 && row < image.moduleCount) {
        for (var col = 0; col < image.moduleCount; col++) {
          if (!image.isDark(row, col)) continue;
          final from = (col + QrSvg.quietZone) * scale;
          for (var x = from; x < from + scale; x++) {
            raw[start + (x >> 3)] &= ~(0x80 >> (x & 7));
          }
        }
      }
      at += rowBytes;
    }

    final png = BytesBuilder()
      ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      ..add(
        _chunk('IHDR', [
          ..._be32(side), ..._be32(side),
          1, // one bit per pixel
          0, // greyscale
          0, 0, 0, // deflate, no filter, no interlace
        ]),
      )
      ..add(_chunk('IDAT', _zlib(raw)))
      ..add(_chunk('IEND', const []));

    return png.toBytes();
  }

  /// A zlib stream of stored blocks. Legal deflate, no compressor.
  static List<int> _zlib(Uint8List raw) {
    final out = <int>[0x78, 0x01];
    for (var offset = 0; offset < raw.length; offset += 0xFFFF) {
      final length = raw.length - offset < 0xFFFF
          ? raw.length - offset
          : 0xFFFF;
      out
        ..add(offset + length >= raw.length ? 1 : 0)
        ..addAll([
          length & 0xFF,
          (length >> 8) & 0xFF,
          (length ^ 0xFFFF) & 0xFF,
          ((length ^ 0xFFFF) >> 8) & 0xFF,
        ])
        ..addAll(raw.sublist(offset, offset + length));
    }
    return out..addAll(_be32(_adler32(raw)));
  }

  static List<int> _chunk(String type, List<int> data) {
    final head = [...type.codeUnits, ...data];
    return [..._be32(data.length), ...head, ..._be32(_crc32(head))];
  }

  static List<int> _be32(int value) => [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];

  static final Uint32List _crcTable = () {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c;
    }
    return table;
  }();

  static int _crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static int _adler32(List<int> bytes) {
    var a = 1;
    var b = 0;
    for (final byte in bytes) {
      a = (a + byte) % 65521;
      b = (b + a) % 65521;
    }
    return ((b << 16) | a) & 0xFFFFFFFF;
  }
}
