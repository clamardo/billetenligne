import '../json/json_codec.dart';

/// Cursor pagination, never offset.
///
/// Offset pagination silently skips or repeats rows when the underlying set
/// changes between pages — and departures are created and cancelled while
/// someone is scrolling.
final class Page<T> {
  const Page({required this.items, this.nextCursor});

  final List<T> items;

  /// Null when there is nothing more.
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  Map<String, Object?> toJson(Map<String, Object?> Function(T) item) =>
      Wire.compact({
        'items': [for (final i in items) item(i)],
        'nextCursor': nextCursor,
      });

  static Page<T> fromJson<T>(
    Map<String, Object?> json,
    T Function(Map<String, Object?>) item,
  ) => Page(
    items: Wire.readList(json['items'], item, field: 'items'),
    nextCursor: json['nextCursor'] as String?,
  );
}
