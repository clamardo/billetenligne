import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../application/ports/boarding_gateway.dart';

/// Who boarded, on the handset, in one SQLite file.
///
/// The scanner's whole promise is that the door works with the radio switched
/// off, and a queue held in memory quietly breaks it: Android kills a
/// backgrounded camera app under memory pressure — which is exactly what a
/// ten-minute boarding on a cheap handset produces — and forty boardings go
/// with it. Nobody finds out until the operator asks why the coach that left
/// full shows nobody on it.
///
/// Hand-written SQL against `sqlite3`, like the traveller app's ticket vault
/// and like this repository's Postgres: one table, five statements, readable
/// without leaving the file.
///
/// **First scan wins is the primary key**, not a rule somebody remembered.
/// `INSERT OR IGNORE` on `(departure_id, key)` is the same guarantee the
/// in-memory log made with `putIfAbsent`, enforced by the storage engine —
/// and the time a dispute is settled with is the one already in the row.
final class SqliteRedemptionStore {
  SqliteRedemptionStore._(this._db);

  final Database _db;

  /// Opens (and creates) the log beside the app's own documents.
  ///
  /// Deliberately not a cache directory: Android empties those under
  /// pressure, which is the failure this file exists to prevent.
  static Future<SqliteRedemptionStore> open({String? path}) async {
    final file =
        path ??
        '${(await getApplicationDocumentsDirectory()).path}/boardings.db';
    return SqliteRedemptionStore._(sqlite3.open(file)).._migrate();
  }

  /// An in-memory database, for tests and for a build with no filesystem.
  /// Not the same thing as `MemoryRedemptionLog` — this one runs the real SQL.
  static SqliteRedemptionStore memory() =>
      SqliteRedemptionStore._(sqlite3.openInMemory()).._migrate();

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS boardings (
        departure_id TEXT    NOT NULL,
        key          TEXT    NOT NULL,
        scanned_at   INTEGER NOT NULL,
        device_id    TEXT    NOT NULL,
        manual       INTEGER NOT NULL,
        code_stale   INTEGER NOT NULL,
        synced       INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (departure_id, key)
      )
    ''');
  }

  /// The log for one coach.
  ///
  /// Scoped rather than global because a conductor works two runs in a day and
  /// the same seat label boards on both — a log that could not tell them apart
  /// would refuse the second coach's 14A as already boarded.
  RedemptionLogForDeparture forDeparture(String departureId) =>
      RedemptionLogForDeparture._(_db, departureId);

  /// Coaches this device still has unsent boardings for.
  ///
  /// Read at launch so a queue left behind by a killed app is not waiting for
  /// somebody to happen to re-open that departure.
  List<String> departuresAwaitingSync() => [
    for (final row in _db.select(
      'SELECT DISTINCT departure_id FROM boardings WHERE synced = 0',
    ))
      row['departure_id'] as String,
  ];

  void dispose() => _db.dispose();
}

/// One coach's rows, behind the two ports the scanner asks for.
final class RedemptionLogForDeparture
    implements RedemptionLog, RedemptionOutbox {
  RedemptionLogForDeparture._(this._db, this._departureId);

  final Database _db;
  final String _departureId;

  @override
  DateTime? scannedAt(String bookingRef, String seatLabel) {
    final rows = _db.select(
      'SELECT scanned_at FROM boardings WHERE departure_id = ? AND key = ?',
      [_departureId, BoardingManifest.keyFor(bookingRef, seatLabel)],
    );
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      rows.first['scanned_at'] as int,
      isUtc: true,
    );
  }

  @override
  void record({
    required String bookingRef,
    required String seatLabel,
    required DateTime at,
    required String deviceId,
    bool codeWasStale = false,
    bool manual = false,
  }) {
    // OR IGNORE, so a conductor's double-tap keeps the first time rather than
    // overwriting it with the second.
    _db.execute(
      'INSERT OR IGNORE INTO boardings '
      '(departure_id, key, scanned_at, device_id, manual, code_stale) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        _departureId,
        BoardingManifest.keyFor(bookingRef, seatLabel),
        at.toUtc().millisecondsSinceEpoch,
        deviceId,
        manual ? 1 : 0,
        codeWasStale ? 1 : 0,
      ],
    );
  }

  @override
  List<BoardingUploadDto> pending() =>
      _read('WHERE departure_id = ? AND synced = 0');

  @override
  List<BoardingUploadDto> recorded() => _read('WHERE departure_id = ?');

  @override
  void markSynced(Iterable<String> keys) {
    final statement = _db.prepare(
      'UPDATE boardings SET synced = 1 WHERE departure_id = ? AND key = ?',
    );
    try {
      for (final key in keys) {
        statement.execute([_departureId, key]);
      }
    } finally {
      statement.dispose();
    }
  }

  int get count => _read('WHERE departure_id = ?').length;

  List<BoardingUploadDto> _read(String where) => [
    for (final row in _db.select(
      'SELECT key, scanned_at, device_id, manual, code_stale '
      'FROM boardings $where ORDER BY scanned_at',
      [_departureId],
    ))
      BoardingUploadDto(
        key: row['key'] as String,
        scannedAt: DateTime.fromMillisecondsSinceEpoch(
          row['scanned_at'] as int,
          isUtc: true,
        ),
        deviceId: row['device_id'] as String,
        mode: (row['manual'] as int) == 1 ? 'manual' : 'scan',
        codeWasStale: (row['code_stale'] as int) == 1,
      ),
  ];
}
