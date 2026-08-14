import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// The section builder: a coach drawn by hand, for the one no preset fits.
///
/// A full screen rather than a dialog. Drawing a layout is the twenty-minute
/// job in this console, and a dialog says "this will take a moment" — which
/// is a promise the task cannot keep. It also gives the preview room, and the
/// preview is the point: an operator who has typed `2+3` should see three
/// seats, an aisle and two seats before they save, not after fourteen coaches
/// point at it.
///
/// **The preview is the traveller's screen.** It is `KSeatMap`, the same
/// widget that sells the seat, drawn from the same [CabinSection] the server
/// will store. Anything else is a drawing of a coach that agrees with the
/// real one until it doesn't.
///
/// Start rows are computed, not typed: sections follow one another, which is
/// what a vehicle actually looks like, and asking somebody to keep a running
/// total in their head is how a layout gets two row 12s.
final class LayoutBuilderScreen extends StatefulWidget {
  const LayoutBuilderScreen({super.key});

  @override
  State<LayoutBuilderScreen> createState() => _LayoutBuilderScreenState();
}

class _LayoutBuilderScreenState extends State<LayoutBuilderScreen> {
  final _name = TextEditingController();
  var _mode = TransportMode.bus;
  var _numbering = SeatNumbering.rowLetter;

  /// One row of 2+2 to start. An empty canvas is a worse first screen than a
  /// wrong one: the operator can see what a section is, and change it.
  final _sections = <_SectionEditor>[_SectionEditor()];

  /// Seats that exist and are not for sale. Held by label rather than by
  /// position, because a label is what the manifest, the ticket and the
  /// conductor all say — and because inserting a row above a blocked seat
  /// must move the block with it, which positions would not do.
  final _blocked = <String>{};

  /// Doors, stairs and the lavatory.
  final _features = <LayoutFeature>[];

  /// What the screen looked like before each structural change, and after
  /// each undo.
  ///
  /// **Coarse on purpose.** A step is a *decision* — a seat condemned, a
  /// section moved, a door placed — not a keystroke. A history that recorded
  /// every character would need forty taps of undo to get back past a row
  /// count somebody retyped, which is a history nobody uses. Text fields keep
  /// their own per-character undo, which is the right granularity for text.
  ///
  /// The typed-but-uncommitted text does ride along in a snapshot, so undoing
  /// a deleted section restores the numbers that were in it. The cost is that
  /// undo also reverts text typed since the last decision — and redo puts it
  /// back, because the current state is snapshotted on the way out.
  final _past = <_Snapshot>[];
  final _future = <_Snapshot>[];

  /// Deep enough for a session of drawing, bounded so a screen left open all
  /// afternoon does not hold every coach the operator has ever considered.
  static const _historyDepth = 40;

  bool get _canUndo => _past.isNotEmpty;
  bool get _canRedo => _future.isNotEmpty;

  /// Call **before** mutating. Everything reachable from the screen goes in,
  /// because a partial snapshot is a restore that silently drops something.
  void _remember() {
    _past.add(_snapshot());
    if (_past.length > _historyDepth) _past.removeAt(0);
    // A new decision ends the redo line. Keeping it would let somebody redo
    // their way into a layout that never existed.
    _future.clear();
  }

  _Snapshot _snapshot() => _Snapshot(
    name: _name.text,
    mode: _mode,
    numbering: _numbering,
    sections: [for (final s in _sections) s.snapshot()],
    blocked: {..._blocked},
    features: [..._features],
    movedBlocks: _movedBlocks,
  );

  void _undo() {
    if (!_canUndo) return;
    final now = _snapshot();
    setState(() {
      _restore(_past.removeLast());
      _future.add(now);
    });
  }

  void _redo() {
    if (!_canRedo) return;
    final now = _snapshot();
    setState(() {
      _restore(_future.removeLast());
      _past.add(now);
    });
  }

  void _restore(_Snapshot s) {
    // The editors own `TextEditingController`s, so a restore is a rebuild
    // rather than an assignment. Disposing first is not optional: a leaked
    // controller keeps notifying a widget that is gone.
    for (final editor in _sections) {
      editor.dispose();
    }
    _sections
      ..clear()
      ..addAll([for (final e in s.sections) _SectionEditor.from(e)]);

    _name.text = s.name;
    _mode = s.mode;
    _numbering = s.numbering;
    _blocked
      ..clear()
      ..addAll(s.blocked);
    _features
      ..clear()
      ..addAll(s.features);
    _movedBlocks = s.movedBlocks;
  }

