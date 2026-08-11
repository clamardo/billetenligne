import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/travel_gateway.dart';

/// What the tickets screen should render.
sealed class TicketsStep {
  const TicketsStep();
}

final class TicketsLoading extends TicketsStep {
  const TicketsLoading();
}

/// The traveller's own bookings, split by whether the coach has left.
///
/// Split here rather than in the widget because "is this trip still ahead of
/// me?" is a rule, not a layout decision — and it is the rule that decides
/// which ticket somebody sees first at six in the morning at a station.
final class TicketsReady extends TicketsStep {
  const TicketsReady({
    required this.upcoming,
    required this.past,
    this.stale = false,
  });

  final List<BookingDto> upcoming;
  final List<BookingDto> past;

  /// True when these came from the last successful load rather than from this
  /// request. Rendered with a banner: a stale ticket list is useful, a
  /// silently stale one is a lie.
  final bool stale;

  bool get isEmpty => upcoming.isEmpty && past.isEmpty;
}

/// One booking, full screen, with its QR.
final class ViewingTicket extends TicketsStep {
  const ViewingTicket({required this.booking, required this.seatIndex});

  final BookingDto booking;

  /// Which passenger's ticket is showing. A family of four is one booking and
  /// four tickets, and the conductor scans each of them in turn.
  final int seatIndex;

  List<TicketDto> get tickets => booking.tickets;

  TicketDto? get ticket =>
      seatIndex < tickets.length ? tickets[seatIndex] : null;
}

/// The choice screen for one disrupted booking (`08-disruption.md` §3.2).
final class ChoosingTravel extends TicketsStep {
  const ChoosingTravel({
    required this.booking,
    required this.choices,
    this.busy = false,
    this.failure,
  });

  final BookingDto booking;
  final TravelChoicesDto choices;

  /// The last refusal, rendered above the options rather than instead of
  /// them. Nearly every refusal here is the world having changed — the coach
  /// filled, the party no longer fits — and the passenger's next move is to
  /// look at what is left, not to read an apology on an empty screen.
  final ApiFailure? failure;

  /// True while a choice is being taken. The screen stays on the options and
  /// disables them rather than blanking: a passenger who taps twice on a bad
  /// connection must not be looking at a spinner wondering which tap counted.
  final bool busy;
}

/// What happened after they tapped. A screen of its own rather than a banner,
/// because a refund carries a code somebody has to write down.
final class TravelChosen extends TicketsStep {
  const TravelChosen({required this.booking, required this.applied});

  final BookingDto booking;
  final ChoiceAppliedDto applied;
}

/// The share sheet for one booking (ADR-0014 §2).
final class SharingTrip extends TicketsStep {
  const SharingTrip({
    required this.booking,
    required this.share,
    this.busy = false,
  });

  final BookingDto booking;

  /// Null before anything has been shared. The sheet then offers to mint one
  /// rather than showing an empty link field.
  final TripShareDto? share;

  final bool busy;
}

/// The cancellation sheet for one booking (`01-feature-spec.md` §8.2).
final class Cancelling extends TicketsStep {
  const Cancelling({
    required this.booking,
    required this.offer,
    this.busy = false,
    this.failure,
  });

  final BookingDto booking;

  /// What cancelling will do, computed by the server. Null only while the
  /// first read is in flight.
  final CancellationOfferDto? offer;

  /// True while the cancellation is being taken. The sheet stays on screen
  /// and disables the button rather than blanking: somebody who taps twice on
  /// a bad connection must not be looking at a spinner wondering whether they
  /// have cancelled their journey once or twice.
  final bool busy;

  /// The last refusal, rendered above the button rather than instead of it.
  /// A booking somebody was refused a cancellation on is still a booking they
  /// are looking at.
  final ApiFailure? failure;
}

/// The receipt. A screen of its own, because a claim code is something
/// somebody has to write down.
final class Cancelled extends TicketsStep {
  const Cancelled({required this.booking, required this.done});

  final BookingDto booking;
  final CancellationDoneDto done;
}

final class TicketsFailed extends TicketsStep {
  const TicketsFailed(this.failure);
  final ApiFailure failure;
}

/// The traveller's tickets and history.
///
/// Plain Dart with a broadcast stream, like [BookingFlow] — the layer check
/// refuses Flutter in the application layer, and the reasons are the same
/// ones: this is testable in milliseconds and reusable by any surface.
///
/// **A booking that has been paid for carries its ticket inside it.** There
/// is no per-ticket fetch and no lazy load, because the moment this screen
/// matters most is at a coach door with one bar of signal, and anything
/// deferred is a thing that fails exactly there.
final class TicketsFlow {
  TicketsFlow({
    required TravelGateway gateway,
    Clock clock = const SystemClock(),
  }) : _gateway = gateway,
       _clock = clock;

