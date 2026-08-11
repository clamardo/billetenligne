import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// Standing agreements with other operators (`08-disruption.md` §5).
///
/// The screen exists to make one already-real behaviour cheaper. When a coach
/// fails at Dolisie the dispatcher walks the forecourt and finds a competitor
/// with room; it settles in cash, at the roadside, with an argument about
/// what a seat was worth. This is that handshake agreed once, in an office,
/// by the people whose job it is.
///
/// Three things it refuses to blur:
///
///   * **Proposed is not agreed.** A proposal sits in its own group at the
///     top, and the card says which side is waiting. An operator who reads
///     "accord créé" and stops thinking about it finds out at the roadside
///     that nobody accepted.
///   * **The ceiling is shown before it bites.** `31 / 40 places ce mois` on
///     the card, not on the refusal. A dispatcher planning a rescue needs to
///     know the agreement is nearly spent while there is still time to find
///     another one.
///   * **The rebill is shown as money on a real fare**, not as a number of
///     basis points. "− 15 % · 7 650 FCFA sur un billet à 9 000" is a term
///     somebody can check; "1500 bps" is a term they have to be taught.
final class ProtectionScreen extends StatelessWidget {
  const ProtectionScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  /// A representative fare, used only to show what the discount means in
  /// francs. Deliberately a round number rather than a real departure's
  /// price: the rebill is computed per seat at the moment of the movement,
  /// and picking one departure's fare here would read as a promise.
  static const _exampleFare = Money.xaf(9000);

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final all = workspace.agreements;
    final waiting = [
      for (final a in all)
        if (a.awaitingUs) a,
    ];
    final rest = [
      for (final a in all)
        if (!a.awaitingUs) a,
    ];
    final canManage = workspace.can('protection.manage');

    // Answering a roadside request is the dispatcher's authority, not the
    // finance office's — the same capability that declares a breakdown.
    final canDecide = workspace.can('disruption.declare');