  @override
  void dispose() {
    _name.dispose();
    for (final s in _sections) {
      s.dispose();
    }
    super.dispose();
  }

  /// The draft as the server will read it. Rebuilt on every keystroke, which
  /// is cheap — a layout is at most six sections — and is what keeps the
  /// capacity counter and the preview honest.
  LayoutDraft get _draft {
    final sections = <CabinSection>[];
    var startRow = 1;
    for (final editor in _sections) {
      final section = editor.toDomain(
        startRow: startRow,
        numbering: _numbering,
      );
      if (section == null) continue;
      sections.add(section);
      startRow += section.rows;
    }
    // Blocks are kept even while the seat they name is gone — a row count
    // being retyped from 10 to 1 to 12 must not silently drop the wheel arch
    // somebody marked — so they are filtered to what currently exists here,
    // at the edge, rather than deleted from the set.
    final layout = SeatLayout(version: 1, mode: _mode, sections: sections);
    final labels = layout.allSeatLabels().toSet();

    return LayoutDraft(
      name: _name.text,
      mode: _mode,
      sections: sections,
      blocked: {
        for (final b in _blocked)
          if (labels.contains(b)) b,
      },
      features: List.unmodifiable(_features),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final draft = _draft;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('console.fleet.builder.title')),
        actions: [
          IconButton(
            tooltip: context.t('console.fleet.builder.undo'),
            icon: const Icon(Icons.undo),
            onPressed: _canUndo ? _undo : null,
          ),
          IconButton(
            tooltip: context.t('console.fleet.builder.redo'),
            icon: const Icon(Icons.redo),
            onPressed: _canRedo ? _redo : null,
          ),
          SizedBox(width: kilo.space.s2),
        ],
      ),
      // The save control lives on a bar of its own rather than in the app
      // bar, and not for looks: a refusal here has to say what it wants, and
      // an explanation under a button does not fit in a 56-pixel toolbar. It
      // overflowed the first time it was tried.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(kilo.space.s3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  draft.capacity == 0
                      ? context.t('console.fleet.builder.capacityEmpty')
                      : context.t('console.fleet.builder.capacity', {
                          'count': draft.capacity,
                        }),
                  style: kilo.text.body,
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: KButton(
                  label: context.t('common.actions.save'),
                  fullWidth: false,
                  icon: Icons.check,
                  onPressed: draft.isValid
                      ? () => Navigator.of(context).pop(draft)
                      : null,
                  // Never a greyed button with no explanation: the single
                  // most common way software strands somebody is a control
                  // that refuses without saying what it wants.
                  disabledHint: context.t('console.fleet.builder.cannotSave'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final editor = _editor(context, draft);
          final preview = _preview(context, draft);

          // Side by side on a desk, stacked on a laptop opened half-width.
          // The threshold is where the preview stops being readable rather
          // than a device class — this console is only ever a browser window.
          if (constraints.maxWidth < 900) {
            return ListView(
              padding: EdgeInsets.all(kilo.space.s4),
              children: [
                editor,
                SizedBox(height: kilo.space.s5),
                preview,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(kilo.space.s4),
                  child: editor,
                ),
              ),
              SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(kilo.space.s4),
                  child: preview,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _editor(BuildContext context, LayoutDraft draft) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KField(
          label: context.t('console.fleet.layoutName'),
          controller: _name,
          autofocus: true,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: kilo.space.s3),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<TransportMode>(
                isExpanded: true,
                initialValue: _mode,
                decoration: InputDecoration(
                  labelText: context.t('console.fleet.builder.mode'),
                ),
                items: [
                  for (final m in TransportMode.values)
                    DropdownMenuItem(
                      value: m,
                      child: Text(
                        context.t('console.fleet.builder.modes.${m.name}'),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _remember();
                  _mode = v ?? _mode;
                }),
              ),
            ),
            SizedBox(width: kilo.space.s3),
            Expanded(
              child: DropdownButtonFormField<SeatNumbering>(
                isExpanded: true,
                initialValue: _numbering,
                decoration: InputDecoration(
                  labelText: context.t('console.fleet.builder.numbering'),
                ),
                items: [
                  for (final n in SeatNumbering.values)
                    DropdownMenuItem(
                      value: n,
                      child: Text(
                        context.t('console.fleet.builder.numberings.${n.name}'),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _remember();
                  _numbering = v ?? _numbering;
                }),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s5),

        Text(context.t('console.fleet.builder.sections'), style: kilo.text.h2),
        if (_movedBlocks) ...[
          SizedBox(height: kilo.space.s2),
          Text(
            context.t('console.fleet.builder.reorderDroppedBlocks'),
            style: kilo.text.caption.copyWith(color: kilo.color.danger),
          ),
        ],
        SizedBox(height: kilo.space.s3),

        for (var i = 0; i < _sections.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: kilo.space.s3),
            child: _SectionCard(
              editor: _sections[i],
              index: i,
              startRow: _startRowOf(i),
              // The last section standing cannot be removed: a layout with no
              // sections is a coach with no seats, and offering the control
              // that produces one is offering a dead end.
              onRemove: _sections.length == 1
                  ? null
                  : () => setState(() {
                      _remember();
                      _sections.removeAt(i).dispose();
                    }),
              // Order is physical: section one is at the front. Getting VIP
              // and standard the wrong way round meant deleting both and
              // retyping them, which is how somebody loses a fare they had
              // already set.
              onMoveUp: i == 0 ? null : () => _move(i, i - 1),
              onMoveDown: i == _sections.length - 1
                  ? null
                  : () => _move(i, i + 1),
              onChanged: () => setState(() {}),
            ),
          ),

        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: KButton(
            label: context.t('console.fleet.builder.addSection'),
            fullWidth: false,
            tone: KButtonTone.secondary,
            icon: Icons.add,
            onPressed: _sections.length >= 6
                ? null
                : () => setState(() {
                    _remember();
                    _sections.add(_SectionEditor());
                  }),
          ),
        ),
      ],
    );
  }