  final TravelGateway _gateway;
  final Clock _clock;

  final _steps = StreamController<TicketsStep>.broadcast();

  TicketsStep _step = const TicketsLoading();
  TicketsStep get step => _step;
  Stream<TicketsStep> get steps => _steps.stream;

  /// The last list that actually loaded. Kept so a failed refresh can show
  /// yesterday's ticket rather than an apology.
  List<BookingDto> _cached = const [];

  bool get hasCache => _cached.isNotEmpty;

  void _emit(TicketsStep next) {
    _step = next;
    if (!_steps.isClosed) _steps.add(next);
  }

  Future<void> load() async {
    _emit(const TicketsLoading());
    await _fetch();
  }

  /// A pull-to-refresh, which must never blank a ticket somebody is looking
  /// at. The list stays on screen while this runs.
  Future<void> refresh() => _fetch();

  /// [silent] reloads the list without moving the passenger off whatever
  /// they are looking at — used after a choice is taken, so the list behind
  /// the receipt is already right when they go back to it.
  Future<void> _fetch({bool silent = false}) async {
    try {
      _cached = await _gateway.bookings();
      if (!silent) _emit(_ready());
    } on ApiFailure catch (failure) {
      // A ticket already loaded is worth more than the error that stopped us
      // reloading it: the traveller is standing at the door either way.
      if (silent) return;
      if (_cached.isNotEmpty) {
        _emit(_ready(stale: true));
      } else {
        _emit(TicketsFailed(failure));
      }
    }
  }

  TicketsReady _ready({bool stale = false}) {
    final now = _clock.now();
    final upcoming = <BookingDto>[];
    final past = <BookingDto>[];

    for (final booking in _cached) {
      // The departure decides, not the state: a cancelled trip tomorrow is
      // still the thing somebody needs to see and act on today, and a
      // confirmed one from last month is history.
      (booking.departsAt.isAfter(now) ? upcoming : past).add(booking);
    }

    // Soonest first among what is ahead — that is the one being boarded — and
    // most recent first among what is behind.
    upcoming.sort((a, b) => a.departsAt.compareTo(b.departsAt));
    past.sort((a, b) => b.departsAt.compareTo(a.departsAt));

    return TicketsReady(upcoming: upcoming, past: past, stale: stale);
  }

  /// Opens a booking's ticket. Refused for an unpaid one, which has no ticket
  /// to open — the payment code screen is where that booking lives.
  void open(BookingDto booking, {int seatIndex = 0}) {
    if (booking.tickets.isEmpty) return;
    _emit(ViewingTicket(booking: booking, seatIndex: seatIndex));
  }

  /// Loads the list and goes straight to one booking's ticket — the path from
  /// a payment receipt to the QR, which is the whole reason somebody paid.
  Future<void> loadAndOpen(String bookingId) async {
    await load();
    for (final booking in _cached) {
      if (booking.id == bookingId) {
        open(booking);
        return;
      }
    }
  }

  /// The next passenger on the same booking. Wraps, because four seats and a
  /// dead end at the fourth is a conductor waiting while somebody taps back.
  void showSeat(int index) {
    final current = _step;
    if (current is! ViewingTicket) return;
    final count = current.booking.tickets.length;
    if (count == 0) return;
    _emit(
      ViewingTicket(
        booking: current.booking,
        seatIndex: (index % count + count) % count,
      ),
    );
  }

  /// Opens the choice screen for a disrupted booking.
  ///
  /// Fetched at the moment of opening and never held: the seat counts on the
  /// alternatives are the entire point of the screen, and a cached one offers
  /// a coach that filled ten minutes ago.
  Future<void> openChoices(BookingDto booking) async {
    try {
      final choices = await _gateway.travelOptions(booking.ref);
      _emit(ChoosingTravel(booking: booking, choices: choices));
    } on ApiFailure catch (failure) {
      _emit(TicketsFailed(failure));
    }
  }

