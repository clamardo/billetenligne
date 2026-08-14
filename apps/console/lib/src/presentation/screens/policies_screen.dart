import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// Terms: what a traveller gets back when they cancel, and what it costs them
/// to move to another departure.
///
/// **The operator answers questions; we write the sentences.** ADR-0015 rule
/// 3, and it is not a style preference — a free-text field beside a tier
/// table is how "the app said 90% and they paid 50%" becomes a dispute nobody
/// can settle. Every line under "what the traveller will read" is rendered by
/// `RefundPolicy.describe()`, the same object the server executes.
///
/// **Saving is never an edit.** A booking is judged by the version it was
/// sold under, forever. The screen says so beside the button rather than in a
/// dialog afterwards, and every version stays in the list — because the
/// person answering a question about a March booking needs to read March's
/// terms, not today's. **The change terms ride on the same version**, which is
/// why they are answered in this wizard rather than on a screen of their own:
/// one save, one version, one set of sentences a booking is judged by.
final class PoliciesScreen extends StatelessWidget {
  const PoliciesScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  bool get _canManage => workspace.can('policy.manage');

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final defaultPolicy = workspace.policies
        .where((p) => p.isDefault)
        .firstOrNull;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        KPageHeader(
          context.t('console.policies.title'),
          subtitle: context.t('console.policies.intro'),
          // Null rather than a greyed control: staff who may not write terms
          // are not shown a button that refuses them (ADR-0011).
          action: _canManage
              ? ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: KButton(
                    label: context.t('console.policies.write'),
                    fullWidth: false,
                    icon: Icons.add,
                    onPressed: () => _write(context),
                  ),
                )
              : null,
        ),
        SizedBox(height: kilo.space.s3),

        // What is live right now, stated before the list. An operator who
        // never scrolls should still know whether today's sales carry terms
        // at all — and "none" is a real state with a real consequence.
        KCard(
          // Tinted when there are none, because "no terms" is not a
          // neutral default — it is a decision with a consequence.
          tone: defaultPolicy == null ? kilo.color.warningSoft : null,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  defaultPolicy == null
                      ? context.t('console.policies.noDefault')
                      : context.t('console.policies.defaultIs', {
                          'name': defaultPolicy.name,
                          'version': defaultPolicy.version,
                        }),
                  style: kilo.text.body,
                ),
              ),
              if (_canManage && defaultPolicy != null)
                TextButton(
                  onPressed: () => workspace.setDefaultPolicy(),
                  child: Text(context.t('console.policies.clear')),
                ),
            ],
          ),
        ),
        SizedBox(height: kilo.space.s3),

        if (workspace.policies.isEmpty)
          KCard(
            child: Text(
              context.t('console.policies.none'),
              style: kilo.text.body,
            ),
          )
        else
          for (final policy in workspace.policies)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: _PolicyCard(
                policy: policy,
                canManage: _canManage,
                onApply: () => workspace.setDefaultPolicy(
                  policyId: policy.id,
                  version: policy.version,
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _write(BuildContext context) async {
    final written = await Navigator.of(context)
        .push<
          ({
            String name,
            RefundPolicy policy,
            ChangePolicy change,
            MissedPolicy missed,
          })
        >(MaterialPageRoute(builder: (_) => const PolicyWizard()));
    if (written == null) return;
    await workspace.saveRefundPolicy(
      name: written.name,
      policy: written.policy,
      change: written.change,
      missed: written.missed,
    );
  }
}

class _PolicyCard extends StatelessWidget {
  const _PolicyCard({
    required this.policy,
    required this.canManage,
    required this.onApply,
  });

  final RefundPolicyDto policy;
  final bool canManage;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(policy.displayName, style: kilo.text.body)),
              if (policy.isDefault)
                KChip(
                  context.t('console.policies.current'),
                  tone: KChipTone.success,
                )
              else if (canManage)
                TextButton(
                  onPressed: onApply,
                  child: Text(context.t('console.policies.apply')),
                ),
            ],
          ),
          SizedBox(height: kilo.space.s2),

          // The sentences, not the numbers. Rendered by the domain from the
          // stored terms, which is what makes the console preview and the
          // traveller's screen the same text.
          for (final line in [
            ...policy.toDomain().describe(),
            ...policy.changeToDomain().describe(),
          ])
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s1),
              child: Text(
                '· ${context.tEncoded(line)}',
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
            ),

          if (policy.bookingCount > 0) ...[
            SizedBox(height: kilo.space.s2),
            // The honest answer to "can I just change this?". Every one of
            // these is somebody entitled to these terms and not to the new
            // ones.
            Text(
              context.t('console.policies.soldUnder', {
                'count': policy.bookingCount,
              }),
              style: kilo.text.caption.copyWith(color: kilo.color.contentMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// The wizard. Questions on the left, the traveller's sentences on the right.
///
/// A screen rather than a dialog for the same reason the seat-layout builder
/// is: this is a commercial term somebody will read twice before saving, and
/// a dialog promises it will be quick.
final class PolicyWizard extends StatefulWidget {
  const PolicyWizard({super.key});

  @override
  State<PolicyWizard> createState() => _PolicyWizardState();
}

class _PolicyWizardState extends State<PolicyWizard> {
  final _name = TextEditingController();
  final _processingHours = TextEditingController(text: '72');
  final _changeFree = TextEditingController(text: '24');
  final _changeFee = TextEditingController(text: '10');
  final _changeCutoff = TextEditingController(text: '2');

  /// Zero and zero: not offered. The one default that must not be generous,
  /// because it is a promise about somebody else's seats.
  final _missedWindow = TextEditingController(text: '0');
  final _missedFee = TextEditingController(text: '0');
  var _destination = RefundDestination.source;
  var _refundServiceFee = false;
  final _tiers = <_TierEditor>[];

  @override
  void initState() {
    super.initState();
    // The standard preset, because starting from a blank timeline is starting
    // from a question most operators have never had to answer in this shape.
    _loadPreset(RefundPolicy.standard());
  }

  @override
  void dispose() {
    _name.dispose();
    _processingHours.dispose();
    _changeFree.dispose();
    _changeFee.dispose();
    _changeCutoff.dispose();
    _missedWindow.dispose();
    _missedFee.dispose();
    for (final t in _tiers) {
      t.dispose();
    }
    super.dispose();
  }

  void _loadPreset(RefundPolicy preset) {
    for (final t in _tiers) {
      t.dispose();
    }
    _tiers
      ..clear()
      ..addAll([for (final tier in preset.tiers) _TierEditor.from(tier)]);
    _destination = preset.destination;
    _refundServiceFee = preset.refundServiceFee;
    _processingHours.text = '${preset.processingWindow.inHours}';
  }

  RefundPolicy get _policy => RefundPolicy(
    id: 'draft',
    version: 0,
    tiers: [
      for (final editor in _tiers)
        if (editor.toDomain() case final tier?) tier,
    ],
    destination: _destination,
    processingWindow: Duration(
      hours: int.tryParse(_processingHours.text.trim()) ?? 72,
    ),
    refundServiceFee: _refundServiceFee,
  );

  /// The change terms as typed, defaulting field by field to D-08 rather than
  /// as a block: an operator who clears one box has answered two questions,
  /// not none, and a wizard that reverts all three would lose the two.
  ChangePolicy get _change => ChangePolicy(
    freeBefore: Duration(hours: int.tryParse(_changeFree.text.trim()) ?? 24),
    // Percent in, basis points out — the same conversion the bands make, in
    // the same direction, for the same reason.
    feeBps: (int.tryParse(_changeFee.text.trim()) ?? 10) * 100,
    cutoff: Duration(hours: int.tryParse(_changeCutoff.text.trim()) ?? 2),
  );

  /// What happens to somebody who was late. Zero hours is "not offered", and
  /// it is what the box holds until an operator decides otherwise.
  MissedPolicy get _missed => MissedPolicy(
    window: Duration(hours: int.tryParse(_missedWindow.text.trim()) ?? 0),
    feeBps: (int.tryParse(_missedFee.text.trim()) ?? 0) * 100,
  );

  /// True when every band the operator typed is readable **and** the policy
  /// as a whole is one the server will store. The second half is the one that
  /// matters: bands in the wrong order are accepted by every field and wrong
  /// as a set.
  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _tiers.every((t) => t.isBlank || t.toDomain() != null) &&
      _tiers.where((t) => !t.isBlank).length == _policy.tiers.length &&
      _policy.isWellFormed &&
      _changeIsTyped &&
      _change.isWellFormed &&
      _missedIsTyped &&
      _missed.isWellFormed;

  /// Every change box holds a number. Blank is not zero here: an empty
  /// cutoff would silently save as "no cutoff at all", which is the one
  /// answer nobody would give on purpose.
  bool get _changeIsTyped => [
    _changeFree,
    _changeFee,
    _changeCutoff,
  ].every((c) => int.tryParse(c.text.trim()) != null);

  /// Same rule, same reason: a blank window would save as "not offered"
  /// without anybody having decided that, and the operator would learn about
  /// it from a passenger.
  bool get _missedIsTyped => [
    _missedWindow,
    _missedFee,
  ].every((c) => int.tryParse(c.text.trim()) != null);

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      appBar: AppBar(title: Text(context.t('console.policies.title'))),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(kilo.space.s3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  // Said beside the button, before it is pressed. Rule 2 of
                  // ADR-0015 asks for exactly this, and a dialog afterwards
                  // would be an apology rather than a warning.
                  context.t('console.policies.versionNote'),
                  style: kilo.text.caption.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
              ),
              SizedBox(width: kilo.space.s3),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: KButton(
                  label: context.t('common.actions.save'),
                  fullWidth: false,
                  icon: Icons.check,
                  onPressed: _canSave
                      ? () => Navigator.of(context).pop((
                          name: _name.text.trim(),
                          policy: _policy,
                          change: _change,
                          missed: _missed,
                        ))
                      : null,
                  disabledHint: context.t('console.policies.cannotSave'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final questions = _questions(context);
          final preview = _preview(context);

          if (constraints.maxWidth < 900) {
            return ListView(
              padding: EdgeInsets.all(kilo.space.s4),
              children: [
                questions,
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
                  child: questions,
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

  Widget _questions(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KField(
          label: context.t('console.policies.name'),
          helper: context.t('console.policies.nameHelp'),
          controller: _name,
          autofocus: true,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: kilo.space.s3),

        Text(context.t('console.policies.preset'), style: kilo.text.label),
        SizedBox(height: kilo.space.s2),
        Wrap(
          spacing: kilo.space.s2,
          children: [
            for (final entry in {
              'souple': RefundPolicy.souple(),
              'standard': RefundPolicy.standard(),
              'strict': RefundPolicy.strict(),
            }.entries)
              ActionChip(
                label: Text(context.t('console.policies.presets.${entry.key}')),
                onPressed: () => setState(() => _loadPreset(entry.value)),
              ),
          ],
        ),
        SizedBox(height: kilo.space.s5),

        Text(context.t('console.policies.tiers'), style: kilo.text.h3),
        Text(
          context.t('console.policies.tiersHelp'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s2),

        for (var i = 0; i < _tiers.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: kilo.space.s2),
            child: _TierRow(
              editor: _tiers[i],
              onRemove: () => setState(() => _tiers.removeAt(i).dispose()),
              onChanged: () => setState(() {}),
            ),
          ),

        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: KButton(
            label: context.t('console.policies.addTier'),
            fullWidth: false,
            tone: KButtonTone.secondary,
            icon: Icons.add,
            onPressed: _tiers.length >= 6
                ? null
                : () => setState(() => _tiers.add(_TierEditor())),
          ),
        ),
        SizedBox(height: kilo.space.s5),

        DropdownButtonFormField<RefundDestination>(
          isExpanded: true,
          initialValue: _destination,
          decoration: InputDecoration(
            labelText: context.t('console.policies.destination'),
          ),
          items: [
            for (final d in RefundDestination.values)
              DropdownMenuItem(
                value: d,
                child: Text(
                  context.t('console.policies.destinations.${d.name}'),
                ),
              ),
          ],
          onChanged: (v) => setState(() => _destination = v ?? _destination),
        ),
        SizedBox(height: kilo.space.s3),

        // Cash at the counter has no processing window to promise: the money
        // is handed over when somebody walks in, and "within 72 hours" would
        // be a promise about their opening times.
        if (_destination != RefundDestination.agencyCash)
          KField(
            label: context.t('console.policies.processingHours'),
            controller: _processingHours,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
        SizedBox(height: kilo.space.s3),

        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _refundServiceFee,
          title: Text(context.t('console.policies.refundServiceFee')),
          subtitle: Text(context.t('console.policies.refundServiceFeeHelp')),
          onChanged: (v) => setState(() => _refundServiceFee = v),
        ),
        SizedBox(height: kilo.space.s5),

        // The same version's other half. Asked here rather than on a screen
        // of its own because a booking carries one `(id, version)` stamp: two
        // screens would mean two saves and two versions for one decision.
        Text(context.t('console.policies.change'), style: kilo.text.h3),
        Text(
          context.t('console.policies.changeHelp'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s2),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: KField(
                label: context.t('console.policies.changeFree'),
                controller: _changeFree,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(width: kilo.space.s3),
            Expanded(
              child: KField(
                label: context.t('console.policies.changeFee'),
                controller: _changeFee,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(width: kilo.space.s3),
            Expanded(
              child: KField(
                label: context.t('console.policies.changeCutoff'),
                controller: _changeCutoff,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s2),

        // Said in the questions rather than only in the preview, because it
        // is the answer to "and if the coach breaks down?" — which is the
        // first thing an operator asks when they read a cutoff.
        Text(
          context.t('console.policies.changeInvoluntary'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),

        SizedBox(height: kilo.space.s4),

        // The third question on the same save, because it is the same
        // commercial decision seen from the counter: what happens to somebody
        // who was late. Zero hours means the ticket is spent, which is what
        // every policy written before this question was asked already does.
        Text(context.t('console.policies.missed'), style: kilo.text.h3),
        Text(
          context.t('console.policies.missedHelp'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s2),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: KField(
                label: context.t('console.policies.missedWindow'),
                controller: _missedWindow,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(width: kilo.space.s3),
            Expanded(
              child: KField(
                label: context.t('console.policies.missedFee'),
                controller: _missedFee,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s2),
        Text(
          context.t('console.policies.missedCounter'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
      ],
    );
  }

  Widget _preview(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KSectionHeader(context.t('console.policies.preview')),
        SizedBox(height: kilo.space.s3),
        KCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Every line comes from the domain. The operator cannot write
              // prose here, and that is the point: the sentences a traveller
              // reads are generated from the numbers the server executes.
              for (final line in [
                ..._policy.describe(),
                if (_change.isWellFormed) ..._change.describe(),
                // Including "not offered", which is a sentence rather than a
                // silence: an operator has to see what they are promising a
                // passenger who turns up at 06h05, and the absence of a line
                // reads as an unanswered question rather than a decision.
                if (_missed.isWellFormed) ..._missed.describe(),
              ])
                Padding(
                  padding: EdgeInsets.only(bottom: kilo.space.s2),
                  child: Text(
                    '· ${context.tEncoded(line)}',
                    style: kilo.text.body,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One band's controllers, and how they become a [RefundTier].
final class _TierEditor {
  _TierEditor()
    : hours = TextEditingController(),
      rate = TextEditingController(),
      flatFee = TextEditingController();

  _TierEditor.from(RefundTier tier)
    : hours = TextEditingController(text: '${tier.minLeadTime.inHours}'),
      rate = TextEditingController(text: '${tier.rateBps ~/ 100}'),
      flatFee = TextEditingController(
        text: tier.flatFeeMinor == 0 ? '' : '${tier.flatFeeMinor}',
      );

  final TextEditingController hours;
  final TextEditingController rate;
  final TextEditingController flatFee;

  bool get isBlank =>
      hours.text.trim().isEmpty &&
      rate.text.trim().isEmpty &&
      flatFee.text.trim().isEmpty;

  void dispose() {
    hours.dispose();
    rate.dispose();
    flatFee.dispose();
  }

  RefundTier? toDomain() {
    final h = int.tryParse(hours.text.trim());
    final percent = int.tryParse(rate.text.trim());
    if (h == null || h < 0 || percent == null) return null;
    if (percent < 0 || percent > 100) return null;

    final fee = flatFee.text.trim().isEmpty
        ? 0
        : int.tryParse(flatFee.text.trim());
    if (fee == null || fee < 0) return null;

    return RefundTier(
      minLeadTime: Duration(hours: h),
      // Percent in, basis points out. The operator thinks in percent and the
      // ledger thinks in integers, and this is the one place they meet.
      rateBps: percent * 100,
      flatFeeMinor: fee,
    );
  }
}

class _TierRow extends StatelessWidget {
  const _TierRow({
    required this.editor,
    required this.onRemove,
    required this.onChanged,
  });

  final _TierEditor editor;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return KCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: KField(
              label: context.t('console.policies.leadTime'),
              controller: editor.hours,
              keyboardType: TextInputType.number,
              onChanged: (_) => onChanged(),
            ),
          ),
          SizedBox(width: kilo.space.s3),
          Expanded(
            child: KField(
              label: context.t('console.policies.rate'),
              controller: editor.rate,
              keyboardType: TextInputType.number,
              onChanged: (_) => onChanged(),
            ),
          ),
          SizedBox(width: kilo.space.s3),
          Expanded(
            child: KField(
              label: context.t('console.policies.flatFee', {
                'currency': Market.current.currency.code,
              }),
              controller: editor.flatFee,
              keyboardType: TextInputType.number,
              onChanged: (_) => onChanged(),
            ),
          ),
          IconButton(
            tooltip: context.t('console.policies.removeTier'),
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
