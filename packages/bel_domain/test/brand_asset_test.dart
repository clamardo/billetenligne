import 'dart:typed_data';

import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// A PNG header with real dimensions and nothing after it. Enough for every
/// question this code asks, which is the point of reading IHDR rather than
/// decoding.
Uint8List png(int width, int height, {int pad = 0}) {
  final bytes = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add([0, 0, 0, 13])
    ..add('IHDR'.codeUnits);

  final size = ByteData(8)
    ..setUint32(0, width)
    ..setUint32(4, height);
  bytes.add(size.buffer.asUint8List());
  if (pad > 0) bytes.add(Uint8List(pad));
  return bytes.toBytes();
}

/// A baseline JPEG: SOI, an APP0 nobody reads, then SOF0 carrying the size.
Uint8List jpeg(int width, int height, {int pad = 0}) {
  final bytes = BytesBuilder()
    ..add([0xFF, 0xD8])
    // APP0: the length counts itself, so 0x0010 means fourteen bytes follow.
    ..add([0xFF, 0xE0, 0x00, 0x10])
    ..add('JFIF\x00'.codeUnits)
    ..add(Uint8List(9))
    ..add([0xFF, 0xC0, 0x00, 0x11, 0x08]);

  final size = ByteData(4)
    ..setUint16(0, height)
    ..setUint16(2, width);
  bytes
    ..add(size.buffer.asUint8List())
    ..add(Uint8List(10));
  if (pad > 0) bytes.add(Uint8List(pad));
  return bytes.toBytes();
}

Uint8List svg([String body = '']) => Uint8List.fromList(
  '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg">$body</svg>'
      .codeUnits,
);

void main() {
  group('what we accept', () {
    test('a small PNG logo, with its dimensions read', () {
      final result = BrandAsset.inspect(
        png(256, 128),
        kind: BrandAssetKind.logo,
      );

      expect(result.problem, isNull);
      expect(result.asset!.contentType, 'image/png');
      expect(result.asset!.extension, 'png');
      expect(result.asset!.width, 256);
      expect(result.asset!.height, 128);
    });

    // Height and width are the other way round in a JPEG frame header than in
    // every other format here, which is the usual place to get this wrong.
    test('a JPEG, with height and width the right way round', () {
      final result = BrandAsset.inspect(
        jpeg(1024, 576),
        kind: BrandAssetKind.cover,
      );

      expect(result.problem, isNull);
      expect(result.asset!.width, 1024);
      expect(result.asset!.height, 576);
    });

    // A vector has no resolution to blow a data budget with, so the byte cap
    // is the whole of the check.
    test('an SVG, which has no pixel size to check', () {
      final result = BrandAsset.inspect(svg(), kind: BrandAssetKind.logo);

      expect(result.problem, isNull);
      expect(result.asset!.contentType, 'image/svg+xml');
      expect(result.asset!.width, isNull);
    });

    test('an SVG with a leading comment or BOM is still an SVG', () {
      final withComment = Uint8List.fromList(
        '﻿<!-- exported by Inkscape --><svg></svg>'.codeUnits,
      );
      expect(
        BrandAsset.inspect(withComment, kind: BrandAssetKind.logo).problem,
        isNull,
      );
    });
  });

  group('what we refuse, and why', () {
    test('a type we will not serve', () {
      // GIF. It animates, and an animated logo on a search row is a thing
      // nobody asked for that every traveller then pays to download.
      final gif = Uint8List.fromList('GIF89a'.codeUnits);
      expect(
        BrandAsset.inspect(gif, kind: BrandAssetKind.logo).problem,
        BrandAssetProblem.unsupportedType,
      );
    });

    test('an executable renamed to look like a logo', () {
      final elf = Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, 0, 0, 0, 0]);
      expect(
        BrandAsset.inspect(elf, kind: BrandAssetKind.logo).problem,
        BrandAssetProblem.unsupportedType,
      );
    });

    test('40 KB is the logo budget, and 41 is not', () {
      expect(
        BrandAsset.inspect(
          png(64, 64, pad: 40 * 1024 - 24),
          kind: BrandAssetKind.logo,
        ).problem,
        isNull,
      );
      expect(
        BrandAsset.inspect(
          png(64, 64, pad: 40 * 1024),
          kind: BrandAssetKind.logo,
        ).problem,
        BrandAssetProblem.tooLarge,
      );
    });

    // A 40 KB PNG can still be 4000 px square — PNG compresses flat colour
    // extremely well — and decoding that on a 2 GB device costs 64 MB of
    // bitmap for a mark rendered at 32 dp.
    test('a small file can still be too many pixels', () {
      final result = BrandAsset.inspect(
        png(4000, 4000),
        kind: BrandAssetKind.logo,
      );
      expect(result.problem, BrandAssetProblem.tooWide);
    });

    test('a cover gets a bigger budget than a logo', () {
      final wide = png(1200, 675);
      expect(
        BrandAsset.inspect(wide, kind: BrandAssetKind.logo).problem,
        BrandAssetProblem.tooWide,
      );
      expect(
        BrandAsset.inspect(wide, kind: BrandAssetKind.cover).problem,
        isNull,
      );
    });

    test('a truncated PNG is unreadable, not accepted blind', () {
      final truncated = Uint8List.fromList(png(64, 64).take(20).toList());
      expect(
        BrandAsset.inspect(truncated, kind: BrandAssetKind.logo).problem,
        BrandAssetProblem.unreadable,
      );
    });

    test('a JPEG with no frame header is unreadable', () {
      final headerOnly = Uint8List.fromList([
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        ...List.filled(20, 0),
      ]);
      expect(
        BrandAsset.inspect(headerOnly, kind: BrandAssetKind.logo).problem,
        BrandAssetProblem.unreadable,
      );
    });

    test('nothing at all', () {
      expect(
        BrandAsset.inspect(const [], kind: BrandAssetKind.logo).problem,
        BrandAssetProblem.unsupportedType,
      );
    });
  });

  // The type we serve is decided by the bytes. A caller who could choose it
  // could have a PNG served as `text/html`, which is how an image upload
  // becomes stored XSS.
  test('the claimed type is never consulted', () {
    final result = BrandAsset.inspect(png(64, 64), kind: BrandAssetKind.logo);
    expect(result.asset!.contentType, 'image/png');

    final vector = BrandAsset.inspect(svg(), kind: BrandAssetKind.logo);
    expect(vector.asset!.contentType, 'image/svg+xml');
  });
}