  /// Takes one. The movement happens server-side inside this call, so what
  /// comes back is what is now true rather than what was asked for.
  Future<void> choose(String optionId) async {
    final current = _step;
    if (current is! ChoosingTravel || current.busy) return;

    _emit(
      ChoosingTravel(
        booking: current.booking,
        choices: current.choices,
        busy: true,
      ),
    );

    try {
      final applied = await _gateway.chooseTravel(
        bookingRef: current.booking.ref,
        optionId: optionId,
      );
      // The list behind is now wrong — a moved booking is on another coach
      // and a refunded one has no ticket — so it is reloaded before the
      // passenger can get back to it.
      await _fetch(silent: true);
      _emit(TravelChosen(booking: current.booking, applied: applied));
    } on ApiFailure catch (failure) {
      // Re-read rather than report and stop: nearly every refusal here is the
      // world having changed — the coach filled, the deadline passed — and
      // the passenger's next move is to look at the options again.
      try {
        final refreshed = await _gateway.travelOptions(current.booking.ref);
        _emit(
          ChoosingTravel(
            booking: current.booking,
            choices: refreshed,
            failure: failure,
          ),
        );
      } on ApiFailure {
        // The options cannot be re-read either. Now it is a failure screen,
        // because there is nothing left to show.
        _emit(TicketsFailed(failure));
      }
    }
  }

  /// Opens the share sheet, reading whatever link already exists.
  ///
  /// Read rather than minted: opening the sheet must not create a link, or a
  /// traveller who taps "partager" to see what it does has quietly published
  /// their journey.
  Future<void> openSharing(BookingDto booking) async {
    _emit(SharingTrip(booking: booking, share: null, busy: true));
    try {
      final share = await _gateway.tripShare(booking.ref);
      _emit(SharingTrip(booking: booking, share: share));
    } on ApiFailure catch (failure) {
      _emit(TicketsFailed(failure));
    }
  }

  /// Mints one, or hands back the one that exists. The server decides which.
  Future<void> shareTrip() async {
    final current = _step;
    if (current is! SharingTrip || current.busy) return;

    _emit(
      SharingTrip(booking: current.booking, share: current.share, busy: true),
    );

    try {
      final share = await _gateway.shareTrip(current.booking.ref);
      _emit(SharingTrip(booking: current.booking, share: share));
    } on ApiFailure catch (failure) {
      _emit(SharingTrip(booking: current.booking, share: current.share));
      _emit(TicketsFailed(failure));
    }
  }

  /// Kills the link. The sheet stays open on purpose — somebody who has just
  /// revoked wants to see that it is gone, not be returned to a list.
  Future<void> revokeShare() async {
    final current = _step;
    if (current is! SharingTrip || current.busy) return;

    _emit(
      SharingTrip(booking: current.booking, share: current.share, busy: true),
    );

    try {
      await _gateway.revokeTripShare(current.booking.ref);
      _emit(SharingTrip(booking: current.booking, share: null));
    } on ApiFailure catch (failure) {
      _emit(SharingTrip(booking: current.booking, share: current.share));
      _emit(TicketsFailed(failure));
    }
  }

  /// Opens the cancellation sheet, reading what cancelling would do.
  ///
  /// Read every time it opens and never cached: the terms depend on how long
  /// is left before departure, and a sheet drawn from this morning's answer
  /// would offer a refund band that elapsed at lunchtime.
  Future<void> openCancellation(BookingDto booking) async {
    _emit(Cancelling(booking: booking, offer: null, busy: true));
    try {
      final offer = await _gateway.cancellationOffer(booking.ref);
      _emit(Cancelling(booking: booking, offer: offer));
    } on ApiFailure catch (failure) {
      _emit(TicketsFailed(failure));
    }
  }

  /// Does it. The seat is on sale again before this returns.
  Future<void> confirmCancellation() async {
    final current = _step;
    if (current is! Cancelling || current.busy || current.offer == null) return;

    _emit(
      Cancelling(booking: current.booking, offer: current.offer, busy: true),
    );

    try {
      final done = await _gateway.cancelBooking(current.booking.ref);
      // The list behind is now wrong — the booking is cancelled and its
      // ticket is void — so it is reloaded before the traveller can get back
      // to it.
      await _fetch(silent: true);
      _emit(Cancelled(booking: current.booking, done: done));
    } on ApiFailure catch (failure) {
      // Re-read rather than report and stop. Every refusal here is the world
      // having moved — the coach left, a counter got there first, a payment
      // landed — and the honest next screen is the same sheet with what is
      // now true on it.
      try {
        final refreshed = await _gateway.cancellationOffer(current.booking.ref);
        _emit(
          Cancelling(
            booking: current.booking,
            offer: refreshed,
            failure: failure,
          ),
        );
      } on ApiFailure {
        _emit(TicketsFailed(failure));
      }
    }
  }

  /// Back to the list from the choice screen or its receipt.
  void closeChoices() => _emit(_ready());

  /// Back to the list, from a ticket. Re-derives it so a booking paid for in
  /// another tab of somebody's life is where it should be.
  void closeTicket() => _emit(_ready());

  Future<void> dispose() => _steps.close();
}
