import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Who is driving this coach and who is taking the tickets (J3).
///
/// Unlike the sheets around it, this one does not answer with a draft. A
/// roster is edited in a loop — put somebody on, take somebody off, look at
/// what is left — and a dialog that closed after one write would be opened
/// three times to fill one departure. So it writes through [onAssign] and
/// [onUnassign] and redraws from the list they return, which is the server's
/// answer rather than its own guess about what the server did.
///
/// Two jobs, listed separately, because they are separate on the coach: the
/// person driving and the person at the door are usually two people here, and
/// which of them holds the operator's handset decides whose tap is evidence
/// in a delay dispute. The same person may hold both — a three-coach company
/// runs that way, and a screen that forbade it would be a screen they cannot
/// use.
final class CrewSheet extends StatefulWidget {
  const CrewSheet({
    required this.routeCode,
    required this.crew,
    required this.staff,
    required this.onAssign,
    required this.onUnassign,
    required this.failureKey,
    this.departed = false,
    super.key,
  });

  final String routeCode;
  final List<CrewMemberDto> crew;

  /// Everybody at this company. Filtered here rather than by the server,
  /// because the console already has the list and the same list answers both
  /// jobs.
  final List<StaffDto> staff;

  /// Both return the roster as it now stands, or null when the write was
  /// refused.
  final Future<List<CrewMemberDto>?> Function(String userId, String role)
  onAssign;
  final Future<List<CrewMemberDto>?> Function(String userId, String role)
  onUnassign;

  /// The catalog key of the last failure, read after a write comes back null.
  ///
  /// The console's own failure banner lives in the shell, which is **behind**
  /// this dialog: without this, a dispatcher who rosters somebody the server
  /// refuses taps a button and watches nothing happen.
  final String? Function() failureKey;

  /// A coach already on the road. Its roster is a record from that moment,
  /// so it is shown and not edited.
  final bool departed;

  @override
  State<CrewSheet> createState() => _CrewSheetState();
}

class _CrewSheetState extends State<CrewSheet> {
  late List<CrewMemberDto> _crew = widget.crew;
  bool _busy = false;
  String? _refusal;

  Future<void> _write(Future<List<CrewMemberDto>?> Function() work) async {
    setState(() {
      _busy = true;
      _refusal = null;
    });
    final updated = await work();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) {
        _crew = updated;
      } else {
        _refusal = widget.failureKey();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(kilo.space.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.routeCode, style: kilo.text.h3),
              Text(
                context.t('console.crew.title'),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),

              // A roster is a plan; once the coach has gone it is a record.
              // Said at the top rather than discovered by pressing a button
              // that is not there.
              if (widget.departed) ...[
                SizedBox(height: kilo.space.s3),
                Text(
                  context.t('console.crew.gone'),
                  style: kilo.text.bodySm.copyWith(color: kilo.color.warning),
                ),
              ],

              // Why the last write did not happen — this person does not
              // work here, is not qualified, has left, or the coach has gone.
              if (_refusal != null) ...[
                SizedBox(height: kilo.space.s3),
                Text(
                  context.t(_refusal!),
                  style: kilo.text.bodySm.copyWith(color: kilo.color.danger),
                ),
              ],

              SizedBox(height: kilo.space.s4),
              for (final role in const ['driver', 'conductor']) ...[
                _Job(
                  role: role,
                  rostered: [
                    for (final c in _crew)
                      if (c.role == role) c,
                  ],
                  candidates: _candidatesFor(role),
                  editable: !widget.departed && !_busy,
                  onAdd: (userId) =>
                      _write(() => widget.onAssign(userId, role)),
                  onRemove: (userId) =>
                      _write(() => widget.onUnassign(userId, role)),
                ),
                SizedBox(height: kilo.space.s4),
              ],

              KButton(
                label: context.t('console.crew.done'),
                tone: KButtonTone.secondary,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Everybody who could take this job and has not already got it.
  ///
  /// Revoked staff are out, and so is anybody already rostered in this job on
  /// this coach — offering them is offering a button whose only outcome is
  /// nothing happening. The server refuses all three cases as well; refusing
  /// them here means the dispatcher finds out while they are still choosing.
  List<StaffDto> _candidatesFor(String role) {
    final taken = {
      for (final c in _crew)
        if (c.role == role) c.userId,
    };
    return [
      for (final person in widget.staff)
        if (!person.isRevoked &&
            person.roles.contains(role) &&
            !taken.contains(person.userId))
          person,
    ];
  }
}

class _Job extends StatelessWidget {
  const _Job({
    required this.role,
    required this.rostered,
    required this.candidates,
    required this.editable,
    required this.onAdd,
    required this.onRemove,
  });

  final String role;
  final List<CrewMemberDto> rostered;
  final List<StaffDto> candidates;
  final bool editable;
  final void Function(String userId) onAdd;
  final void Function(String userId) onRemove;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('enum.CrewRole.$role'), style: kilo.text.label),
        SizedBox(height: kilo.space.s2),

        if (rostered.isEmpty)
          Text(
            context.t('console.crew.empty'),
            style: kilo.text.bodySm.copyWith(
              color: kilo.color.contentSecondary,
            ),
          )
        else
          for (final member in rostered)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: Row(
                children: [
                  Expanded(
                    child: _Person(
                      name: member.fullName,
                      staffRef: member.staffRef,
                    ),
                  ),
                  if (editable)
                    IconButton(
                      tooltip: context.t('console.crew.remove'),
                      icon: const Icon(Icons.person_remove_outlined),
                      onPressed: () => onRemove(member.userId),
                    ),
                ],
              ),
            ),

        if (editable) ...[
          SizedBox(height: kilo.space.s2),
          if (candidates.isEmpty)
            // Names the cause and where to fix it. An empty picker on its own
            // reads as a screen that failed to load rather than as a company
            // that has not granted the role to anybody.
            Text(
              context.t('console.crew.noneQualified'),
              style: kilo.text.bodySm.copyWith(color: kilo.color.warning),
            )
          else
            Wrap(
              spacing: kilo.space.s2,
              runSpacing: kilo.space.s2,
              children: [
                for (final person in candidates)
                  KButton(
                    label: _label(person),
                    tone: KButtonTone.secondary,
                    fullWidth: false,
                    icon: Icons.person_add_alt,
                    onPressed: () => onAdd(person.userId),
                  ),
              ],
            ),
        ],
      ],
    );
  }

  /// The operator's own number for somebody, when they have one. It is what a
  /// dispatcher says out loud on the radio — "quatorze" rather than a name
  /// two of the drivers share.
  String _label(StaffDto person) {
    // A name, or the phone the invitation went to, or nothing at all —
    // never the word "Add", which is what a careless fallback produces and
    // which would read as a person called Add.
    final name = person.fullName ?? person.phone ?? '—';
    return person.staffRef == null ? name : '$name · ${person.staffRef}';
  }
}

class _Person extends StatelessWidget {
  const _Person({required this.name, required this.staffRef});

  final String? name;
  final String? staffRef;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Row(
      children: [
        Icon(
          Icons.badge_outlined,
          size: kilo.space.s4,
          color: kilo.color.contentSecondary,
        ),
        SizedBox(width: kilo.space.s2),
        Flexible(
          child: Text(
            name ?? '—',
            overflow: TextOverflow.ellipsis,
            style: kilo.text.body,
          ),
        ),
        if (staffRef != null) ...[
          SizedBox(width: kilo.space.s2),
          KChip(staffRef!, tone: KChipTone.neutral),
        ],
      ],
    );
  }
}