    // Only the live ones. A declined request from three weeks ago is history,
    // and history on this screen is noise between a dispatcher and the coach
    // they are trying to fill.
    final open =
        [
          for (final request in workspace.requests)
            if (request.isPending) request,
        ]..sort((a, b) {
          if (a.awaitingUs == b.awaitingUs) {
            return b.requestedAt.compareTo(a.requestedAt);
          }
          return a.awaitingUs ? -1 : 1;
        });

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
                    context.t('console.protection.title'),
                    style: kilo.text.h2,
                  ),
                  SizedBox(height: kilo.space.s1),
                  Text(
                    context.t('console.protection.subtitle'),
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (canManage)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: KButton(
                  label: context.t('console.protection.propose'),
                  fullWidth: false,
                  icon: Icons.handshake,
                  onPressed: () => _propose(context),
                ),
              ),
          ],
        ),
        SizedBox(height: kilo.space.s4),

        // The inbound queue, above the agreements and above everything else
        // on this screen. An agreement is read once a quarter; a request is
        // somebody standing at a gare right now, and it is the only thing
        // here with a clock running on it (§2.3).
        if (open.isNotEmpty) ...[
          Text(context.t('console.request.title'), style: kilo.text.label),
          SizedBox(height: kilo.space.s2),
          for (final request in open)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s3),
              child: _RequestCard(
                request: request,
                canDecide: canDecide,
                onDecide: (decision) => workspace.decideProtectionRequest(
                  requestId: request.id,
                  decision: decision,
                ),
              ),
            ),
          SizedBox(height: kilo.space.s3),
        ],

        if (waiting.isNotEmpty) ...[
          Text(
            context.t('console.protection.awaitingUs'),
            style: kilo.text.label,
          ),
          SizedBox(height: kilo.space.s2),
          for (final agreement in waiting)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s3),
              child: _AgreementCard(
                agreement: agreement,
                canManage: canManage,
                onDecide: (decision) => workspace.decideAgreement(
                  agreementId: agreement.id,
                  decision: decision,
                ),
              ),
            ),
          SizedBox(height: kilo.space.s3),
        ],

        if (all.isEmpty && !workspace.busy)
          KStateView(
            KEmpty(
              title: context.t('console.protection.emptyTitle'),
              body: context.t('console.protection.emptyBody'),
            ),
          )
        else
          for (final agreement in rest)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s3),
              child: _AgreementCard(
                agreement: agreement,
                canManage: canManage,
                onDecide: (decision) => workspace.decideAgreement(
                  agreementId: agreement.id,
                  decision: decision,
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _propose(BuildContext context) async {
    final code = TextEditingController();
    final discount = TextEditingController(text: '15');
    final cap = TextEditingController(text: '40');
    var reciprocal = true;
    final corridors = <String>{};

    // Every corridor this operator actually runs, as pairs. Offering a free
    // text field here would let somebody agree to protect a road neither
    // company serves.
    final available = <String>{
      for (final route in workspace.routes)
        Corridor(route.originCity, route.destinationCity).key,
    }.toList()..sort();

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(dialogContext.t('console.protection.propose')),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KField(
                    label: dialogContext.t('console.protection.counterparty'),
                    helper: dialogContext.t(
                      'console.protection.counterpartyHelp',
                    ),
                    controller: code,
                    autofocus: true,
                  ),
                  SizedBox(height: dialogContext.kilo.space.s3),
                  Text(
                    dialogContext.t('console.protection.corridors'),
                    style: dialogContext.kilo.text.label,
                  ),
                  if (available.isEmpty)
                    Text(
                      dialogContext.t('console.protection.noRoutes'),
                      style: dialogContext.kilo.text.caption.copyWith(
                        color: dialogContext.kilo.color.contentSecondary,
                      ),
                    ),
                  for (final key in available)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: corridors.contains(key),
                      title: Text(key.replaceAll('~', ' ↔ ')),
                      onChanged: (on) => setState(() {
                        if (on ?? false) {
                          corridors.add(key);
                        } else {
                          corridors.remove(key);
                        }
                      }),
                    ),
                  SizedBox(height: dialogContext.kilo.space.s3),
                  Row(
                    children: [
                      Expanded(
                        child: KField(
                          label: dialogContext.t('console.protection.discount'),
                          helper: dialogContext.t(
                            'console.protection.discountHelp',
                          ),
                          controller: discount,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      SizedBox(width: dialogContext.kilo.space.s3),
                      Expanded(
                        child: KField(
                          label: dialogContext.t('console.protection.cap'),
                          helper: dialogContext.t('console.protection.capHelp'),
                          controller: cap,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: reciprocal,
                    title: Text(
                      dialogContext.t('console.protection.reciprocal'),
                    ),
                    subtitle: Text(
                      dialogContext.t('console.protection.reciprocalHelp'),
                      style: dialogContext.kilo.text.caption,
                    ),
                    onChanged: (on) => setState(() => reciprocal = on),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.t('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: corridors.isEmpty || code.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.t('console.protection.send')),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;

    final percent = int.tryParse(discount.text.trim()) ?? 0;
    final ceiling = int.tryParse(cap.text.trim());

    await workspace.proposeAgreement(
      counterpartyCode: code.text.trim().toUpperCase(),
      corridors: corridors.toList(),
      reciprocal: reciprocal,
      // Typed as a percentage because that is how the term is spoken. Basis
      // points are the storage format, not the vocabulary.
      rebillDiscountBps: percent * 100,
      monthlyCapSeats: ceiling != null && ceiling > 0 ? ceiling : null,
    );
  }

  static Money rebillOn(Money fare, int discountBps) =>
      fare.percentBps(10000 - discountBps);
}

class _AgreementCard extends StatelessWidget {
  const _AgreementCard({
    required this.agreement,
    required this.canManage,
    required this.onDecide,
  });

  final ProtectionAgreementDto agreement;
  final bool canManage;
  final void Function(String decision) onDecide;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final rebill = ProtectionScreen.rebillOn(
      ProtectionScreen._exampleFare,
      agreement.rebillDiscountBps,
    );

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
                    Text(agreement.counterpartyName, style: kilo.text.h3),
                    SizedBox(height: kilo.space.s1),
                    Text(
                      [
                        for (final key in agreement.corridors)
                          key.replaceAll('~', ' ↔ '),
                      ].join(' · '),
                      style: kilo.text.caption.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              KChip(
                context.t('console.protection.state.${agreement.state}'),
                tone: switch (agreement.state) {
                  'active' => KChipTone.success,
                  'proposed' => KChipTone.warning,
                  _ => KChipTone.neutral,
                },
              ),
            ],
          ),
          SizedBox(height: kilo.space.s3),

          // The terms, as sentences rather than as fields. Somebody reading
          // this is checking whether it still makes sense to be in it.
          _Term(
            label: context.t('console.protection.rebill'),
            value: context.t('console.protection.rebillValue', {
              'percent': '${agreement.rebillDiscountBps ~/ 100}',
              'amount': rebill.format(locale: context.language),
              'fare': ProtectionScreen._exampleFare.format(
                locale: context.language,
              ),
            }),
          ),
          _Term(
            label: context.t('console.protection.direction'),
            value: context.t(
              agreement.reciprocal
                  ? 'console.protection.bothWays'
                  : 'console.protection.oneWay',
            ),
          ),
          if (agreement.monthlyCapSeats case final ceiling?)
            _Term(
              label: context.t('console.protection.cap'),
              value: context.t('console.protection.capValue', {
                'used': '${agreement.seatsUsedThisMonth}',
                'cap': '$ceiling',
              }),
            ),

          SizedBox(height: kilo.space.s3),
          if (agreement.awaitingUs)
            Text(
              context.t('console.protection.theyProposed', {
                'name': agreement.counterpartyName,
              }),
              style: kilo.text.caption.copyWith(color: kilo.color.warning),
            )
          else if (agreement.state == 'proposed')
            // The line that stops "accord créé" being read as "protected".
            Text(
              context.t('console.protection.weProposed', {
                'name': agreement.counterpartyName,
              }),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),

          if (canManage) ...[
            SizedBox(height: kilo.space.s2),
            Wrap(
              spacing: kilo.space.s2,
              alignment: WrapAlignment.end,
              children: [
                if (agreement.awaitingUs) ...[
                  TextButton(
                    onPressed: () => onDecide('decline'),
                    child: Text(context.t('console.protection.decline')),
                  ),
                  FilledButton(
                    onPressed: () => onDecide('accept'),
                    child: Text(context.t('console.protection.accept')),
                  ),
                ] else if (agreement.state == 'active')
                  TextButton(
                    onPressed: () => onDecide('suspend'),
                    child: Text(context.t('console.protection.suspend')),
                  )
                else if (agreement.state == 'suspended')
                  FilledButton(
                    onPressed: () => onDecide('resume'),
                    child: Text(context.t('console.protection.resume')),
                  ),
                if (agreement.state != 'ended' && !agreement.awaitingUs)
                  TextButton(
                    onPressed: () => onDecide('end'),
                    child: Text(context.t('console.protection.end')),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One live request, on whichever console is looking at it.
///
/// Deliberately not the same card as an agreement. An agreement is a term
/// somebody reads once a quarter; this is a decision with people waiting on
/// it, so it carries four facts and two buttons and nothing else: who is
/// asking, how many, on which coach of ours, and what we would be paid.
class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.canDecide,
    required this.onDecide,
  });

  final ProtectionRequestDto request;
  final bool canDecide;
  final void Function(String decision) onDecide;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

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
                    Text(request.counterpartyName, style: kilo.text.h3),
                    SizedBox(height: kilo.space.s1),
                    Text(
                      context.t(
                        request.weAsked
                            ? 'console.request.weAsked'
                            : 'console.request.theyAsked',
                        {
                          'count': request.seatsRequested,
                          'name': request.counterpartyName,
                        },
                      ),
                      style: kilo.text.body.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              KChip(
                context.t(
                  request.awaitingUs
                      ? 'console.request.awaitingUs'
                      : 'console.request.awaitingThem',
                ),
                tone: request.awaitingUs
                    ? KChipTone.warning
                    : KChipTone.neutral,
              ),
            ],
          ),
          SizedBox(height: kilo.space.s3),

          if (request.routeCode != null)
            _Term(
              label: context.t('console.request.coach'),
              value: [
                request.routeCode!,
                if (request.replacementDepartsAt case final at?) _time(at),
              ].join(' · '),
            ),
          // Their live seat count, on the card rather than a screen away.
          // §2.3: a receiving operator deciding blind is one who says no.
          _Term(
            label: context.t('console.request.seatsFree'),
            value: context.t('console.request.seatsValue', {
              'free': '${request.seatsFree}',
              'asked': '${request.seatsRequested}',
            }),
          ),
          if (request.rebill case final rebill?)
            _Term(
              label: context.t('console.request.rebill'),
              value: rebill.format(locale: context.language),
            ),
          if (request.note case final note?)
            _Term(label: context.t('console.request.note'), value: note),

          if (request.seatsFree < request.seatsRequested)
            Padding(
              padding: EdgeInsets.only(top: kilo.space.s2),
              child: Text(
                // Partial coverage is a success and is said as a number
                // before the decision, not discovered from the notice after.
                context.t('console.request.partial', {
                  'covered': '${request.seatsFree}',
                  'total': '${request.seatsRequested}',
                }),
                style: kilo.text.caption.copyWith(color: kilo.color.warning),
              ),
            ),

          if (canDecide && request.awaitingUs) ...[
            SizedBox(height: kilo.space.s3),
            Text(
              // The one thing about this button that is not obvious: it does
              // not schedule anything. The passengers change company, and
              // their tickets change with them, while the page is open.
              context.t('console.request.movesNow'),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            SizedBox(height: kilo.space.s2),
            Wrap(
              spacing: kilo.space.s2,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onDecide('decline'),
                  child: Text(context.t('console.request.decline')),
                ),
                FilledButton(
                  onPressed: request.seatsFree == 0
                      ? null
                      : () => onDecide('accept'),
                  child: Text(context.t('console.request.accept')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _time(DateTime instant) {
    final local = instant.toUtc().add(const Duration(hours: 1));
    return '${local.hour.toString().padLeft(2, '0')}h'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _Term extends StatelessWidget {
  const _Term({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ),
          Expanded(child: Text(value, style: kilo.text.body)),
        ],
      ),
    );
  }
}
