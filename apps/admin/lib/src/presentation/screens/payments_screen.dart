import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/admin_workspace.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';

/// The reconciliation queue (ADR-0005).
///
/// Every row here is money in limbo and a customer in the dark. So it is a
/// work queue and not a report: longest-waiting first, everything needed to
/// decide *in the row*, and a way to reach the person waiting.
///
/// Three exits, and `reask` is offered first on purpose. Most of these
/// resolve once the rail has caught up, and a queue whose only tools are
/// "declare it paid" and "declare it lost" invites somebody to guess when
/// they could have known.
final class PaymentsScreen extends StatelessWidget {
  const PaymentsScreen({required this.workspace, super.key});

  final AdminWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final payments = workspace.payments;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        Text(context.t('admin.payments.title'), style: kilo.text.h1),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('admin.payments.subtitle', {'count': payments.length}),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s4),

        if (payments.isEmpty && !workspace.busy)
          KStateView(
            KEmpty(
              title: context.t('admin.payments.emptyTitle'),
              body: context.t('admin.payments.emptyBody'),
            ),
          )
        else
          for (final payment in payments)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s3),
              child: _PaymentCard(workspace: workspace, payment: payment),
            ),
      ],
    );
  }
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({required this.workspace, required this.payment});

  final AdminWorkspace workspace;
  final UnresolvedPaymentDto payment;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final waited = DateTime.now().toUtc().difference(payment.createdAt);

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KMoney(
                      payment.amount.format(locale: context.language),
                      size: KMoneySize.hero,
                    ),
                    SizedBox(height: kilo.space.s1),
                    Text(
                      context.t('admin.payments.booking', {
                        'ref': payment.bookingRef,
                      }),
                      style: kilo.text.body,
                    ),
                    Text(
                      payment.operatorName,
                      style: kilo.text.caption.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  KChip(
                    context.t('enum.PaymentState.${payment.state}'),
                    tone: KChipTone.warning,
                  ),
                  SizedBox(height: kilo.space.s1),
                  Text(
                    context.t('admin.payments.waiting', {
                      'duration': Format.age(waited, locale: context.language),
                    }),
                    style: kilo.text.caption.copyWith(
                      // Every hour here is an hour a traveller does not know
                      // whether they have a seat.
                      color: waited.inHours >= 2
                          ? kilo.color.danger
                          : kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: kilo.space.s3),
          const Divider(height: 1),
          SizedBox(height: kilo.space.s3),

          _Line(
            context.t('admin.payments.payer'),
            Format.msisdn(payment.payerMsisdn),
          ),
          _Line(
            context.t('admin.payments.rail'),
            context.t('enum.MobileOperator.${payment.railId}'),
          ),
          // The reference somebody reads down a phone line to a telco's
          // support desk, which is how most of these actually resolve.
          _Line(
            context.t('admin.payments.railRef'),
            payment.railTransactionId ?? context.t('admin.payments.noRailRef'),
          ),
          _Line(
            context.t('admin.payments.traveller'),
            payment.travellerPhone == null
                ? (payment.travellerEmail ??
                      context.t('admin.payments.noTraveller'))
                : Format.msisdn(payment.travellerPhone!),
          ),
          if (payment.departsAt != null)
            _Line(
              context.t('admin.payments.tripLabel'),
              context.t('admin.payments.departure', {
                'from': payment.originCity ?? '—',
                'to': payment.destinationCity ?? '—',
                'date': Format.dateTime(payment.departsAt!),
              }),
            ),
          _Line(
            context.t('admin.payments.pollsLabel'),
            payment.lastPolledAt == null
                ? context.t('admin.payments.neverPolled')
                : context.t('admin.payments.polls', {
                    'count': payment.pollAttempts,
                    'time': Format.dateTime(payment.lastPolledAt!),
                  }),
          ),

          SizedBox(height: kilo.space.s3),
          _Exits(workspace: workspace, payment: payment),
        ],
      ),
    );
  }
}

/// The queue's only three exits.
class _Exits extends StatelessWidget {
  const _Exits({required this.workspace, required this.payment});

  final AdminWorkspace workspace;
  final UnresolvedPaymentDto payment;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final allowed =
        workspace.can('platform.payment.reconcile') && workspace.hasReason;
    final hint = !workspace.can('platform.payment.reconcile')
        ? context.t('admin.operator.notAllowed')
        : context.t('admin.reason.required');

