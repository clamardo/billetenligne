import 'dart:convert';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/ticket_designs.dart';
import '../db/database.dart';

/// The operator's stationery, against Postgres.
///
/// **The design is stored as the domain re-reads it, never as it arrived.**
/// `SaveTicketDesignRequest.design` is a map that came off a wire; it goes
/// through `TicketDesign.fromJson` and back out through `toJson` before it
/// reaches the column. So a console that sends a motif this build has never
/// heard of stores the fallback rather than the typo, and the row is always
/// a document this build can read back — which matters because the thing that
/// reads it back is a counter trying to sell a ticket.
///
/// **The format comes from the design, not from a field beside it.** Two
/// places to say which sheet to print on is one place to disagree.
final class PostgresTicketDesigns implements TicketDesigns {
  const PostgresTicketDesigns(this._db);

  final Database _db;

  static const _columns = 'id, name, format, design, is_default';

  @override
  Future<List<TicketDesignDto>> forOperator(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT $_columns FROM ticket_designs
             WHERE operator_id = @op
             ORDER BY format, is_default DESC, lower(name)
          '''),
          parameters: {'op': TypedValue(Type.uuid, operatorId)},
        );
        return [for (final row in rows) _design(row.toColumnMap())];
      });

  @override
  Future<TicketDesignDto?> save({
    required String operatorId,
    required SaveTicketDesignRequest edit,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // Through the domain and back: see the class comment.
    final design = TicketDesign.fromJson(edit.design);
    final format = design.format.name;
    final json = jsonEncode(design.toJson());

    if (edit.makeDefault) {
      // In the same transaction as the write below. A partial unique index
      // refuses two defaults outright, so doing this in two calls would not
      // merely be racy — it would fail.
      await tx.execute(
        Sql.named('''
          UPDATE ticket_designs SET is_default = false
           WHERE operator_id = @op AND format = @format AND is_default
        '''),
        parameters: {'op': TypedValue(Type.uuid, operatorId), 'format': format},
      );
    }

    final id = edit.id;
    // The write returns an id and nothing else, and the row is re-read
    // through the one query that describes it. A `RETURNING` sees the table
    // it wrote and no joins or defaults computed around it, and building a
    // DTO from one is how a field ends up silently null.
    final written = await tx.execute(
      Sql.named(
        id == null
            ? '''
              INSERT INTO ticket_designs
                     (operator_id, name, format, design, is_default)
              VALUES (@op, @name, @format, @design, @isDefault)
              RETURNING id
            '''
            : '''
              UPDATE ticket_designs
                 SET name = @name, format = @format, design = @design,
                     is_default = @isDefault, updated_at = now()
               WHERE id = @id AND operator_id = @op
              RETURNING id
            ''',
      ),
      parameters: {
        'op': TypedValue(Type.uuid, operatorId),
        'name': edit.name.trim(),
        'format': format,
        'design': TypedValue(Type.jsonb, json),
        'isDefault': edit.makeDefault,
        if (id != null) 'id': TypedValue(Type.uuid, id),
      },
    );
    if (written.isEmpty) return null;

    final rows = await tx.execute(
      Sql.named('SELECT $_columns FROM ticket_designs WHERE id = @id'),
      parameters: {'id': written.first.toColumnMap()['id']},
    );
    return rows.isEmpty ? null : _design(rows.first.toColumnMap());
  });

  @override
  Future<bool> remove({required String operatorId, required String id}) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            DELETE FROM ticket_designs
             WHERE id = @id AND operator_id = @op
            RETURNING id
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, id),
            'op': TypedValue(Type.uuid, operatorId),
          },
        );
        return rows.isNotEmpty;
      });

  /// Under the public scope, for the reason written in the port: the reader
  /// is somebody at a counter with a link and no account, and a company's own
  /// branding is not a secret from the person holding their ticket.
  @override
  Future<TicketDesignDto?> defaultFor({
    required String operatorCode,
    required String format,
  }) => _db.transaction(const DbScope.anonymous(), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT ${_columns.replaceAll('id', 'd.id')} FROM ticket_designs d
          JOIN operators o ON o.id = d.operator_id
         WHERE o.code = @code AND d.format = @format AND d.is_default
         LIMIT 1
      '''),
      parameters: {
        'code': TypedValue(Type.text, operatorCode),
        'format': format,
      },
    );
    return rows.isEmpty ? null : _design(rows.first.toColumnMap());
  });

  static TicketDesignDto _design(Map<String, dynamic> row) {
    final raw = row['design'];
    final decoded = switch (raw) {
      // `jsonb` comes back decoded by the driver, but a column written by
      // something else — a fixture, a psql session — arrives as text.
      final Map<String, Object?> map => map,
      final String text => jsonDecode(text) as Map<String, Object?>,
      _ => <String, Object?>{},
    };
    return TicketDesignDto(
      id: (row['id'] as Object).toString(),
      name: row['name'] as String,
      format: row['format'] as String,
      design: decoded,
      isDefault: row['is_default'] == true,
    );
  }
}
