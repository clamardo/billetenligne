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
    return LayoutDraft(name: _name.text, mode: _mode, sections: sections);
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final draft = _draft;

    return Scaffold(
      appBar: AppBar(title: Text(context.t('console.fleet.builder.title'))),
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
                onChanged: (v) => setState(() => _mode = v ?? _mode),
              ),
            ),
            SizedBox(width: kilo.space.s3),
            Expanded(
              child: DropdownButtonFormField<SeatNumbering>(
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
                onChanged: (v) => setState(() => _numbering = v ?? _numbering),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s5),

        Text(context.t('console.fleet.builder.sections'), style: kilo.text.h2),
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
                  : () => setState(() => _sections.removeAt(i).dispose()),
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
                : () => setState(() => _sections.add(_SectionEditor())),
          ),
        ),
      ],
    );
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
        if (labels.isNotEmpty)
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
                  KSeat(label: label, state: KSeatState.available),
              ],
              selected: const {},
              // Nothing to select: this is a drawing of a coach, not a sale.
              onToggle: (_) {},
              labels: KSeatMapLabels(
                front: context.t('travel.seatmap.front'),
                free: context.t('travel.seatmap.free'),
                chosen: context.t('travel.seatmap.chosen'),
                taken: context.t('travel.seatmap.taken'),
              ),
            ),
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
    required this.onChanged,
  });

  final _SectionEditor editor;
  final int index;
  final int startRow;
  final VoidCallback? onRemove;
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
