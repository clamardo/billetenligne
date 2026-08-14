import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';
import '../widgets/ticket_receipt.dart';

/// The guichet.
///
/// Two ways money arrives at a counter, and the screen puts the common one
/// first: somebody walks in with a code they got on their phone, and the
/// vendor types five characters. The walk-in sale is the second tab because
/// it is slower — a departure, a seat, a name and a number — and putting it
/// first would make the fast path feel like the exception.
///
/// **The code field folds what the vendor hears onto what was generated.** A
/// traveller says "oh", the vendor types O, and Crockford maps it to zero. A
/// sale lost to a font is a sale lost.
final class CounterScreen extends StatefulWidget {
  const CounterScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  @override
  State<CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends State<CounterScreen> {
  final _code = TextEditingController();
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _seat = TextEditingController();
  final _ref = TextEditingController();
  final _reason = TextEditingController();
  final _claim = TextEditingController();

  String? _departureId;
  _CounterMode _mode = _CounterMode.collect;

  /// The last quote read aloud. Cleared the moment the reference changes, so
  /// a vendor can never refund one booking against another's numbers.
  RefundOfferDto? _offer;

  /// The coaches last read aloud. Cleared with the reference for the same
  /// reason the refund quote is: one passenger's options must never be shown
  /// against another passenger's ticket.
  MissedOptionsDto? _missedOffer;

  ConsoleWorkspace get _work => widget.workspace;

  /// Which counter this till belongs to.
  ///
  /// A vendor is scoped to their station and the server refuses a sale into
  /// somebody else's drawer, so this is not a free choice — it is the first
  /// of theirs, and an owner with no station scope picks.
  String? get _stationId => _work.identity?.stationIds.firstOrNull;

  @override
  void dispose() {
    for (final c in [_code, _phone, _name, _seat, _ref, _reason, _claim]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    if (_stationId == null) {
      // An owner or dispatcher with every station and no default. Refusing
      // here beats guessing: the till is reconciled against the drawer that
      // took the money, and a sale in the wrong drawer is a variance nobody
      // can explain at close of shift.
      return KStateView(
        KEmpty(
          art: KArt.searchEmpty,
          title: context.t('console.counter.noStationTitle'),
          body: context.t('console.counter.noStationBody'),
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        Text(context.t('console.counter.title'), style: kilo.text.h2),
        SizedBox(height: kilo.space.s4),

        SegmentedButton<_CounterMode>(
          segments: [
            ButtonSegment(
              value: _CounterMode.collect,
              label: Text(context.t('console.counter.collect')),
              icon: const Icon(Icons.qr_code),
            ),
            ButtonSegment(
              value: _CounterMode.walkIn,
              label: Text(context.t('console.counter.walkIn')),
              icon: const Icon(Icons.person_add),
            ),
            // Third, because it is the rarest of the three and the two that
            // take money should stay where a vendor's hand already goes.
            // Absent entirely without the capability: a segment that appears
            // and then refuses is a worse answer than one that never
            // suggested itself.
            if (_work.can('booking.refund'))
              ButtonSegment(
                value: _CounterMode.refund,
                label: Text(context.t('console.counter.refund')),
                icon: const Icon(Icons.undo),
              ),
            // The passenger who was late. Its own mode rather than a corner
            // of the refund one: they are opposite conversations, and an
            // agent reaching for "rembourser" to put somebody on a later
            // coach is an agent one tap from cancelling their ticket.
            if (_work.can('booking.reschedule'))
              ButtonSegment(
                value: _CounterMode.missed,
                label: Text(context.t('console.counter.missed')),
                icon: const Icon(Icons.schedule),
              ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        SizedBox(height: kilo.space.s5),

        ...switch (_mode) {
          _CounterMode.collect => _collect(context),
          _CounterMode.walkIn => _sell(context),
          _CounterMode.refund => _refund(context),
          _CounterMode.missed => _missed(context),
        },
      ],
    );
  }

  // ── Collect against a reservation ─────────────────────────────────────────

  List<Widget> _collect(BuildContext context) {
    final kilo = context.kilo;
    return [
      Text(context.t('console.counter.collectIntro'), style: kilo.text.body),
      SizedBox(height: kilo.space.s3),
      KField(
        label: context.t('console.counter.paymentCode'),
        hint: 'K4M2Q',
        controller: _code,
        autofocus: true,
        maxLength: 5,
        enabled: !_work.busy,
        onChanged: (_) => setState(() {}),
      ),
      SizedBox(height: kilo.space.s4),
      KButton(
        label: context.t('console.counter.takeCash'),
        loading: _work.busy,
        onPressed: _code.text.trim().length < 5 ? null : _doCollect,
        disabledHint: context.t('console.counter.codeLength'),
      ),
    ];
  }

  Future<void> _doCollect() async {
    final sale = await _work.collect(
      paymentCode: _code.text.trim(),
      stationId: _stationId!,
    );
    if (sale == null || !mounted) return;
    _code.clear();
    await _showReceipt(sale);
  }

  // ── Sell to a walk-in ─────────────────────────────────────────────────────

  List<Widget> _sell(BuildContext context) {
    final kilo = context.kilo;
    final departures = _work.board.where((d) => d.available > 0).toList();

    return [
      Text(context.t('console.counter.walkInIntro'), style: kilo.text.body),
      SizedBox(height: kilo.space.s3),

      if (departures.isEmpty)
        KCard(
          child: Text(
            context.t('console.counter.noDepartures'),
            style: kilo.text.body,
          ),
        )
      else ...[
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _departureId,
          decoration: InputDecoration(
            labelText: context.t('console.counter.departure'),
          ),
          items: [
            for (final d in departures)
              DropdownMenuItem(
                value: d.id,
                child: Text('${d.routeCode} · ${d.available}'),
              ),
          ],
          onChanged: (v) => setState(() => _departureId = v),
        ),
        SizedBox(height: kilo.space.s3),
        KField(
          label: context.t('console.counter.seat'),
          controller: _seat,
          enabled: !_work.busy,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: kilo.space.s3),
        KField(
          label: context.t('console.counter.passengerName'),
          controller: _name,
          enabled: !_work.busy,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: kilo.space.s3),
        KField(
          label: context.t('console.counter.buyerPhone'),
          hint: '06 123 45 67',
          // The ticket goes here by SMS, and this number becomes their
          // account — unverified, because a vendor identifies a traveller and
          // does not authenticate one.
          helper: context.t('console.counter.phoneHelp'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          enabled: !_work.busy,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: kilo.space.s4),
        KButton(
          label: context.t('console.counter.sellAndTakeCash'),
          loading: _work.busy,
          onPressed: _canSell ? _doSell : null,
          disabledHint: context.t('console.counter.fillAll'),
        ),
      ],
    ];
  }

  bool get _canSell =>
      _departureId != null &&
      _seat.text.trim().isNotEmpty &&
      _name.text.trim().isNotEmpty &&
      _phone.text.trim().isNotEmpty;

  Future<void> _doSell() async {
    final sale = await _work.sell(
      departureId: _departureId!,
      buyerPhone: _phone.text.trim(),
      passengers: [
        PassengerDto(
          fullName: _name.text.trim(),
          phone: _phone.text.trim(),
          seatLabel: _seat.text.trim().toUpperCase(),
        ),
      ],
      stationId: _stationId!,
      // Minted per attempt, so a till whose network drops mid-sale returns
      // the same booking on the retry rather than a second one on a
      // different seat.
      idempotencyKey: IdempotencyKey.generate(),
    );

    if (sale == null || !mounted) return;
    _seat.clear();
    _name.clear();
    _phone.clear();
    await _showReceipt(sale);
  }

  // ── The passenger who was late ────────────────────────────────────────────

  /// Somebody standing at a counter with a ticket for a coach that has gone.
  ///
  /// The whole screen is one sentence the agent has to be able to say out
  /// loud: *votre car est parti, celui de 09h30 part de l'autre gare, ça vous
  /// coûte 2 700 francs*. So the yard is on every row and the price is on
  /// every row — an agent who has to tap a coach to learn what it costs is an
  /// agent making somebody wait while they compare.
  List<Widget> _missed(BuildContext context) {
    final kilo = context.kilo;
    final options = _missedOffer;

    return [
      Text(context.t('console.counter.missedIntro'), style: kilo.text.body),
      SizedBox(height: kilo.space.s3),

      KField(
        label: context.t('console.counter.bookingRef'),
        hint: 'BEL-K4M2QX',
        controller: _ref,
        enabled: !_work.busy,
        onChanged: (_) => setState(() => _missedOffer = null),
      ),
      SizedBox(height: kilo.space.s3),
      KButton(
        label: context.t('console.counter.missedLook'),
        tone: KButtonTone.secondary,
        loading: _work.busy,
        onPressed: _ref.text.trim().length < 6 ? null : _doMissedLook,
      ),

      if (options != null) ...[
        SizedBox(height: kilo.space.s4),

        // The company's own terms, in the company's own words, read aloud
        // before anybody is told a price.
        KCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final term in options.terms)
                Padding(
                  padding: EdgeInsets.only(bottom: kilo.space.s1),
                  child: Text(
                    context.tEncoded(term, prefix: ''),
                    style: kilo.text.bodySm,
                  ),
                ),
              if (options.involuntary)
                Text(
                  context.t('console.counter.missedInvoluntary'),
                  style: kilo.text.bodySm.copyWith(color: kilo.color.success),
                ),
            ],
          ),
        ),
        SizedBox(height: kilo.space.s3),

        if (!options.isPossible)
          KCard(
            child: Text(
              context.t('errors.${options.refusalCode}'),
              style: kilo.text.body.copyWith(color: kilo.color.danger),
            ),
          )
        else if (options.options.isEmpty)
          KCard(
            child: Text(
              context.t('console.counter.missedNoCoach'),
              style: kilo.text.body,
            ),
          )
        else
          for (final option in options.options)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: KCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_time(option.departsAt)} → '
                            '${_time(option.arrivesAt)}',
                            style: kilo.text.h3,
                          ),
                          if (option.stationName != null) ...[
                            SizedBox(height: kilo.space.s1),
                            Row(
                              children: [
                                Icon(
                                  Icons.place_outlined,
                                  size: 14,
                                  // The one row an agent must not misread.
                                  // A coach from the other yard is a taxi
                                  // ride somebody has to be told about.
                                  color: option.sameStation
                                      ? kilo.color.contentMuted
                                      : kilo.color.warning,
                                ),
                                SizedBox(width: kilo.space.s1),
                                Expanded(
                                  child: Text(
                                    option.sameStation
                                        ? option.stationName!
                                        : context.t(
                                            'console.counter.missedOtherGare',
                                            {'station': option.stationName!},
                                          ),
                                    style: kilo.text.bodySm.copyWith(
                                      color: option.sameStation
                                          ? kilo.color.contentSecondary
                                          : kilo.color.warning,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (option.refusalCode != null) ...[
                            SizedBox(height: kilo.space.s1),
                            Text(
                              context.t('errors.${option.refusalCode}'),
                              style: kilo.text.bodySm.copyWith(
                                color: kilo.color.contentSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(width: kilo.space.s3),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (option.owed != null)
                          Text(
                            option.isFree
                                ? context.t('console.counter.missedFree')
                                : option.owed!.format(),
                            style: kilo.text.amount,
                          ),
                        SizedBox(height: kilo.space.s2),
                        KButton(
                          label: context.t('console.counter.missedMove'),
                          fullWidth: false,
                          onPressed: option.isTakeable && !_work.busy
                              ? () => _doMissedMove(option)
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      ],
    ];
  }

  /// Congo is UTC+1 and does not observe daylight saving, so the offset is a
  /// constant rather than a lookup — the same simplification the dispatcher's
  /// day makes, and the same line that has to be revisited for a second
  /// market.
  static String _time(DateTime instant) {
    final local = instant.toUtc().add(const Duration(hours: 1));
    return '${local.hour.toString().padLeft(2, '0')}h'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _doMissedLook() async {
    final options = await _work.missedOptions(_ref.text.trim());
    if (!mounted) return;
    setState(() => _missedOffer = options);
  }

  Future<void> _doMissedMove(MissedOptionDto option) async {
    final moved = await _work.moveMissed(
      bookingRef: _ref.text.trim(),
      departureId: option.departureId,
      // Only when money changes hands. A station named on a free transfer is
      // a drawer nobody counted, and the server refuses it.
      stationId: option.isFree ? null : _stationId,
    );
    if (!mounted || moved == null) return;
    setState(() => _missedOffer = null);
  }

  // ── Refund a ticket, and pay a claim ──────────────────────────────────────

  List<Widget> _refund(BuildContext context) {
    final kilo = context.kilo;
    final offer = _offer;

    return [
      Text(context.t('console.counter.refundIntro'), style: kilo.text.body),
      SizedBox(height: kilo.space.s3),

      KField(
        label: context.t('console.counter.bookingRef'),
        hint: 'BEL-K4M2QX',
        controller: _ref,
        enabled: !_work.busy,
        onChanged: (_) => setState(() => _offer = null),
      ),
      SizedBox(height: kilo.space.s3),
      KButton(
        label: context.t('console.counter.quote'),
        tone: KButtonTone.secondary,
        loading: _work.busy,
        onPressed: _ref.text.trim().length < 6 ? null : _doQuote,
      ),

      if (offer != null) ...[
        SizedBox(height: kilo.space.s4),
        KCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (offer.isRefundable) ...[
                Text(
                  context.t('console.counter.refundable', {
                    'amount': offer.refundable!.format(),
                  }),
                  style: kilo.text.h3,
                ),
                Text(
                  context.t('console.counter.retained', {
                    'amount': offer.retained!.format(),
                  }),
                  style: kilo.text.caption.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
              ] else
                // The reason, never "0 FCFA". A zero reads as a bug to the
                // person being told it, and the vendor has to repeat
                // something true to a traveller standing in front of them.
                Text(
                  offer.failureCode == null
                      ? context.t('console.counter.notRefundable')
                      : context.t('errors.${offer.failureCode}'),
                  style: kilo.text.body.copyWith(color: kilo.color.danger),
                ),

              if (offer.policyName != null) ...[
                SizedBox(height: kilo.space.s2),
                Text(
                  context.t('console.counter.soldUnder', {
                    'name': offer.policyName!,
                  }),
                  style: kilo.text.caption.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
              ],
              // The same sentences the traveller read before paying, rendered
              // from the terms stamped on the booking rather than from
              // today's policy.
              for (final line in offer.policyLines)
                Padding(
                  padding: EdgeInsets.only(top: kilo.space.s1),
                  child: Text(
                    '· ${context.tEncoded(line)}',
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],

      if (offer != null && offer.isRefundable) ...[
        SizedBox(height: kilo.space.s3),
        KField(
          label: context.t('console.counter.reason'),
          helper: context.t('console.counter.reasonHelp'),
          controller: _reason,
          enabled: !_work.busy,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: kilo.space.s3),
        KButton(
          label: context.t('console.counter.doRefund'),
          tone: KButtonTone.danger,
          loading: _work.busy,
          onPressed: _reason.text.trim().length < 3 ? null : _doRefund,
          disabledHint: context.t('console.counter.needReason'),
        ),
      ],

      SizedBox(height: kilo.space.s6),

      // The other half of a cash refund: somebody walks back in with the code
      // and collects. Same screen, because it is the same person's job and
      // the same drawer.
      Text(context.t('console.counter.payClaim'), style: kilo.text.h3),
      SizedBox(height: kilo.space.s2),
      KField(
        label: context.t('console.counter.claimCode'),
        hint: 'K4M2QX',
        controller: _claim,
        maxLength: 6,
        enabled: !_work.busy,
        onChanged: (_) => setState(() {}),
      ),
      SizedBox(height: kilo.space.s3),
      KButton(
        label: context.t('console.counter.doPayClaim'),
        loading: _work.busy,
        onPressed: _claim.text.trim().length < 6 ? null : _doPayClaim,
      ),
    ];
  }

  Future<void> _doQuote() async {
    final offer = await _work.quoteRefund(_ref.text.trim());
    if (!mounted) return;
    setState(() => _offer = offer);
  }

  Future<void> _doRefund() async {
    final issued = await _work.refund(
      bookingRef: _ref.text.trim(),
      reason: _reason.text.trim(),
    );
    if (issued == null || !mounted) return;

    setState(() {
      _offer = null;
      _ref.clear();
      _reason.clear();
    });

    final code = issued.claimCode;
    if (code == null) return;

    // A dialog, and deliberately a blocking one: this code is the traveller's
    // only way to collect, it is shown once, and a vendor who dismisses the
    // screen without reading it out has left somebody with nothing.
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('console.counter.claimTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(code, style: dialogContext.kilo.text.codeHero),
            SizedBox(height: dialogContext.kilo.space.s3),
            KMoney(issued.amount.format(), size: KMoneySize.hero),
            if (issued.claimExpiresAt != null) ...[
              SizedBox(height: dialogContext.kilo.space.s2),
              Text(
                dialogContext.t('console.counter.claimExpires', {
                  'date': _day(issued.claimExpiresAt!),
                }),
                style: dialogContext.kilo.text.caption,
              ),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.t('common.actions.done')),
          ),
        ],
      ),
    );
  }

  Future<void> _doPayClaim() async {
    final claimed = await _work.payClaim(
      claimCode: _claim.text.trim(),
      stationId: _stationId!,
    );
    if (claimed == null || !mounted) return;
    setState(_claim.clear);
  }

  Future<void> _showReceipt(CounterSaleDto sale) => showDialog<void>(
    context: context,
    builder: (_) => TicketReceipt(sale: sale, workspace: _work),
  );
}

/// `15/08/2026`. The order every form in Congo uses.
String _day(DateTime at) {
  final local = at.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}

/// What the vendor is doing right now. Three acts, one drawer.
enum _CounterMode { collect, walkIn, refund, missed }
