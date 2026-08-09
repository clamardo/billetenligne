import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/travel_gateway.dart';

/// Where the traveller is in the funnel, and what the screen should render.
///
/// A sealed type rather than a bag of nullable fields, because "loading with
/// stale results showing" and "failed after a successful load" are real states
/// that a `bool isLoading` plus a `String? error` cannot express without
/// producing combinations that mean nothing.
sealed class BookingStep {
  const BookingStep();
}

final class Idle extends BookingStep {
  const Idle();
}

final class Searching extends BookingStep {
  const Searching();
}

final class ResultsReady extends BookingStep {
  const ResultsReady(this.departures, {this.stale = false});

  final List<DepartureSummaryDto> departures;

  /// True when these came from the last successful load rather than from this
  /// request. Rendered with a banner: stale times are useful, silently stale
  /// times are a lie.
  final bool stale;
}

final class LoadingSeatMap extends BookingStep {
  const LoadingSeatMap(this.departure);
  final DepartureSummaryDto departure;
}

final class ChoosingSeats extends BookingStep {
  const ChoosingSeats(this.departure, this.seatMap, this.selected);

  final DepartureSummaryDto departure;
  final SeatMapDto seatMap;
  final Set<String> selected;

  Money get fare {
    var minor = 0;
    for (final label in selected) {
      final seat = seatMap.seats.where((s) => s.label == label).firstOrNull;
      minor += seat?.fare?.minor ?? departure.fare.minor;
    }
    return Money(minor, departure.fare.currency);
  }

  Money get total => fare + departure.serviceFee;
}

/// The seats are chosen and the traveller has no account yet.
///
/// This is the ONE moment sign-in is asked for (ADR-0013). Not at launch, not
/// before the search, not before the price — by here they have seen the
/// departure, the seat and the total, and are being asked for an address to
/// send a ticket to rather than for permission to look around.
///
/// Carries the whole selection so that finishing sign-in resumes the hold
/// rather than restarting the funnel.
final class NeedsIdentity extends BookingStep {
  const NeedsIdentity(this.departure, this.seatMap, this.selected);
  final DepartureSummaryDto departure;
  final SeatMapDto seatMap;
  final Set<String> selected;
}

final class Holding extends BookingStep {
  const Holding(this.departure, this.seatMap, this.selected);
  final DepartureSummaryDto departure;
  final SeatMapDto seatMap;
  final Set<String> selected;
}

final class HoldReady extends BookingStep {
  const HoldReady(this.departure, this.hold);
  final DepartureSummaryDto departure;
  final HoldDto hold;
}

/// Something went wrong, and we know exactly what.
final class StepFailed extends BookingStep {
  const StepFailed(this.failure, {this.recoverable = true});

  final ApiFailure failure;

  /// Whether the screen offers a way forward other than going back. A seat
  /// that is genuinely sold is not recoverable by retrying — the way forward
  /// is a different seat.
  final bool recoverable;
}

/// The traveller's journey from a search box to a held seat.
///
/// A plain broadcast stream rather than a `ChangeNotifier`, and that is not a
/// stylistic choice: `ChangeNotifier` lives in `package:flutter/foundation`,
/// and the layer check refuses Flutter in the application layer. The rule
/// caught this exact import, and it was right to — a use case that needs the
/// Flutter SDK to exist cannot be tested with `dart test`, cannot be reused by
/// the console's web build without dragging the framework in, and has quietly
/// inverted the dependency direction.
///
/// No state-management package either. This app has one linear funnel, and a
/// library that adds 200 KB to the APK to model it would be paid for by the
/// person with the cheapest handset.
///
/// Three rules live here and nowhere else:
///
///   * **The idempotency key is minted when the attempt begins**, not when the
///     request is sent, and it is reused for every retry of that attempt. That
///     one decision is what makes a dropped connection safe.
///   * **A failed search keeps the previous results.** Losing signal must not
///     blank a screen somebody was reading.
///   * **Selection is capped**, and the cap is stated before it is hit rather
///     than by a control that silently stops responding.
final class BookingFlow {
  BookingFlow({
    required TravelGateway gateway,
    required bool Function() isSignedIn,
    this.maxSeats = 6,
  }) : _gateway = gateway,
       _isSignedIn = isSignedIn;

  final TravelGateway _gateway;

  /// Asked at the moment of holding, not held as a flag. A flag captured at
  /// construction is wrong the instant somebody signs in or is signed out
  /// mid-session, and the second of those happens on a revoked token.
  final bool Function() _isSignedIn;

  final int maxSeats;

  final _steps = StreamController<BookingStep>.broadcast();

  BookingStep _step = const Idle();

  /// The current step. Held as well as streamed so a widget building for the
  /// first time has something to render before any event arrives.
  BookingStep get step => _step;

  Stream<BookingStep> get steps => _steps.stream;

  List<DepartureSummaryDto> _lastResults = const [];
  String? _attemptKey;

  /// The departure being booked, remembered independently of the step.
  ///
  /// Deriving it from the current step looked tidier and was wrong: after a
  /// failure the step is [StepFailed], which carries no departure, so
  /// [backToSeatMap] — the exact recovery the error screen offers — silently
  /// did nothing and left the traveller on a dead end. The test caught it.
  DepartureSummaryDto? _activeDeparture;

  SearchDeparturesQuery? _lastQuery;
  SearchDeparturesQuery? get lastQuery => _lastQuery;

