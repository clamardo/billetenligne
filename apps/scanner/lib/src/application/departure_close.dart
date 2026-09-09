import 'package:bel_platform/bel_platform.dart';

import 'ports/boarding_gateway.dart';

/// Says the coach has left, or has arrived (J4).
///
/// A use case rather than a call from a button handler, because of the rule
/// it encodes and the one it deliberately does not: **this is the only thing
/// the scanner does that cannot be queued.** Every other write on this device
/// is a record of something that already happened — a person at a door, a
/// place on a road — and stays true however late it arrives. Closing a
/// departure is not a record, it is an instruction: it stops new sales on the
/// server, and a close that syncs three hours later has let a counter sell
/// seats on a coach halfway to Pointe-Noire.
///
/// So it fails honestly with no network, and the conductor tries again. It
/// touches the outbox not at all: boardings queued behind it upload
/// afterwards and are still accepted, because the door happened while the
/// coach was there.
final class DepartureClose {
  const DepartureClose({
    required BoardingGateway gateway,
    required String departureId,
    DepartureState state = DepartureState.scheduled,
  }) : _gateway = gateway,
       _departureId = departureId,
       _state = state;

  final BoardingGateway _gateway;
  final String _departureId;
  final DepartureState _state;

  /// What this coach can still be told, or null when there is nothing left.
  ///
  /// The button is drawn from this, so a coach that has arrived draws none
  /// rather than one whose only outcome is a refusal.
  DepartureState? get next => switch (_state) {
    DepartureState.scheduled ||
    DepartureState.delayed ||
    DepartureState.boarding => DepartureState.departed,
    DepartureState.departed => DepartureState.arrived,
    DepartureState.arrived || DepartureState.cancelled => null,
  };

  /// One attempt. Failure is reported rather than thrown, the same shape
  /// [BoardingSync.drain] uses — the conductor decides whether to try again,
  /// and nothing on the device has changed in the meantime.
  Future<DepartureClose> call() async {
    final target = next;
    if (target == null) return this;

    final answered = await _gateway.setDepartureState(
      departureId: _departureId,
      state: target.name,
    );
    return DepartureClose(
      gateway: _gateway,
      departureId: _departureId,
      state: DepartureState.byName(answered.state) ?? target,
    );
  }
}
