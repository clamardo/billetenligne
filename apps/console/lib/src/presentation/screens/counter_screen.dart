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

  String? _departureId;
  var _walkIn = false;

  ConsoleWorkspace get _work => widget.workspace;

  /// Which counter this till belongs to.
  ///
  /// A vendor is scoped to their station and the server refuses a sale into
  /// somebody else's drawer, so this is not a free choice — it is the first
  /// of theirs, and an owner with no station scope picks.
  String? get _stationId => _work.identity?.stationIds.firstOrNull;

  @override
  void dispose() {
    for (final c in [_code, _phone, _name, _seat]) {
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

        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: false,
              label: Text(context.t('console.counter.collect')),
              icon: const Icon(Icons.qr_code),
            ),
            ButtonSegment(
              value: true,
              label: Text(context.t('console.counter.walkIn')),
              icon: const Icon(Icons.person_add),
            ),
          ],
          selected: {_walkIn},
          onSelectionChanged: (s) => setState(() => _walkIn = s.first),
        ),
        SizedBox(height: kilo.space.s5),

        if (!_walkIn) ..._collect(context) else ..._sell(context),
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

  Future<void> _showReceipt(CounterSaleDto sale) => showDialog<void>(
    context: context,
    builder: (_) => TicketReceipt(sale: sale),
  );
}
