import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/admin_workspace.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';
import 'queue_screen.dart' show statusTone;

/// One operator's file, on one page.
///
/// Documents, the agreement, the counts and the audit trail together, because
/// tab-hunting during a review is how a missing insurance certificate gets
/// approved (`03-operator-lifecycle.md` §6).
///
/// The decision buttons are drawn from [OperatorLifecycle] — the same table
/// the server's SQL guard is conditional on — and from this person's
/// capabilities. A button that is not offered is one the server would refuse,
/// and it is not offered rather than greyed with no explanation: what is
/// missing is said in words next to it.
final class OperatorScreen extends StatelessWidget {
  const OperatorScreen({
    required this.workspace,
    required this.detail,
    super.key,
  });

  final AdminWorkspace workspace;
  final AdminOperatorDetailDto detail;

  AdminOperatorDto get operator => detail.operator;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: workspace.closeOperator,
            icon: const Icon(Icons.arrow_back),
            label: Text(context.t('admin.operator.back')),
          ),
        ),
        SizedBox(height: kilo.space.s2),

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(operator.legalName, style: kilo.text.h1),
                  if (operator.tradingName != null)
                    Text(
                      operator.tradingName!,
                      style: kilo.text.body.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                ],
              ),
            ),
            KChip(
              context.t('admin.status.${operator.status}'),
              tone: statusTone(operator.status),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s4),

        _Decisions(workspace: workspace, operator: operator),
        SizedBox(height: kilo.space.s4),

        _Identity(operator: operator),
        SizedBox(height: kilo.space.s4),

        _Commission(workspace: workspace, operator: operator),
        SizedBox(height: kilo.space.s4),

        _Documents(documents: detail.documents),
        SizedBox(height: kilo.space.s4),

        _Trail(entries: detail.trail),
      ],
    );
  }
}

class _Decisions extends StatelessWidget {
  const _Decisions({required this.workspace, required this.operator});

