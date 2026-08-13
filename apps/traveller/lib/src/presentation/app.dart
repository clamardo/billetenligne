import 'dart:async';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/booking_flow.dart';
import '../application/payment_flow.dart';
import '../application/sign_in_flow.dart';
import '../application/tickets_flow.dart';
import 'l10n.dart';
import 'screens/hold_screen.dart';
import 'screens/results_screen.dart';
import 'screens/search_screen.dart';
import 'screens/passengers_screen.dart';
import 'screens/payment_confirm_screen.dart';
import 'screens/payment_result_screen.dart';
import 'screens/payment_screen.dart';
import 'screens/payment_checkout_screen.dart';
import 'screens/payment_waiting_screen.dart';
import 'screens/reserved_screen.dart';
import 'screens/seat_alert_screen.dart';
import 'screens/seat_map_screen.dart';
import 'screens/ticket_screen.dart';
import 'screens/tickets_screen.dart';
import 'screens/cancel_screen.dart';
import 'screens/change_screen.dart';
import 'screens/share_trip_screen.dart';
import 'screens/travel_choice_screen.dart';
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
    required this.payment,
    required this.tickets,
    this.currentUserId,
    this.openUrl,
    this.openTicketsOnLaunch = false,
    this.language = 'fr',
    super.key,
  });

  final TranslationCatalog catalog;
  final BookingFlow flow;
  final SignInFlow signIn;
  final PaymentFlow payment;
  final TicketsFlow tickets;

  /// Who is signed in, asked each time rather than captured once — the answer
  /// changes while the app is running. Keys the offline ticket store: a
  /// handset here is shared, and a vault keyed on nothing would hand the next
  /// person to sign in somebody else's ticket.
  final String? Function()? currentUserId;

  /// Opens a page outside the app — today only the card rail's hosted
  /// checkout. Injected rather than called from a screen so the presentation
  /// layer keeps no opinion about browsers, and so a test can watch what was
  /// opened without a plugin channel to stub.
  final void Function(String url)? openUrl;

  /// The app was opened *by* a ticket link (ADR-0026), so it opens on the
  /// ticket list rather than on the search screen. Landing anywhere else and
  /// then jumping is the version of this that looks broken.
  final bool openTicketsOnLaunch;

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
      home: _Funnel(
        flow: flow,
        signIn: signIn,
        payment: payment,
        tickets: tickets,
        currentUserId: currentUserId,
        openUrl: openUrl,
        openTicketsOnLaunch: openTicketsOnLaunch,
      ),
    ),
  );
}

class _Funnel extends StatefulWidget {
  const _Funnel({
    required this.flow,
    required this.signIn,
    required this.payment,
    required this.tickets,
    this.currentUserId,
    this.openUrl,
    this.openTicketsOnLaunch = false,
  });

  final BookingFlow flow;
  final SignInFlow signIn;
  final PaymentFlow payment;
  final TicketsFlow tickets;
  final String? Function()? currentUserId;
  final void Function(String url)? openUrl;
  final bool openTicketsOnLaunch;

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
  StreamSubscription<PaymentStep>? _paymentSubscription;
  StreamSubscription<TicketsStep>? _ticketsSubscription;

  /// True while the tickets flow owns the screen. Layered over the funnel in
  /// the same way paying is: whatever the traveller was doing is still
  /// underneath, and closing the ticket returns them to it rather than to the
  /// top of the app.
  var _viewingTickets = false;

  /// True while the payment flow owns the screen. The booking flow's step is
  /// still `Reserved` underneath, which is what makes backing out of paying
  /// land exactly where it started rather than at the top of the funnel.
  var _paying = false;

