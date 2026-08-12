import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

/// A traveller waiting for a seat on a coach that is full.
final class SeatAlert {
  const SeatAlert({
    required this.id,
    required this.departureId,
    required this.seatsWanted,
    required this.createdAt,
    this.notifiedAt,
  });

  final String id;
  final String departureId;
  final int seatsWanted;
  final DateTime createdAt;

  /// When the message went out, if it has. A spent alert is kept rather than
  /// deleted: "I asked and was never told" is a support conversation, and a
  /// deleted row cannot answer it.
  final DateTime? notifiedAt;

  bool get isWaiting => notifiedAt == null;
}

sealed class SeatAlertFailure extends DomainFailure {
  const SeatAlertFailure();
}

/// Asking about a coach that has already left, or one nobody is selling.
final class NotWorthWaitingFor extends SeatAlertFailure {
  const NotWorthWaitingFor(this.departureId);
  final String departureId;
  @override
  String get code => ErrorCode.notFound;
  @override
  Map<String, Object?> get params => {'departureId': departureId};
}

/// A coach that has room right now.
///
/// Refused rather than accepted-and-fired-immediately, because the honest
/// answer is "go and book it": an alert would put a message in a queue about
/// a seat the traveller is looking at.
final class SeatsAreAvailable extends SeatAlertFailure {
  const SeatsAreAvailable(this.available);
  final int available;
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => {'available': available};
}

/// Who is waiting for what.
///
/// **An alert holds nothing.** It is a row of intent: the first person to pay
/// still gets the seat, and everybody waiting is told at the same moment.
/// Anything stronger would be a queue over inventory that is simultaneously
/// on sale to the whole market — a promise this system cannot keep at a coach
/// door.
abstract interface class SeatAlerts {
  /// Registers interest. Asking twice is asking once.
  Future<Result<SeatAlert, SeatAlertFailure>> watch({
    required String departureId,
    required String userId,
    required int seatsWanted,
  });

  /// Withdraws it. Silent when there was nothing waiting — somebody who taps
  /// "no longer interested" twice has got what they wanted both times.
  Future<void> forget({required String departureId, required String userId});

  /// Everything this traveller is still waiting on, soonest coach first.
  Future<List<SeatAlert>> waitingFor(String userId);
}

/// The API with no database behind it.
final class NoSeatAlerts implements SeatAlerts {
  const NoSeatAlerts();

  @override
  Future<Result<SeatAlert, SeatAlertFailure>> watch({
    required String departureId,
    required String userId,
    required int seatsWanted,
  }) async => Err(NotWorthWaitingFor(departureId));

  @override
  Future<void> forget({
    required String departureId,
    required String userId,
  }) async {}

  @override
  Future<List<SeatAlert>> waitingFor(String userId) async => const [];
}