  final AdminWorkspace workspace;
  final AdminOperatorDto operator;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final available = OperatorLifecycle.decisionsFrom(operator.status);

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('admin.operator.decisions'), style: kilo.text.h2),
          SizedBox(height: kilo.space.s3),

          if (available.isEmpty)
            Text(
              context.t('admin.operator.unavailableHere', {
                'status': context.t('admin.status.${operator.status}'),
              }),
              style: kilo.text.body.copyWith(
                color: kilo.color.contentSecondary,
              ),
            )
          else
            Wrap(
              spacing: kilo.space.s2,
              runSpacing: kilo.space.s2,
              children: [
                for (final decision in available)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: KButton(
                      label: context.t('admin.decision.$decision'),
                      fullWidth: false,
                      tone: _tone(decision),
                      onPressed:
                          workspace.can(_capabilityFor(decision)) &&
                              workspace.hasReason
                          ? () => _confirm(context, decision)
                          : null,
                      // Never a bare grey button. There are exactly two
                      // reasons this is unavailable and both are fixable by
                      // the person looking at it.
                      disabledHint: !workspace.can(_capabilityFor(decision))
                          ? context.t('admin.operator.notAllowed')
                          : context.t('admin.reason.required'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Reviewing is not suspending. The same split the server checks per
  /// outcome rather than per route.
  static String _capabilityFor(String decision) => switch (decision) {
    'suspend' || 'reinstate' => 'platform.operator.suspend',
    _ => 'platform.operator.review',
  };

  static KButtonTone _tone(String decision) => switch (decision) {
    'reject' || 'suspend' => KButtonTone.danger,
    'approve' || 'activate' || 'reinstate' => KButtonTone.primary,
    _ => KButtonTone.secondary,
  };

  Future<void> _confirm(BuildContext context, String decision) async {
    final detail = await showDialog<String>(
      context: context,
      builder: (_) => _DecisionDialog(
        decision: decision,
        operatorName: operator.legalName,
        reason: workspace.reason,
      ),
    );
    if (detail == null) return;
    await workspace.decide(
      operatorId: operator.id,
      decision: decision,
      detail: detail.isEmpty ? null : detail,
    );
  }
}

/// Confirming a decision, with room to say what is missing.
///
/// Its own widget so that the note field's controller is owned by something
/// with a `dispose` — a controller disposed by the caller the instant the
/// dialog pops is one the closing animation is still rebuilding.
class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({
    required this.decision,
    required this.operatorName,
    required this.reason,
  });

  final String decision;
  final String operatorName;
  final String reason;

  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  final _detail = TextEditingController();

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return AlertDialog(
      title: Text(
        context.t('admin.decision.confirmTitle', {
          'decision': context.t('admin.decision.${widget.decision}'),
          'operator': widget.operatorName,
        }),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The standing reason is shown, not re-typed. It is already going
            // into the audit row; prompting for it twice is what teaches
            // people to type "review" twice.
            Text(
              widget.reason,
              style: kilo.text.body.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            SizedBox(height: kilo.space.s3),
            KField(
              label: context.t('admin.decision.detail'),
              helper: context.t('admin.decision.detailHelp'),
              controller: _detail,
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('common.actions.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_detail.text.trim()),
          child: Text(context.t('admin.decision.submit')),
        ),
      ],
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.operator});

  final AdminOperatorDto operator;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final missing = context.t('admin.operator.missing');

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('admin.operator.identity'), style: kilo.text.h2),
          SizedBox(height: kilo.space.s3),
          _Line(context.t('admin.operator.code'), operator.code),
          _Line(context.t('admin.operator.market'), operator.marketCode),
          _Line(
            context.t('admin.operator.rccm'),
            operator.rccmNumber ?? missing,
          ),
          _Line(context.t('admin.operator.taxId'), operator.taxId ?? missing),
          SizedBox(height: kilo.space.s2),
          Text(
            context.t('admin.operator.created', {
              'date': Format.date(operator.createdAt),
            }),
            style: kilo.text.caption.copyWith(
              color: kilo.color.contentSecondary,
            ),
          ),
        ],
      ),
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

/// What this client negotiated.
///
/// A percentage in the field and basis points on the wire. A rate that
/// arrives as `0.075` is a rate somebody eventually sends as `7.5`, and the
/// difference is a hundredfold error in what we take from a fare.
class _Commission extends StatefulWidget {
  const _Commission({required this.workspace, required this.operator});

  final AdminWorkspace workspace;
  final AdminOperatorDto operator;

  @override
  State<_Commission> createState() => _CommissionState();
}

class _CommissionState extends State<_Commission> {
  late final _field = TextEditingController(
    text: _percentText(widget.operator.commissionBps),
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    // Deliberately the strictest capability on the page. A commission is the
    // platform's side of a signed agreement, and reviewing an application is
    // not the same authority as changing what we charge.
    final allowed = widget.workspace.can('platform.operator.offboard');
    final bps = _bpsFrom(_field.text);

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('admin.commission.title'), style: kilo.text.h2),
          SizedBox(height: kilo.space.s1),
          Text(
            context.t('admin.commission.current', {
              'rate': CommissionTerm(widget.operator.commissionBps).display,
            }),
            style: kilo.text.body,
          ),
          SizedBox(height: kilo.space.s3),
          KField(
            label: context.t('admin.commission.label'),
            helper: context.t('admin.commission.help'),
            controller: _field,
            enabled: allowed,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            error: bps == null
                ? context.t('admin.commission.invalid', {
                    'max': CommissionTerm.maxBps ~/ 100,
                  })
                : null,
          ),
          SizedBox(height: kilo.space.s3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: KButton(
              label: context.t('admin.commission.save'),
              fullWidth: false,
              onPressed:
                  allowed &&
                      widget.workspace.hasReason &&
                      bps != null &&
                      bps != widget.operator.commissionBps
                  ? () => widget.workspace.setCommission(
                      operatorId: widget.operator.id,
                      commissionBps: bps,
                    )
                  : null,
              disabledHint: !allowed
                  ? context.t('admin.operator.notAllowed')
                  : (!widget.workspace.hasReason
                        ? context.t('admin.reason.required')
                        : null),
            ),
          ),
        ],
      ),
    );
  }

  static String _percentText(int bps) =>
      CommissionTerm(bps).display.replaceAll('%', '');

  /// `7.5` → 750, and null for anything the domain would refuse. Parsed here
  /// rather than trusted to the server so a typo is caught before it becomes
  /// a 400 with no field named.
  static int? _bpsFrom(String raw) {
    final value = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (value == null) return null;
    final bps = (value * 100).round();
    if (bps < 0 || bps > CommissionTerm.maxBps) return null;
    return bps;
  }
}

