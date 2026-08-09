import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/boarding_session.dart';

/// Boarding by name or reference, against the pinned offline manifest.
///
/// For a dead battery, a cracked digitiser, a passenger who never had the app.
/// **Never leave a paying passenger at the roadside because of our
/// technology** — that is the rule this screen exists to keep.
///
/// Every boarding here is flagged manual, so an operator can see how often it
/// happens. A spike usually means a real problem somewhere upstream.
class ManualBoardingPage extends StatefulWidget {
  const ManualBoardingPage({required this.session, super.key});

  final BoardingSession session;

  @override
  State<ManualBoardingPage> createState() => _ManualBoardingPageState();
}

class _ManualBoardingPageState extends State<ManualBoardingPage> {
  final _controller = TextEditingController();
  List<ManifestEntry> _results = const [];

  @override
  void initState() {
    super.initState();
    // Opening on the no-show list is the common case: the conductor is looking
    // for someone specific and already knows who is missing.
    _results = widget.session.noShows;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String query) {
    setState(() {
      _results = query.trim().isEmpty
          ? widget.session.noShows
          : widget.session.search(query);
    });
  }

  void _board(ManifestEntry entry) {
    final outcome = widget.session.boardManually(
      bookingRef: entry.bookingRef,
      seatLabel: entry.seatLabel,
    );
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      backgroundColor: kilo.color.surfaceBase,
      appBar: AppBar(
        title: const Text('Embarquement manuel'),
        backgroundColor: kilo.color.surfaceRaised,
        foregroundColor: kilo.color.contentPrimary,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(kilo.space.s4),
              child: TextField(
                controller: _controller,
                onChanged: _search,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                style: kilo.text.bodyLg,
                decoration: InputDecoration(
                  labelText: 'Nom, référence ou siège',
                  hintText: '7QK4M2  ·  Aline  ·  14A',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: kilo.radius.controlBorder,
                  ),
                ),
              ),
            ),
            if (_controller.text.trim().isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: kilo.space.s4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'PAS ENCORE EMBARQUÉS — ${_results.length}',
                    style: kilo.text.label.copyWith(
                      color: kilo.color.contentMuted,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _results.isEmpty
                  ? _EmptyState(hasQuery: _controller.text.trim().isNotEmpty)
                  : ListView.separated(
                      padding: EdgeInsets.all(kilo.space.s4),
                      itemCount: _results.length,
                      separatorBuilder: (_, __) =>
                          SizedBox(height: kilo.space.s2),
                      itemBuilder: (_, i) => _PassengerRow(
                        entry: _results[i],
                        onBoard: () => _board(_results[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PassengerRow extends StatelessWidget {
  const _PassengerRow({required this.entry, required this.onBoard});

  final ManifestEntry entry;
  final VoidCallback onBoard;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Material(
      color: kilo.color.surfaceRaised,
      borderRadius: kilo.radius.cardBorder,
      child: InkWell(
        onTap: onBoard,
        borderRadius: kilo.radius.cardBorder,
        child: Container(
          padding: EdgeInsets.all(kilo.space.s3),
          decoration: BoxDecoration(
            border: Border.all(color: kilo.color.borderSubtle),
            borderRadius: kilo.radius.cardBorder,
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kilo.color.brandPrimarySoft,
                  borderRadius: kilo.radius.controlBorder,
                ),
                child: Text(
                  entry.seatLabel,
                  style: kilo.text.amount.copyWith(
                    color: kilo.color.brandPrimary,
                  ),
                ),
              ),
              SizedBox(width: kilo.space.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.passengerName, style: kilo.text.h3),
                    Text(
                      entry.bookingRef,
                      style: kilo.text.code.copyWith(
                        color: kilo.color.contentMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: kilo.color.contentMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Center(
      child: Padding(
        padding: EdgeInsets.all(kilo.space.s6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              hasQuery ? Icons.search_off : Icons.done_all,
              size: 48,
              color: kilo.color.contentMuted,
            ),
            SizedBox(height: kilo.space.s3),
            Text(
              hasQuery
                  ? 'Aucun passager ne correspond'
                  : 'Tout le monde est embarqué',
              textAlign: TextAlign.center,
              style: kilo.text.bodyLg.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
            if (hasQuery) ...[
              SizedBox(height: kilo.space.s2),
              Text(
                'Vérifiez la référence, ou synchronisez\nla liste si le billet vient d\'être acheté.',
                textAlign: TextAlign.center,
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
