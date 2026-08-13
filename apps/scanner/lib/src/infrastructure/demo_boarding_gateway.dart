import 'package:bel_contracts/bel_contracts.dart';

import '../application/ports/boarding_gateway.dart';
import 'demo_data.dart';

/// The same three calls, answered locally by a signed demo departure.
///
/// It exists so the app has **one** path: the picker, the pin and the outbox
/// are exercised on a fresh clone with no server, through the same widgets a
/// conductor uses. A demo that skipped the picker would be a picker nobody
/// ever looked at until the morning it was needed.
final class DemoBoardingGateway implements BoardingGateway {
  DemoBoardingGateway();

  DemoDeparture? _departure;

  Future<DemoDeparture> _build() async =>
      _departure ??= await DemoDeparture.build();

  @override
  Future<List<BoardingDepartureDto>> coachesOn(DateTime localDate) async {
    final demo = await _build();
    return [
      BoardingDepartureDto(
        id: demo.manifest.departureId,
        routeCode: 'BZV>PNR',
        originCity: 'Brazzaville',
        destinationCity: 'Pointe-Noire',
        departsAt: demo.manifest.departsAt,
        expected: demo.manifest.expected,
        capacity: 60,
        status: 'scheduled',
        stationName: 'Gare routière de Brazzaville',
      ),
    ];
  }

  @override
  Future<PinnedDeparture> pin(String departureId) async {
    final demo = await _build();
    return PinnedDeparture(
      manifest: demo.manifest,
      signatures: demo.verifier,
      preparer: demo.verifier,
      simulatedScans: demo.simulatedScans(),
    );
  }

  /// Settles everything, because there is nowhere for it to go. The outbox
  /// still empties on screen, which is the behaviour being demonstrated.
  @override
  Future<Set<String>> uploadBoardings({
    required String departureId,
    required List<BoardingUploadDto> boardings,
  }) async => {for (final b in boardings) b.key};
}