  /// Swaps two sections, and the blocks with them.
  ///
  /// **The labels move.** A block is held by label, and labels are computed
  /// from a section's position — so moving VIP behind standard renames every
  /// seat in both, and a block left on its old label would land on somebody
  /// else's seat. Rather than remapping, which needs a rule for a section that
  /// changed size in between, the blocks in the two sections are dropped and
  /// the operator is told. Losing two taps is better than blocking the wrong
  /// seat quietly.
  void _move(int from, int to) => setState(() {
    _remember();
    final blocksBefore = _blocked.length;
    final section = _sections.removeAt(from);
    _sections.insert(to, section);
    _blocked.removeAll(_labelsIn(from));
    _blocked.removeAll(_labelsIn(to));
    _movedBlocks = blocksBefore != _blocked.length;
  });

  /// True when the last reorder dropped blocks, so the screen can say so once.
  var _movedBlocks = false;

  /// Every label the section at [i] currently owns.
  Set<String> _labelsIn(int i) {
    if (i < 0 || i >= _sections.length) return const {};
    final section = _sections[i].toDomain(
      startRow: _startRowOf(i),
      numbering: _numbering,
    );
    if (section == null) return const {};
    return SeatLayout(
      version: 1,
      mode: _mode,
      sections: [section],
    ).allSeatLabels().toSet();
  }

  /// Where section [i] begins, counting only the sections above it that can
  /// actually be drawn — so a half-typed row count does not shift every
  /// number below it while somebody is still typing.
  int _startRowOf(int i) {
    var row = 1;
    for (var j = 0; j < i; j++) {
      final section = _sections[j].toDomain(
        startRow: row,
        numbering: _numbering,
      );
      if (section != null) row += section.rows;
    }
    return row;
  }