  @override
  void initState() {
    super.initState();
    // The flow is pure Dart and knows nothing about widgets — the layer check
    // enforces that — so the subscription is the seam between them.
    _subscription = _flow.steps.listen((_) {
      if (mounted) setState(() {});
    });
    _paymentSubscription = widget.payment.steps.listen((_) {
      if (mounted) setState(() {});
    });
    _ticketsSubscription = widget.tickets.steps.listen((step) {
      if (!mounted) return;
      // A change that owes money hands straight over to the payment funnel:
      // same rails, same prompt, same poll. The seam is here rather than in
      // either flow, because neither of them knows about the other.
      if (step is ChangeAwaitingPayment && !_paying) {
        setState(() => _paying = true);
        widget.payment.start(step.order.bookingId, changeId: step.order.id);
        return;
      }
      setState(() {});
    });
    // The city list is the first thing the search screen needs and the app
    // holds no copy of it.
    _flow.start();

    // Opened by a ticket link: straight to the list, which claims the booking
    // on the way in if somebody is signed in to claim it for.
    if (widget.openTicketsOnLaunch) _openTickets();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _paymentSubscription?.cancel();
    _ticketsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _release() async {
    setState(() => _releasing = true);
    await _flow.releaseHold();
    if (mounted) setState(() => _releasing = false);
  }

  @override
  Widget build(BuildContext context) {
    // Tickets first: somebody who opened their ticket while a hold was
    // counting down is looking at the ticket, not at the countdown.
    if (_viewingTickets) return _ticketsScreen(context);
    if (_paying) return _paymentScreen(context);

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
        onOpenTickets: _openTickets,
      ),

      Searching() => Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: _flow.reset)),
        body: KStateView(KLoading(context.t('travel.results.searching'))),
      ),

      ResultsReady(
        :final departures,
        :final stale,
        :final hasMore,
        :final loadingMore,
        :final watching,
      ) =>
        ResultsScreen(
          query: _flow.lastQuery!,
          departures: departures,
          stale: stale,
          hasMore: hasMore,
          loadingMore: loadingMore,
          watching: watching,
          cityNames: {for (final c in _flow.cities) c.code: c.name},
          onSelect: _flow.openSeatMap,
          // A full coach is not a dead end. It is the one row on this screen
          // where the only useful thing left to offer is "tell me if it
          // changes".
          onWatch: _flow.offerAlert,
          onBack: _flow.reset,
          onLoadMore: () => unawaited(_flow.searchMore()),
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

      // The sold-out detour. Reached only from a full coach, and it is the
      // one screen in the funnel that sells nothing.
      AskingForAlert(
        :final departure,
        :final seats,
        :final saving,
        :final alert,
        :final failure,
      ) =>
        SeatAlertScreen(
          departure: departure,
          seats: seats,
          watching: alert != null,
          saving: saving,
          maxSeats: _flow.maxSeats,
          failure: failure,
          onSeats: _flow.setAlertSeats,
          onConfirm: () => unawaited(_flow.confirmAlert()),
          onCancel: () => unawaited(_flow.cancelAlert()),
          onBack: _backToResults,
        ),

      // The second reason this product asks who somebody is: an alert is a
      // promise to send a message, and an anonymous one has no recipient.
      AlertNeedsIdentity() => SignInScreen(
        flow: widget.signIn,
        onSignedIn: (_) {
          widget.signIn.reset();
          unawaited(_flow.resumeAlertAfterIdentity());
        },
        onCancel: () {
          widget.signIn.reset();
          _flow.abandonAlert();
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
        // Cash at an agency. Mobile money is Phase 2 and this button does not
        // pretend otherwise — it collects names and issues a code to pay
        // with, which is the whole of the pilot's payment story.
        onPay: _flow.namePassengers,
      ),

      NamingPassengers(:final departure, :final hold, :final failure) =>
        PassengersScreen(
          departure: departure,
          hold: hold,
          failure: failure,
          onReserve: _flow.reserve,
          onBack: _backToResults,
        ),

      Reserving(:final departure, :final hold) => PassengersScreen(
        departure: departure,
        hold: hold,
        busy: true,
        onReserve: (_) {},
        onBack: () {},
      ),

      Reserved(:final booking) => ReservedScreen(
        booking: booking,
        onDone: _flow.reset,
        // Mobile money. Cash at an agency stays on the same screen — a
        // traveller who cannot pay by phone still has a code to walk in with,
        // and offering both is the whole point of the market this serves.
        onPayNow: () {
          setState(() => _paying = true);
          widget.payment.start(booking.id);
        },
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

  /// The payment flow's screens, layered over the funnel.
  Widget _paymentScreen(BuildContext context) {
    final step = widget.payment.step;

    return switch (step) {
      LoadingOptions() => Scaffold(
        body: KStateView(KLoading(context.t('payment.method.loading'))),
      ),

      ChoosingMethod() => PaymentMethodScreen(
        step: step,
        flow: widget.payment,
        onBack: _stopPaying,
      ),

      ConfirmingPayment() => PaymentConfirmScreen(
        step: step,
        flow: widget.payment,
        // Back to the method screen, not out of paying: changing a number is
        // the commonest reason anybody leaves the confirmation.
        onBack: () => widget.payment.tryAgain(),
      ),

      AwaitingPin() => PaymentWaitingScreen(step: step, onCancel: _stopPaying),

      AwaitingCheckout() => PaymentCheckoutScreen(
        step: step,
        onOpen: widget.openUrl,
        onCancel: _stopPaying,
      ),

      PaymentSucceeded() => PaymentReceiptScreen(
        step: step,
        // "See my ticket" now shows the ticket. It used to return to the
        // search screen, which is the one thing somebody who has just paid is
        // not looking for.
        onDone: () {
          // A paid difference lands back on the change receipt — new
          // departure, new seats, new ticket — rather than on the ticket for
          // a journey they have just moved off.
          if (widget.tickets.step case final ChangeAwaitingPayment pending) {
            setState(() {
              _paying = false;
              _viewingTickets = true;
            });
            widget.tickets.changePaid(pending.order);
            return;
          }
          setState(() {
            _paying = false;
            _viewingTickets = true;
          });
          _flow.reset();
          widget.tickets.loadAndOpen(step.booking.id);
        },
      ),

      PaymentRefused() => PaymentRefusedScreen(
        step: step,
        onRetry: widget.payment.tryAgain,
        onBack: _stopPaying,
      ),

      PaymentUnresolved() => PaymentUnresolvedScreen(
        step: step,
        onDone: () {
          setState(() => _paying = false);
          _flow.reset();
        },
      ),
    };
  }

  /// The tickets flow's screens, layered over the funnel.
  Widget _ticketsScreen(BuildContext context) {
    final step = widget.tickets.step;

    return switch (step) {
      TicketsLoading() => Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: _closeTickets)),
        body: KStateView(KLoading(context.t('travel.tickets.loading'))),
      ),

      TicketsReady(:final upcoming, :final past, :final stale) => TicketsScreen(
        upcoming: upcoming,
        past: past,
        stale: stale,
        onOpen: widget.tickets.open,
        onChoices: widget.tickets.openChoices,
        onCancel: widget.tickets.openCancellation,
        onChange: widget.tickets.openChange,
        onRefresh: widget.tickets.refresh,
        onBack: _closeTickets,
        onSearch: _closeTickets,
        onBookAgain: _bookAgain,
        cityNames: {for (final c in _flow.cities) c.code: c.name},
      ),

      ViewingTicket(:final booking, :final seatIndex) => switch (step.ticket) {
        // A booking with no ticket cannot reach this step — the flow refuses
        // to open one — so this arm is the type system's, not a state.
        null => const SizedBox.shrink(),
        final ticket => TicketScreen(
          booking: booking,
          ticket: ticket,
          seatIndex: seatIndex,
          onSeat: widget.tickets.showSeat,
          onClose: widget.tickets.closeTicket,
          onShare: () => widget.tickets.openSharing(booking),
          // Only where there is something to choose. A delay declared as the
          // operator's fault opens the entitlement; anything else is a
          // notice, and a button leading to one option is a dead end.
          onChoices: booking.disruption?.marksInvoluntary == true
              ? () => widget.tickets.openChoices(booking)
              : null,
        ),
      },

      ChoosingTravel(:final choices, :final busy, :final failure) =>
        TravelChoiceScreen(
          choices: choices,
          busy: busy,
          failure: failure,
          onChoose: widget.tickets.choose,
          onClose: widget.tickets.closeChoices,
        ),

      TravelChosen(:final applied) => TravelChosenScreen(
        applied: applied,
        onDone: widget.tickets.closeChoices,
      ),

      SharingTrip(:final booking, :final share, :final busy) => ShareTripScreen(
        booking: booking,
        share: share,
        busy: busy,
        onShare: widget.tickets.shareTrip,
        onRevoke: widget.tickets.revokeShare,
        onClose: widget.tickets.closeChoices,
      ),

      Cancelling(:final booking, :final offer, :final busy, :final failure) =>
        CancelScreen(
          booking: booking,
          offer: offer,
          busy: busy,
          failure: failure,
          onConfirm: widget.tickets.confirmCancellation,
          onClose: widget.tickets.closeChoices,
        ),

      Cancelled(:final booking, :final done) => CancelledScreen(
        booking: booking,
        done: done,
        onClose: widget.tickets.closeChoices,
      ),

      ChangingDeparture(
        :final booking,
        :final options,
        :final busy,
        :final failure,
      ) =>
        ChangeScreen(
          booking: booking,
          options: options,
          busy: busy,
          failure: failure,
          onTake: widget.tickets.changeDeparture,
          onPay: widget.tickets.orderChange,
          onCancelPending: widget.tickets.cancelPendingChange,
          onClose: widget.tickets.closeChoices,
        ),

      // Held, quoted, and waiting on a handset. The payment flow owns the
      // screen from the moment this step arrives, so what is drawn here is
      // only ever seen if somebody backs out of paying.
      ChangeAwaitingPayment() => Scaffold(
        body: KStateView(KLoading(context.t('payment.method.loading'))),
      ),

      DepartureChanged(:final applied) => DepartureChangedScreen(
        applied: applied,
        onClose: widget.tickets.closeChoices,
      ),

      TicketsFailed(:final failure) => Scaffold(
        appBar: AppBar(leading: BackButton(onPressed: _closeTickets)),
        body: FailureView(failure, onRetry: widget.tickets.load),
      ),
    };
  }

  void _openTickets() {
    setState(() => _viewingTickets = true);
    // What is on the handset first, then what the server says. The stored
    // list is drawn before the request goes out rather than after it fails:
    // on a dead connection the difference between the two is a spinner for
    // however long a timeout takes, at the moment somebody is being asked to
    // show their ticket.
    unawaited(widget.tickets.loadCachedThen(widget.currentUserId?.call()));
  }

  void _closeTickets() => setState(() => _viewingTickets = false);

  /// The same road again, from a trip already taken.
  ///
  /// Straight to the results rather than to a pre-filled search form: the
  /// whole point is that it is one tap, and the form is what backing out
  /// lands on — already carrying the route and the party, so changing the
  /// date is the one thing left to do.
  void _bookAgain(BookingDto booking, {bool reversed = false}) {
    setState(() => _viewingTickets = false);
    unawaited(_flow.searchAgain(booking, reversed: reversed));
  }

  /// Leaves paying without losing the reservation. The payment code and its
  /// deadline are still on the screen underneath.
  void _stopPaying() {
    setState(() => _paying = false);
    // Backing out of paying for a change goes back to the priced list, not to
    // a step waiting on money that is no longer coming. The order is left to
    // lapse on its own: those seats are theirs for the length of the window,
    // and people come straight back.
    if (widget.tickets.step is ChangeAwaitingPayment) {
      unawaited(widget.tickets.abandonChange());
    }
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