  void _emit(BookingStep next) {
    _step = next;
    if (!_steps.isClosed) _steps.add(next);
  }

  // ── Search ────────────────────────────────────────────────────────────────

  Future<void> search(SearchDeparturesQuery query) async {
    _lastQuery = query;
    _emit(const Searching());

    try {
      final results = await _gateway.search(query);
      _lastResults = results;
      _emit(ResultsReady(results));
    } on ApiFailure catch (failure) {
      // Signal dropped mid-search. Showing what we had a minute ago, clearly
      // marked as old, beats an empty screen — the 06:00 has not moved.
      if (_lastResults.isNotEmpty && failure is! ServerRefused) {
        _emit(ResultsReady(_lastResults, stale: true));
      } else {
        _emit(StepFailed(failure));
      }
    }
  }

  // ── Seat map ──────────────────────────────────────────────────────────────

  Future<void> openSeatMap(DepartureSummaryDto departure) async {
    _activeDeparture = departure;
    _emit(LoadingSeatMap(departure));

    try {
      final map = await _gateway.seatMap(departure.id);
      _emit(ChoosingSeats(departure, map, const {}));
    } on ApiFailure catch (failure) {
      _emit(StepFailed(failure));
    }
  }

  /// Toggles a seat. Returns false when the cap refused it, so the screen can
  /// say so rather than appear broken.
  bool toggleSeat(String label) {
    final current = _step;
    if (current is! ChoosingSeats) return false;

    final next = {...current.selected};
    if (!next.remove(label)) {
      if (next.length >= maxSeats) return false;
      next.add(label);
    }

    _emit(ChoosingSeats(current.departure, current.seatMap, next));
    return true;
  }

  // ── Hold ──────────────────────────────────────────────────────────────────

  Future<void> holdSelection() async {
    final current = _step;
    if (current is! ChoosingSeats || current.selected.isEmpty) return;

    // The gate. A hold has an owner — an anonymous one is a hold nobody can be
    // warned about before it expires — so this is where browsing ends.
    if (!_isSignedIn()) {
      _emit(NeedsIdentity(current.departure, current.seatMap, current.selected));
      return;
    }

    // Minted here, at the start of the attempt. Every retry below reuses it,
    // which is the entire reason a duplicate tap on a flaky connection cannot
    // produce two holds.
    _attemptKey ??= IdempotencyKey.generate();

    _emit(Holding(current.departure, current.seatMap, current.selected));

    try {
      final hold = await _gateway.hold(
        departureId: current.departure.id,
        seatLabels: current.selected.toList()..sort(),
        idempotencyKey: _attemptKey!,
      );
      _attemptKey = null;
      _emit(HoldReady(current.departure, hold));
    } on ApiFailure catch (failure) {
      // A refusal ends this attempt: the next try is a genuinely new request
      // and must not reuse a key the server has already answered.
      if (failure is ServerRefused) _attemptKey = null;

      _emit(
        StepFailed(
          failure,
          // "That seat is gone" is not fixed by trying again. The way forward
          // is the seat map, and the screen offers that instead.
          recoverable: failure is! ServerRefused,
        ),
      );
    }
  }

  /// Picks the funnel back up after signing in.
  ///
  /// Resumes rather than restarts: the traveller chose those seats before
  /// being interrupted, and making them choose again is a good way to lose
  /// them. The seats may of course have gone in the meantime — the hold
  /// refusal below handles that, and it handles it better than a pre-emptive
  /// re-fetch would, because it is one round trip rather than two.
  Future<void> resumeAfterIdentity() async {
    final current = _step;
    if (current is! NeedsIdentity) return;

    _emit(ChoosingSeats(current.departure, current.seatMap, current.selected));
    await holdSelection();
  }

  /// The traveller backed out of signing in. Their seats are still selected.
  void abandonIdentity() {
    final current = _step;
    if (current is! NeedsIdentity) return;
    _emit(ChoosingSeats(current.departure, current.seatMap, current.selected));
  }

  /// Returns to the seat map after a refusal, so a traveller whose seat was
  /// taken lands where they can choose another rather than at a dead end.
  ///
  /// Re-fetches rather than reusing the map we had. The whole reason we are
  /// here is that the map was out of date, and showing the same stale map
  /// would invite the traveller to pick the same taken seat again.
  Future<void> backToSeatMap() async {
    final departure = _activeDeparture;
    if (departure != null) await openSeatMap(departure);
  }

  Future<void> releaseHold() async {
    final current = _step;
    if (current is! HoldReady) return;

    try {
      await _gateway.release(current.hold.id);
    } on ApiFailure catch (_) {
      // Deliberately swallowed. The hold expires on its own in minutes, so a
      // failed release costs an operator a few minutes of inventory — and
      // showing an error for an action the traveller has already mentally
      // completed would be worse than the cost.
    }
    _emit(const Idle());
  }

  /// The hold ran out while the traveller was on the payment screen.
  void holdExpired() {
    if (_step is! HoldReady) return;
    _emit(
      const StepFailed(
        ServerRefused(410, ApiError(code: ErrorCode.holdExpired)),
        recoverable: false,
      ),
    );
  }

  void reset() {
    _attemptKey = null;
    _activeDeparture = null;
    _emit(const Idle());
  }

  Future<void> dispose() => _steps.close();
}