  Widget _preview(BuildContext context, LayoutDraft draft) {
    final kilo = context.kilo;
    final layout = draft.layout;
    final labels = layout.allSeatLabels();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The count is on the save bar, not here. Two places saying 40 is two
        // places to disagree the first time one of them is computed
        // differently.
        Text(context.t('console.fleet.builder.preview'), style: kilo.text.h2),
        SizedBox(height: kilo.space.s3),
        if (labels.isNotEmpty) ...[
          Text(
            context.t('console.fleet.builder.tapToBlock'),
            style: kilo.text.caption.copyWith(
              color: kilo.color.contentSecondary,
            ),
          ),
          SizedBox(height: kilo.space.s2),
          KCard(
            child: KSeatMap(
              sections: [
                for (final s in layout.sections)
                  KSection(
                    code: s.code,
                    label: context.t(s.labelKey),
                    abreast: s.abreast,
                    pitchCm: s.pitchCm,
                  ),
              ],
              seats: [
                for (final label in labels)
                  KSeat(
                    label: label,
                    // The same drawing the traveller will see, which is the
                    // point of previewing here at all: an operator who blocks
                    // 7C sees exactly what somebody choosing a seat will.
                    state: _blocked.contains(label)
                        ? KSeatState.blocked
                        : KSeatState.available,
                  ),
              ],
              selected: const {},
              // The coach is being drawn, not sold from: a blocked seat has to
              // answer a tap or blocking one is a decision with no way back.
              editing: true,
              // Not a sale — a drawing. Tapping toggles whether the seat can
              // ever be sold, which is why the map is here rather than a grid
              // of checkboxes: the thing being edited is the coach.
              onToggle: (seat) => setState(() {
                _remember();
                if (!_blocked.remove(seat.label)) _blocked.add(seat.label);
              }),
              labels: KSeatMapLabels(
                front: context.t('travel.seatmap.front'),
                free: context.t('travel.seatmap.free'),
                chosen: context.t('travel.seatmap.chosen'),
                taken: context.t('travel.seatmap.taken'),
              ),
            ),
          ),
          if (draft.blocked.isNotEmpty) ...[
            SizedBox(height: kilo.space.s2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.t('console.fleet.builder.blockedCount', {
                      'count': draft.blocked.length,
                    }),
                    style: kilo.text.caption,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _remember();
                    _blocked.clear();
                  }),
                  child: Text(context.t('console.fleet.builder.unblockAll')),
                ),
              ],
            ),
          ],
          SizedBox(height: kilo.space.s5),
          _featureEditor(context),
        ],
      ],
    );
  }

  /// Doors, stairs and the lavatory.
  ///
  /// A list rather than a drag onto the map, and the reason is the map: a
  /// door does not sit *on* a seat, it sits between two rows, and inventing a
  /// drop target for a coordinate the seat map does not draw would be a
  /// gesture that lies about where the thing ends up. Row and column are the
  /// numbers the format actually stores, so what is typed is what is saved.
  Widget _featureEditor(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('console.fleet.builder.features'), style: kilo.text.h2),
        SizedBox(height: kilo.space.s2),
        Text(
          context.t('console.fleet.builder.featuresHint'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s3),

        for (var i = 0; i < _features.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: kilo.space.s2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.t('console.fleet.builder.featureAt', {
                      'feature': context.t(
                        'console.fleet.builder.featureTypes.'
                        '${_features[i].type.name}',
                      ),
                      'row': _features[i].row,
                      'col': _features[i].col,
                    }),
                    style: kilo.text.body,
                  ),
                ),
                IconButton(
                  tooltip: context.t('console.fleet.builder.removeFeature'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() {
                    _remember();
                    _features.removeAt(i);
                  }),
                ),
              ],
            ),
          ),

        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: KButton(
            label: context.t('console.fleet.builder.addFeature'),
            fullWidth: false,
            tone: KButtonTone.secondary,
            icon: Icons.add,
            // Eight is more than any coach in this market carries, and the
            // cap is here rather than on the server alone so the control
            // stops being offered rather than starting to refuse.
            onPressed: _features.length >= 8 ? null : _addFeature,
          ),
        ),
      ],
    );
  }

  Future<void> _addFeature() async {
    final added = await showDialog<LayoutFeature>(
      context: context,
      builder: (context) => const _FeatureDialog(),
    );
    if (added != null) {
      setState(() {
        _remember();
        _features.add(added);
      });
    }
  }
}

/// Where a door goes, asked once.
///
/// A dialog rather than three inline fields, because a half-typed coordinate
/// in a list that redraws the preview on every keystroke puts a lavatory at
/// row 1 while somebody is typing 12.
class _FeatureDialog extends StatefulWidget {
  const _FeatureDialog();

  @override
  State<_FeatureDialog> createState() => _FeatureDialogState();
}

class _FeatureDialogState extends State<_FeatureDialog> {
  var _type = LayoutFeatureType.door;
  final _row = TextEditingController(text: '1');
  final _col = TextEditingController(text: '0');

  @override
  void dispose() {
    _row.dispose();
    _col.dispose();
    super.dispose();
  }