class _Documents extends StatelessWidget {
  const _Documents({required this.documents});

  final List<KybDocumentDto> documents;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final now = DateTime.now().toUtc();

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('admin.operator.documents'), style: kilo.text.h2),
          SizedBox(height: kilo.space.s3),
          if (documents.isEmpty)
            Text(
              context.t('admin.operator.noDocuments'),
              style: kilo.text.body.copyWith(color: kilo.color.warning),
            )
          else
            for (final document in documents)
              Padding(
                padding: EdgeInsets.only(bottom: kilo.space.s2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _docLabel(context, document.docType),
                            style: kilo.text.body,
                          ),
                          Text(
                            _state(context, document, now),
                            style: kilo.text.caption.copyWith(
                              color: kilo.color.contentSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    KChip(
                      document.isVerified
                          ? context.t('admin.operator.documentVerified', {
                              'date': Format.date(document.verifiedAt!),
                            })
                          : context.t('admin.operator.documentPending'),
                      tone: document.isVerified
                          ? KChipTone.success
                          : KChipTone.warning,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  /// Falls back to the raw type rather than an empty line: the list a
  /// regulator asks for changes, and a document we have no label for is still
  /// a document somebody has to look at.
  static String _docLabel(BuildContext context, String type) {
    final key = 'admin.docType.$type';
    final label = context.t(key);
    return label == key ? type : label;
  }

  static String _state(BuildContext context, KybDocumentDto doc, DateTime now) {
    if (doc.rejectedReason != null) {
      return context.t('admin.operator.documentRejected', {
        'reason': doc.rejectedReason!,
      });
    }
    final expires = doc.expiresAt;
    if (expires == null) return Format.date(doc.createdAt);
    return expires.isBefore(now)
        ? context.t('admin.operator.documentExpired', {
            'date': Format.date(expires),
          })
        : context.t('admin.operator.documentExpires', {
            'date': Format.date(expires),
          });
  }
}

/// The immutable trail. Read-only here, as it is everywhere.
class _Trail extends StatelessWidget {
  const _Trail({required this.entries});

  final List<AuditEntryDto> entries;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('admin.operator.trail'), style: kilo.text.h2),
          SizedBox(height: kilo.space.s3),
          if (entries.isEmpty)
            Text(
              context.t('admin.operator.noTrail'),
              style: kilo.text.body.copyWith(
                color: kilo.color.contentSecondary,
              ),
            )
          else
            for (final entry in entries)
              Padding(
                padding: EdgeInsets.only(bottom: kilo.space.s2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(entry.action, style: kilo.text.code),
                        ),
                        Text(
                          Format.dateTime(entry.createdAt),
                          style: kilo.text.caption.copyWith(
                            color: kilo.color.contentSecondary,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      context.t('admin.operator.trailBy', {
                        'actor':
                            entry.actorId ??
                            context.t('admin.operator.trailSystem'),
                      }),
                      style: kilo.text.caption.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                    // The reason, verbatim. It is the only part of this row
                    // that cannot be reconstructed from anything else.
                    if (entry.reason != null)
                      SelectableText(entry.reason!, style: kilo.text.body),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
