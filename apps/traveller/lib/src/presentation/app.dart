import 'dart:async';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/booking_flow.dart';
import '../application/sign_in_flow.dart';
import 'l10n.dart';
import 'screens/hold_screen.dart';
import 'screens/results_screen.dart';
import 'screens/search_screen.dart';
import 'screens/seat_map_screen.dart';
import 'screens/sign_in_screen.dart';
import 'widgets/failure_view.dart';

/// The traveller app.
///
/// Navigation is driven by [BookingFlow]'s step rather than by a router,
/// because this app has one linear funnel and the step *is* the screen. A
/// route table would let the app be in a state the flow does not model — a
/// seat map with no departure, a hold screen with no hold — and every one of
/// those is a crash somebody hits on a bad connection.
final class TravellerApp extends StatelessWidget {
  const TravellerApp({
    required this.catalog,
    required this.flow,
    required this.signIn,
    this.language = 'fr',
    super.key,
  });

  final TranslationCatalog catalog;
  final BookingFlow flow;
  final SignInFlow signIn;
  final String language;

  @override
  Widget build(BuildContext context) => Localized(
    catalog: catalog,
    initialLanguage: language,
    child: MaterialApp(
      title: 'BilletEnLigne',
      debugShowCheckedModeBanner: false,
      theme: KiloTheme.materialTheme(),
      darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
      home: _Funnel(flow: flow, signIn: signIn),
    ),
  );
}

class _Funnel extends StatefulWidget {
  const _Funnel({required this.flow, required this.signIn});

  final BookingFlow flow;
  final SignInFlow signIn;

  @override
  State<_Funnel> createState() => _FunnelState();
}

class _FunnelState extends State<_Funnel> {
  BookingFlow get _flow => widget.flow;

  /// Set when a tap was refused by the seat cap, cleared on the next
  /// successful toggle. Lives here rather than in the flow: it is a fact about
  /// this screen's last interaction, not about the booking.
  var _capReached = false;
  var _releasing = false;

  StreamSubscription<BookingStep>? _subscription;

  @override
  void initState() {
    super.initState();
    // The flow is pure Dart and knows nothing about widgets — the layer check
    // enforces that — so the subscription is the seam between them.
    _subscription = _flow.steps.listen((_) {
      if (mounted) setState(() {});
    });
    // The city list is the first thing the search screen needs and the app
    // holds no copy of it.
    _flow.start();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _release() async {
    setState(() => _releasing = true);
    await _flow.releaseHold();
    if (mounted) setState(() => _releasing = false);
  }

  @override
  Widget build(BuildContext context) {
    final step = _flow.step;

    return switch (step) {
      Starting() => Scaffold(
        body: KStateView(KLoading(context.t('common.state.loading'))),
      ),

      Idle() => SearchScreen(
        cities: [
          for (final city in _flow.cities) CityOption(city.code, city.name),
        ],
        initialQuery: _flow.lastQuery,
        onSearch: _flow.search,
      ),

      Searching() => Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: _flow.reset)),
        body: KStateView(KLoading(context.t('travel.results.searching'))),
      ),

      ResultsReady(:final departures, :final stale) => ResultsScreen(
        query: _flow.lastQuery!,
        departures: departures,
        stale: stale,
        onSelect: _flow.openSeatMap,
        onBack: _flow.reset,
        onRefresh: () => _flow.search(_flow.lastQuery!),
        onTryTomorrow: () {
          final was = _flow.lastQuery!;
          _flow.search(
            SearchDeparturesQuery(
              originCity: was.originCity,
              destinationCity: was.destinationCity,
              date: was.date.add(const Duration(days: 1)),
              passengers: was.passengers,
            ),
          );
        },
      ),

      LoadingSeatMap() => Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: _backToResults)),
        body: KStateView(KLoading(context.t('travel.seatmap.loading'))),
      ),

      ChoosingSeats(:final departure, :final seatMap, :final selected) =>
        SeatMapScreen(
          departure: departure,
          seatMap: seatMap,
          selected: selected,
          capReached: _capReached,
          maxSeats: _flow.maxSeats,
          onToggle: (label) {
            final accepted = _flow.toggleSeat(label);
            setState(() => _capReached = !accepted);
          },
          onContinue: _flow.holdSelection,
          onBack: _backToResults,
        ),

      // The one moment sign-in is asked for (ADR-0013). The seats stay
      // selected behind it: finishing signs in and resumes the hold, backing
      // out returns to exactly the seat map they left.
      NeedsIdentity() => SignInScreen(
        flow: widget.signIn,
        onSignedIn: (_) {
          widget.signIn.reset();
          _flow.resumeAfterIdentity();
        },
        onCancel: () {
          widget.signIn.reset();
          _flow.abandonIdentity();
        },
      ),

      Holding(:final departure, :final seatMap, :final selected) =>
        SeatMapScreen(
          departure: departure,
          seatMap: seatMap,
          selected: selected,
          maxSeats: _flow.maxSeats,
          holding: true,
          onToggle: (_) {},
          onContinue: () {},
          onBack: _backToResults,
        ),

      HoldReady(:final departure, :final hold) => HoldScreen(
        departure: departure,
        hold: hold,
        releasing: _releasing,
        onRelease: _release,
        onExpired: _flow.holdExpired,
        // Payment lands in Phase 2. Disabled and honest about why, rather than
        // a button that opens a screen apologising.
        onPay: null,
      ),

      StepFailed(:final failure, :final recoverable) => Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: _flow.reset)),
        body: FailureView(
          failure,
          onRetry: recoverable ? _retry : null,
          // When retrying cannot help — the seat is genuinely gone — the way
          // forward is a different seat, and that is the button offered.
          alternativeLabel: context.t('common.actions.seeOptions'),
          onAlternative: _flow.backToSeatMap,
        ),
      ),
    };
  }

  void _backToResults() {
    final query = _flow.lastQuery;
    if (query == null) {
      _flow.reset();
    } else {
      _flow.search(query);
    }
  }

  void _retry() {
    final query = _flow.lastQuery;
    // No query yet means the city list is what failed, and retrying that is
    // the only thing that can help.
    if (query == null) {
      _flow.start();
    } else {
      _flow.search(query);
    }
  }
}
