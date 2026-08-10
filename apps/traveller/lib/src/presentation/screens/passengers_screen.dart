import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// Who is travelling.
///
/// Asked here and not at seat selection. A form between somebody and a seat
/// map is a form most of them abandon; by this point they have a seat held
/// and a countdown running, which is the moment they are most willing to
/// type.
///
/// The name is the only required field, because it is the only one a
/// conductor uses: they read it aloud against a face. A phone number is
/// optional and per passenger, which is what makes "buy a ticket for my
/// mother" a first-class flow — her ticket goes to her handset, not to the
/// purchaser's (ADR-0013).
final class PassengersScreen extends StatefulWidget {
  const PassengersScreen({
    required this.departure,
    required this.hold,
    required this.onReserve,
    required this.onBack,
    this.failure,
    this.busy = false,
    super.key,
  });

  final DepartureSummaryDto departure;
  final HoldDto hold;
  final ValueChanged<List<PassengerDto>> onReserve;
  final VoidCallback onBack;
  final ApiFailure? failure;
  final bool busy;

  @override
  State<PassengersScreen> createState() => _PassengersScreenState();
}

class _PassengersScreenState extends State<PassengersScreen> {
  late final Map<String, TextEditingController> _names;
  late final Map<String, TextEditingController> _phones;

  @override
  void initState() {
    super.initState();
    _names = {
      for (final seat in widget.hold.seatLabels) seat: TextEditingController(),
    };
    _phones = {
      for (final seat in widget.hold.seatLabels) seat: TextEditingController(),
    };
  }

  @override
  void dispose() {
    for (final c in [..._names.values, ..._phones.values]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete => _names.values.every((c) => c.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onBack),
        title: Text(context.t('travel.passengers.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Text(context.t('travel.passengers.intro'), style: kilo.text.body),
            SizedBox(height: kilo.space.s4),

            for (final seat in widget.hold.seatLabels) ...[
              Text(
                context.t('travel.passengers.forSeat', {'seat': seat}),
                style: kilo.text.label,
              ),
              SizedBox(height: kilo.space.s2),
              KField(
                label: context.t('common.labels.name'),
                controller: _names[seat],
                autofocus: seat == widget.hold.seatLabels.first,
                enabled: !widget.busy,
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: kilo.space.s3),
              KField(
                label: context.t('travel.passengers.phoneOptional'),
                hint: context.t('auth.phone.hint'),
                controller: _phones[seat],
                keyboardType: TextInputType.phone,
                enabled: !widget.busy,
                // Per passenger, not per booking. The ticket goes to the
                // person travelling, who may not be the person paying.
                helper: context.t('travel.passengers.phoneHelp'),
              ),
              SizedBox(height: kilo.space.s5),
            ],

            if (widget.failure != null) ...[
              Text(
                context.t(
                  widget.failure!.messageKey,
                  widget.failure is ServerRefused
                      ? (widget.failure! as ServerRefused).params
                      : const {},
                ),
                style: kilo.text.body.copyWith(color: kilo.color.danger),
              ),
              SizedBox(height: kilo.space.s4),
            ],

            KButton(
              label: context.t('travel.passengers.submit', {
                'total': Format.money(widget.departure.total, locale: locale),
              }),
              loading: widget.busy,
              onPressed: _complete ? _submit : null,
              // A greyed control with no explanation is the most common way an
              // app strands somebody.
              disabledHint: context.t('travel.passengers.nameRequired'),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() => widget.onReserve([
    for (final seat in widget.hold.seatLabels)
      PassengerDto(
        fullName: _names[seat]!.text.trim(),
        phone: _phones[seat]!.text.trim().isEmpty
            ? null
            : _phones[seat]!.text.trim(),
        seatLabel: seat,
      ),
  ]);
}
