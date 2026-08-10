import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// Refund terms: what a traveller gets back when they cancel, and when.
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
/// terms, not today's.
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
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t('console.policies.title'),
                    style: kilo.text.h2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    context.t('console.policies.intro'),
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (_canManage)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: KButton(
                  label: context.t('console.policies.write'),
                  fullWidth: false,
                  icon: Icons.add,
                  onPressed: () => _write(context),
                ),
              ),
          ],
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
        .push<({String name, RefundPolicy policy})>(
          MaterialPageRoute(builder: (_) => const PolicyWizard()),
        );
    if (written == null) return;
    await workspace.saveRefundPolicy(
      name: written.name,
      policy: written.policy,
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
          for (final line in policy.toDomain().describe())
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

  /// True when every band the operator typed is readable **and** the policy
  /// as a whole is one the server will store. The second half is the one that
  /// matters: bands in the wrong order are accepted by every field and wrong
  /// as a set.
  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _tiers.every((t) => t.isBlank || t.toDomain() != null) &&
      _tiers.where((t) => !t.isBlank).length == _policy.tiers.length &&
      _policy.isWellFormed;

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
                      ? () => Navigator.of(
                          context,
                        ).pop((name: _name.text.trim(), policy: _policy))
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
      ],
    );
  }

  Widget _preview(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('console.policies.preview'), style: kilo.text.h2),
        SizedBox(height: kilo.space.s3),
        KCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Every line comes from the domain. The operator cannot write
              // prose here, and that is the point: the sentences a traveller
              // reads are generated from the numbers the server executes.
              for (final line in _policy.describe())
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