    return Wrap(
      spacing: kilo.space.s2,
      runSpacing: kilo.space.s2,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: KButton(
            label: context.t('admin.payments.reask'),
            fullWidth: false,
            icon: Icons.refresh,
            onPressed: allowed
                ? () => workspace.resolve(
                    intentId: payment.intentId,
                    outcome: 'reask',
                  )
                : null,
            disabledHint: allowed ? null : hint,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: KButton(
            label: context.t('admin.payments.captured'),
            fullWidth: false,
            tone: KButtonTone.secondary,
            onPressed: allowed
                ? () => _confirm(context, outcome: 'captured')
                : null,
            disabledHint: allowed ? null : hint,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: KButton(
            label: context.t('admin.payments.failed'),
            fullWidth: false,
            tone: KButtonTone.danger,
            onPressed: allowed
                ? () => _confirm(context, outcome: 'failed')
                : null,
            disabledHint: allowed ? null : hint,
          ),
        ),
      ],
    );
  }

  /// Both terminal exits go through the same dialog, and both demand a
  /// sentence about *this* payment. The standing reason says why somebody is
  /// in the back office; this says what they saw.
  Future<void> _confirm(BuildContext context, {required String outcome}) async {
    final result = await showDialog<({String evidence, String failureCode})>(
      context: context,
      builder: (_) => _ResolutionDialog(outcome: outcome),
    );
    if (result == null) return;

    await workspace.resolve(
      intentId: payment.intentId,
      outcome: outcome,
      evidence: result.evidence,
      failureCode: outcome == 'failed' ? result.failureCode : null,
    );
  }
}

/// Declaring a payment captured or failed.
///
/// Its own widget so the evidence field's controller outlives the dialog's
/// closing animation, and so "no evidence, no exit" is one condition in one
/// place: this is the row that settles a dispute six weeks later, and
/// "somebody marked it paid" is not an answer.
class _ResolutionDialog extends StatefulWidget {
  const _ResolutionDialog({required this.outcome});

  final String outcome;

  @override
  State<_ResolutionDialog> createState() => _ResolutionDialogState();
}

class _ResolutionDialogState extends State<_ResolutionDialog> {
  final _evidence = TextEditingController();
  var _failureCode = PaymentFailureCode.timeoutNoResponse.wire;

  bool get _captured => widget.outcome == 'captured';

  @override
  void dispose() {
    _evidence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return AlertDialog(
      title: Text(
        context.t(
          _captured
              ? 'admin.payments.confirmCaptured'
              : 'admin.payments.confirmFailed',
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t(
                  _captured
                      ? 'admin.payments.capturedHelp'
                      : 'admin.payments.failedHelp',
                ),
                style: kilo.text.body,
              ),
              SizedBox(height: kilo.space.s3),
              KField(
                label: context.t('admin.payments.evidence'),
                helper: context.t('admin.payments.evidenceHelp'),
                controller: _evidence,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
              ),
              if (!_captured) ...[
                SizedBox(height: kilo.space.s3),
                Text(
                  context.t('admin.payments.failureCode'),
                  style: kilo.text.label,
                ),
                SizedBox(height: kilo.space.s2),
                // The same taxonomy the rails use, so a resolution puts a
                // sentence on a traveller's screen rather than "payment
                // failed".
                DropdownButton<String>(
                  value: _failureCode,
                  isExpanded: true,
                  items: [
                    for (final code in PaymentFailureCode.values)
                      DropdownMenuItem(
                        value: code.wire,
                        // `wire` already carries its family, so the key is the
                        // code's own `messageKey` — the same one the
                        // traveller's screen renders.
                        child: Text(context.t('${code.messageKey}.title')),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _failureCode = value ?? _failureCode),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('common.actions.cancel')),
        ),
        FilledButton(
          onPressed: _evidence.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop((
                  evidence: _evidence.text.trim(),
                  failureCode: _failureCode,
                )),
          child: Text(context.t('common.actions.confirm')),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: kilo.space.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ),
          Expanded(child: SelectableText(value, style: kilo.text.body)),
        ],
      ),
    );
  }
}
