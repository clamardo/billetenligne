import 'dart:convert';
import 'dart:typed_data';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../application/ports/ticket_vault.dart';

/// The tickets, on the handset, in one SQLite file.
///
/// Hand-written SQL against `sqlite3` rather than an ORM, which is the same
/// choice this repository makes against Postgres. There is **one table and
/// three statements** here; a code generator and a build step is a large
/// thing to carry for that, and the schema below can be read in full without
/// leaving the file.
///
/// What is stored is the **booking as the server sent it**, JSON and all,
/// rather than a set of columns mirroring `BookingDto`. Two reasons, and both
/// are about the day this is being debugged rather than the day it is
/// written: a mirror is a second definition of the wire format that drifts
/// the first time a field is added, and a ticket is only useful whole — a
/// row missing its signature renders a QR no conductor will accept.
final class SqliteTicketVault implements TicketVault {
  SqliteTicketVault._(this._db);

  final Database _db;

  /// Opens (and creates) the vault beside the app's own documents.
  ///
  /// The file is deliberately not in a cache directory: Android empties those
  /// under pressure, and the whole point of this is a ticket that is still
  /// there on a morning when nothing else is.
  static Future<SqliteTicketVault> open({String? path}) async {
    final file =
        path ?? '${(await getApplicationDocumentsDirectory()).path}/tickets.db';
    return SqliteTicketVault._(sqlite3.open(file)).._migrate();
  }

  /// An in-memory vault, for tests and for a build with no filesystem.
  static SqliteTicketVault memory() =>
      SqliteTicketVault._(sqlite3.openInMemory()).._migrate();

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tickets (
        user_id  TEXT NOT NULL,
        ref      TEXT NOT NULL,
        json     TEXT NOT NULL,
        saved_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, ref)
      )
    ''');
    // Not keyed by traveller. A mark belongs to the company, several people
    // sharing a handset ride the same companies, and the bytes are the one
    // thing here that is public on a poster — so the second person to sign in
    // is spared a download rather than shown somebody else's ticket.
    _db.execute('''
      CREATE TABLE IF NOT EXISTS logos (
        url      TEXT NOT NULL PRIMARY KEY,
        bytes    BLOB NOT NULL,
        saved_at INTEGER NOT NULL
      )
    ''');
  }

  /// The largest mark this will keep, in bytes.
  ///
  /// The same 40 KB the upload route enforces (`asset.too_large`), asserted
  /// again here because what arrives is whatever a URL answered with: a
  /// misconfigured CDN handing back a 4 MB original must not put it in the
  /// file that has to survive on a full handset.
  static const maxLogoBytes = 40 * 1024;

  @override
  Future<List<BookingDto>> read(String userId) async {
    try {
      final rows = _db.select(
        'SELECT json FROM tickets WHERE user_id = ? ORDER BY saved_at',
        [userId],
      );
      final bookings = <BookingDto>[];
      for (final row in rows) {
        // One unreadable row is one missing ticket, not an unusable vault.
        // The alternative — throwing — turns a single bad write into a
        // handset that can never show any ticket again.
        try {
          bookings.add(
            BookingDto.fromJson(
              jsonDecode(row['json'] as String) as Map<String, Object?>,
            ),
          );
        } on Object {
          continue;
        }
      }
      return bookings;
    } on Object {
      // A corrupt or unopenable database degrades to "nothing cached". It
      // must never be the reason an app fails to start.
      return const [];
    }
  }

  @override
  Future<void> write(String userId, List<BookingDto> bookings) async {
    try {
      _db.execute('BEGIN');
      // Replaced rather than merged, in one transaction: the answer the
      // server just gave is the whole truth about what this traveller holds,
      // and a booking that has left it was cancelled or refunded. Merging
      // would keep a refunded ticket renderable forever.
      _db.execute('DELETE FROM tickets WHERE user_id = ?', [userId]);
      final insert = _db.prepare(
        'INSERT INTO tickets (user_id, ref, json, saved_at) '
        'VALUES (?, ?, ?, ?)',
      );
      try {
        var order = 0;
        for (final booking in bookings) {
          insert.execute([
            userId,
            booking.ref,
            jsonEncode(booking.toJson()),
            order++,
          ]);
        }
      } finally {
        insert.dispose();
      }
      _db.execute('COMMIT');
    } on Object {
      try {
        _db.execute('ROLLBACK');
      } on Object {
        // Nothing left to do: the write failed and the previous list stands,
        // which is the outcome this catch exists to guarantee.
      }
    }
  }

  @override
  Future<Uint8List?> logo(String url) async {
    try {
      final rows = _db.select('SELECT bytes FROM logos WHERE url = ?', [url]);
      if (rows.isEmpty) return null;
      return rows.first['bytes'] as Uint8List;
    } on Object {
      // A mark that will not read is a ticket without a mark, which is a
      // ticket (§7.1).
      return null;
    }
  }

  @override
  Future<void> putLogo(String url, List<int> bytes) async {
    if (bytes.isEmpty || bytes.length > maxLogoBytes) return;
    try {
      _db.execute(
        'INSERT INTO logos (url, bytes, saved_at) VALUES (?, ?, ?) '
        'ON CONFLICT(url) DO UPDATE SET bytes = excluded.bytes, '
        'saved_at = excluded.saved_at',
        [url, Uint8List.fromList(bytes), DateTime.now().millisecondsSinceEpoch],
      );
    } on Object {
      // Not being able to keep a logo is not a failure to hold a ticket.
    }
  }

  @override
  Future<void> keepLogos(Set<String> urls) async {
    try {
      if (urls.isEmpty) {
        _db.execute('DELETE FROM logos');
        return;
      }
      // Parameterised rather than interpolated even here: the values come
      // from a server response, and building SQL out of a response is a habit
      // that is wrong the first time one of them contains a quote.
      final holes = List.filled(urls.length, '?').join(',');
      _db.execute('DELETE FROM logos WHERE url NOT IN ($holes)', [...urls]);
    } on Object {
      // Leaving a stale mark behind costs kilobytes. Throwing here would cost
      // the write that has just stored the tickets.
    }
  }

  @override
  Future<void> clear() async {
    try {
      _db.execute('DELETE FROM tickets');
      _db.execute('DELETE FROM logos');
    } on Object {
      // Sign-out must not fail because a cache would not empty.
    }
  }

  /// Closes the file. Not part of the port: only whoever opened it knows when
  /// it is finished with.
  void close() => _db.dispose();
}