  LayoutFeature? get _value {
    final row = int.tryParse(_row.text.trim());
    final col = int.tryParse(_col.text.trim());
    if (row == null || row < 0 || row > 200) return null;
    if (col == null || col < 0 || col > 10) return null;
    return LayoutFeature(_type, row: row, col: col);
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return AlertDialog(
      title: Text(context.t('console.fleet.builder.addFeature')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<LayoutFeatureType>(
            isExpanded: true,
            initialValue: _type,
            decoration: InputDecoration(
              labelText: context.t('console.fleet.builder.featureType'),
            ),
            items: [
              for (final t in LayoutFeatureType.values)
                DropdownMenuItem(
                  value: t,
                  child: Text(
                    context.t('console.fleet.builder.featureTypes.${t.name}'),
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          SizedBox(height: kilo.space.s3),
          Row(
            children: [
              Expanded(
                child: KField(
                  label: context.t('console.fleet.builder.featureRow'),
                  controller: _row,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: KField(
                  label: context.t('console.fleet.builder.featureCol'),
                  controller: _col,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('common.actions.cancel')),
        ),
        TextButton(
          onPressed: _value == null
              ? null
              : () => Navigator.of(context).pop(_value),
          child: Text(context.t('common.actions.add')),
        ),
      ],
    );
  }
}

/// The four classes an operator picks from, and the translation key each one
/// carries into the layout.
///
/// A closed set rather than a free-text field, because the key is rendered on
/// the traveller's seat map and on the ticket: a typed class name would ship
/// one operator's French into an English reader's screen (ADR-0008).
const _classes = <String, String>{
  'STD': 'seat.class.standard',
  'VIP': 'seat.class.vip',
  'F': 'seat.class.first',
  'Y': 'seat.class.economy',
};

enum _FareMode { none, multiplier, supplement }

/// The mutable half of one section: the controllers, and how they become a
/// [CabinSection].
final class _SectionEditor {
  _SectionEditor()
    : rows = TextEditingController(text: '10'),
      abreast = TextEditingController(text: '2+2'),
      pitch = TextEditingController(),
      fareValue = TextEditingController();

  /// Rebuilt from a snapshot, controllers and all. Undo restores a section
  /// that was deleted, which means the widget tree gets new controllers —
  /// there is no way to un-dispose the old ones.
  _SectionEditor.from(_SectionSnapshot s)
    : rows = TextEditingController(text: s.rows),
      abreast = TextEditingController(text: s.abreast),
      pitch = TextEditingController(text: s.pitch),
      fareValue = TextEditingController(text: s.fareValue) {
    code = s.code;
    fareMode = s.fareMode;
  }

  _SectionSnapshot snapshot() => _SectionSnapshot(
    code: code,
    rows: rows.text,
    abreast: abreast.text,
    pitch: pitch.text,
    fareMode: fareMode,
    fareValue: fareValue.text,
  );

  String code = 'STD';
  final TextEditingController rows;
  final TextEditingController abreast;
  final TextEditingController pitch;
  _FareMode fareMode = _FareMode.none;
  final TextEditingController fareValue;

  void dispose() {
    rows.dispose();
    abreast.dispose();
    pitch.dispose();
    fareValue.dispose();
  }

  /// Null while the section is unfinished or wrong — which is the same
  /// question the server asks, asked here so the preview simply omits a
  /// section nobody could sell rather than drawing a guess.
  CabinSection? toDomain({
    required int startRow,
    required SeatNumbering numbering,
  }) {
    final rowCount = int.tryParse(rows.text.trim());
    if (rowCount == null || rowCount < 1 || rowCount > 80) return null;
    if (!Abreast.isValid(abreast.text)) return null;

    return CabinSection(
      code: code,
      labelKey: _classes[code] ?? 'seat.class.standard',
      rows: rowCount,
      abreast: abreast.text.trim(),
      startRow: startRow,
      numbering: numbering,
      pitchCm: int.tryParse(pitch.text.trim()),
      modifier: _modifier(),
    );
  }

  PriceModifier? _modifier() {
    final raw = fareValue.text.trim().replaceAll(',', '.');
    return switch (fareMode) {
      _FareMode.none => null,
      _FareMode.multiplier => switch (double.tryParse(raw)) {
        final v? when v > 0 && v <= 10 => PriceModifier.multiplier(v),
        _ => null,
      },
      _FareMode.supplement => switch (int.tryParse(raw)) {
        final v? when v >= 0 => PriceModifier.supplementMinor(v),
        _ => null,
      },
    };
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.editor,
    required this.index,
    required this.startRow,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onChanged,
  });

  final _SectionEditor editor;
  final int index;
  final int startRow;
  final VoidCallback? onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final workable =
        editor.toDomain(
          startRow: startRow,
          numbering: SeatNumbering.rowLetter,
        ) !=
        null;

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t('console.fleet.builder.sectionTitle', {
                    'index': index + 1,
                  }),
                  style: kilo.text.body,
                ),
              ),
              Text(
                context.t('console.fleet.builder.startRow', {'row': startRow}),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              IconButton(
                tooltip: context.t('console.fleet.builder.moveUp'),
                icon: const Icon(Icons.arrow_upward),
                onPressed: onMoveUp,
              ),
              IconButton(
                tooltip: context.t('console.fleet.builder.moveDown'),
                icon: const Icon(Icons.arrow_downward),
                onPressed: onMoveDown,
              ),
              if (onRemove != null)
                IconButton(
                  tooltip: context.t('console.fleet.builder.removeSection'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onRemove,
                ),
            ],
          ),
          SizedBox(height: kilo.space.s2),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: editor.code,
                  decoration: InputDecoration(
                    labelText: context.t('console.fleet.builder.sectionClass'),
                  ),
                  items: [
                    for (final code in _classes.keys)
                      DropdownMenuItem(
                        value: code,
                        child: Text(
                          context.t('console.fleet.builder.classes.$code'),
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    editor.code = v ?? editor.code;
                    onChanged();
                  },
                ),
              ),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: KField(
                  label: context.t('console.fleet.builder.rows'),
                  controller: editor.rows,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => onChanged(),
                ),
              ),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: KField(
                  label: context.t('console.fleet.builder.abreast'),
                  helper: context.t('console.fleet.builder.abreastHelp'),
                  controller: editor.abreast,
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          SizedBox(height: kilo.space.s2),

          // The arrangements that actually run here, one tap each. Typing
          // `2+2` is not hard; getting `2+2` rather than `2 + 2` on the first
          // try, on a laptop in an agency, is.
          Wrap(
            spacing: kilo.space.s2,
            children: [
              for (final preset in const [
                '2+2',
                '2+3',
                '3+3',
                '1+2',
                '1+1',
                '5',
              ])
                ActionChip(
                  label: Text(preset),
                  onPressed: () {
                    editor.abreast.text = preset;
                    onChanged();
                  },
                ),
            ],
          ),
          SizedBox(height: kilo.space.s2),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DropdownButtonFormField<_FareMode>(
                  isExpanded: true,
                  initialValue: editor.fareMode,
                  decoration: InputDecoration(
                    labelText: context.t('console.fleet.builder.fare'),
                  ),
                  items: [
                    for (final mode in _FareMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(
                          context.t(
                            'console.fleet.builder.fareModes.${mode.name}',
                          ),
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    editor.fareMode = v ?? editor.fareMode;
                    onChanged();
                  },
                ),
              ),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: editor.fareMode == _FareMode.none
                    ? SizedBox(height: kilo.space.s1)
                    : KField(
                        label: editor.fareMode == _FareMode.multiplier
                            ? context.t('console.fleet.builder.fareMultiplier')
                            : context.t(
                                'console.fleet.builder.fareSupplement',
                                {'currency': Market.current.currency.code},
                              ),
                        controller: editor.fareValue,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => onChanged(),
                      ),
              ),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: KField(
                  label: context.t('console.fleet.builder.pitch'),
                  controller: editor.pitch,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),

          if (!workable) ...[
            SizedBox(height: kilo.space.s2),
            Text(
              context.t('console.fleet.builder.invalidSection'),
              style: kilo.text.caption.copyWith(color: kilo.color.danger),
            ),
          ],
        ],
      ),
    );
  }
}

/// One step of history: everything the screen holds, as values.
///
/// A record of the *state*, not of the action that produced it. An undo stack
/// of inverse operations needs an inverse for every action, and the first one
/// somebody forgets to write is the one that corrupts the layout — where a
/// snapshot that is simply wrong is a snapshot that is visibly wrong.
final class _Snapshot {
  const _Snapshot({
    required this.name,
    required this.mode,
    required this.numbering,
    required this.sections,
    required this.blocked,
    required this.features,
    required this.movedBlocks,
  });

  final String name;
  final TransportMode mode;
  final SeatNumbering numbering;
  final List<_SectionSnapshot> sections;
  final Set<String> blocked;
  final List<LayoutFeature> features;
  final bool movedBlocks;
}

/// One section, as text rather than as controllers.
final class _SectionSnapshot {
  const _SectionSnapshot({
    required this.code,
    required this.rows,
    required this.abreast,
    required this.pitch,
    required this.fareMode,
    required this.fareValue,
  });

  final String code;
  final String rows;
  final String abreast;
  final String pitch;
  final _FareMode fareMode;
  final String fareValue;
}
