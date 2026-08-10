import 'dart:typed_data';

/// What an operator can put on their storefront.
///
/// Two kinds with genuinely different budgets, because they are read in
/// different places: a logo appears on every search row, every ticket and
/// every console header, so it is fetched constantly; a cover appears once, on
/// a page somebody deliberately opened.
enum BrandAssetKind {
  /// ≤ 40 KB and ≤ 512 px on the long edge.
  ///
  /// The size is from `03-operator-lifecycle.md` §2.4 and the reason is
  /// ADR-0009: this ships to every traveller's phone on a metered bundle, and
  /// a 2 MB logo is a data cost imposed on the poorest user.
  logo(maxBytes: 40 * 1024, maxEdge: 512),

  /// ≤ 120 KB and ≤ 1600 px. Optional and never required — most operators
  /// have no usable photography, and a storefront that looks empty without one
  /// is a broken design rather than a missing upload.
  cover(maxBytes: 120 * 1024, maxEdge: 1600);

  const BrandAssetKind({required this.maxBytes, required this.maxEdge});

  final int maxBytes;

  /// The longest side we will serve, in pixels.
  ///
  /// A cap rather than a downscale, and that is a decision. Re-encoding
  /// somebody's brand mark is a silent change to the one asset they care
  /// about most — a resample softens a wordmark, and a PNG round-trip through
  /// a quantiser shifts the colour they chose. Refusing tells them, in the
  /// screen where they can fix it, in the tool that made the file.
  ///
  /// It also costs no image library, and this repository would otherwise be
  /// carrying a decoder in an API process to serve fourteen operators.
  final int maxEdge;
}

/// Why an upload was refused.
enum BrandAssetProblem {
  /// Not PNG, JPEG or SVG. Sniffed from the bytes, never from the header the
  /// caller sent — a `Content-Type` is a claim, and this one decides what we
  /// will later serve back to a browser.
  unsupportedType,
  tooLarge,
  tooWide,

  /// Truncated, or an SVG that is not markup. A file we cannot measure is a
  /// file we cannot bound.
  unreadable,
}

/// A brand asset we are willing to store, having actually looked at it.
final class BrandAsset {
  const BrandAsset._({
    required this.kind,
    required this.contentType,
    required this.extension,
    required this.bytes,
    this.width,
    this.height,
  });

  final BrandAssetKind kind;

  /// What we will serve it back as. Derived from the bytes, so a PNG uploaded
  /// as `image/svg+xml` is stored and served as a PNG — the alternative is
  /// letting a caller choose the type a browser will interpret, which is how
  /// an "image" upload becomes stored XSS.
  final String contentType;

  final String extension;
  final Uint8List bytes;

  /// Null for SVG, which has no intrinsic pixel size. That is not a hole in
  /// the check: a vector has no resolution to blow a data budget with, and its
  /// byte cap already bounds it.
  final int? width;
  final int? height;

  /// Inspects [bytes] and either accepts them or says why not.
  ///
  /// Order matters. The type is sniffed first because an unsupported file's
  /// size is not the interesting fact about it, and the size is checked before
  /// the dimensions because reading dimensions means trusting the header of a
  /// file we have already decided is too big to keep.
  static ({BrandAsset? asset, BrandAssetProblem? problem}) inspect(
    List<int> bytes, {
    required BrandAssetKind kind,
  }) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    final type = _sniff(data);
    if (type == null) {
      return (asset: null, problem: BrandAssetProblem.unsupportedType);
    }

    if (data.length > kind.maxBytes) {
      return (asset: null, problem: BrandAssetProblem.tooLarge);
    }

    int? width;
    int? height;

    if (type.$1 != 'image/svg+xml') {
      final size = type.$1 == 'image/png' ? _pngSize(data) : _jpegSize(data);
      if (size == null) {
        return (asset: null, problem: BrandAssetProblem.unreadable);
      }
      (width, height) = size;
      if (width > kind.maxEdge || height > kind.maxEdge) {
        return (asset: null, problem: BrandAssetProblem.tooWide);
      }
    }

    return (
      asset: BrandAsset._(
        kind: kind,
        contentType: type.$1,
        extension: type.$2,
        bytes: data,
        width: width,
        height: height,
      ),
      problem: null,
    );
  }

  /// The three we accept, by magic number.
  ///
  /// No GIF and no WebP: a GIF can animate, and an animated logo on a search
  /// row is a thing nobody asked for that every traveller then pays to
  /// download. WebP is only absent because Safari carried it late enough that
  /// a fallback would be needed, and one format we cannot fall back from is
  /// worse than three we can.
  static (String, String)? _sniff(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return ('image/png', 'png');
    }

    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return ('image/jpeg', 'jpg');
    }

    if (_looksLikeSvg(bytes)) return ('image/svg+xml', 'svg');
    return null;
  }

  /// SVG has no magic number, so this reads the start of the file as text and
  /// looks for the root element. Deliberately shallow: this decides whether we
  /// *store* it, and the reason it is safe to be shallow is that an SVG is
  /// never served from our own origin — see [BrandAsset] callers.
  static bool _looksLikeSvg(Uint8List bytes) {
    final head = String.fromCharCodes(
      bytes.take(512).where((b) => b < 0x80),
    ).toLowerCase();
    return head.contains('<svg');
  }

  /// PNG puts width and height in the IHDR chunk, which the spec requires to
  /// be first: 8 bytes of signature, 4 of length, 4 of type, then two big-
  /// endian 32-bit integers.
  static (int, int)? _pngSize(Uint8List bytes) {
    if (bytes.length < 24) return null;
    final view = ByteData.sublistView(bytes);
    return (view.getUint32(16), view.getUint32(20));
  }

  /// JPEG has to be walked: a chain of markers, with the dimensions inside
  /// whichever start-of-frame segment the encoder chose. Every SOFn carries
  /// them at the same offset except the ones that are not frames at all
  /// (`DHT`, `DRI`, and the restart markers).
  static (int, int)? _jpegSize(Uint8List bytes) {
    var offset = 2;
    final view = ByteData.sublistView(bytes);

    while (offset + 9 < bytes.length) {
      if (bytes[offset] != 0xFF) return null;

      final marker = bytes[offset + 1];
      // Standalone markers carry no length: padding, restarts, and SOI/EOI.
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }

      final length = view.getUint16(offset + 2);
      if (length < 2) return null;

      final isFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isFrame) {
        // length, precision, then height and width — in that order, which is
        // the reverse of every other format here and the usual place to get
        // this wrong.
        return (view.getUint16(offset + 7), view.getUint16(offset + 5));
      }

      offset += 2 + length;
    }
    return null;
  }
}
