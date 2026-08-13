import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_scanner/main.dart';
import 'package:bel_scanner/src/application/ports/boarding_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// The app from launch to the picker.
///
/// It stops at the coach list on purpose: tapping through opens the camera,
/// and a `MobileScannerController` in a widget test is a plugin channel with
/// nothing on the other end. What the wire tests prove is what happens after
/// the tap; what this proves is that the app gets that far by itself.
void main() {
  testWidgets("lands on today's coaches with nobody to sign in", (
    tester,
  ) async {
    final catalog = await loadTestCatalog();

    await tester.pumpWidget(
      ScannerApp(
        catalog: catalog,
        gateway: _OneCoach(),
        deviceId: 'test-device',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mes départs du jour'), findsOneWidget);
    expect(find.text('Brazzaville → Pointe-Noire'), findsOneWidget);
  });

  testWidgets('a gateway that cannot answer says so and offers a retry', (
    tester,
  ) async {
    final catalog = await loadTestCatalog();

    await tester.pumpWidget(
      ScannerApp(
        catalog: catalog,
        gateway: _Refuses(),
        deviceId: 'test-device',
      ),
    );
    await tester.pumpAndSettle();

    // Not an exception's toString: the person reading it is standing in a
    // yard and has to know what to do next.
    expect(
      find.text('Impossible de charger la liste des passagers.'),
      findsOneWidget,
    );
    expect(find.text("Aucun départ aujourd'hui."), findsOneWidget);
  });
}

final class _OneCoach implements BoardingGateway {
  @override
  Future<List<BoardingDepartureDto>> coachesOn(DateTime localDate) async => [
    BoardingDepartureDto(
      id: 'dep-1',
      routeCode: 'BZV>PNR',
      originCity: 'Brazzaville',
      destinationCity: 'Pointe-Noire',
      departsAt: DateTime.utc(2026, 8, 15, 6),
      expected: 41,
      capacity: 49,
      status: 'scheduled',
    ),
  ];

  @override
  Future<PinnedDeparture> pin(String departureId) => throw UnimplementedError();

  @override
  Future<Set<String>> uploadBoardings({
    required String departureId,
    required List<BoardingUploadDto> boardings,
  }) => throw UnimplementedError();

  @override
  Future<Set<String>> uploadCheckpoints({
    required String departureId,
    required List<PassageUploadDto> passages,
  }) => throw UnimplementedError();
}

final class _Refuses implements BoardingGateway {
  @override
  Future<List<BoardingDepartureDto>> coachesOn(DateTime localDate) async =>
      throw StateError('no');

  @override
  Future<PinnedDeparture> pin(String departureId) => throw UnimplementedError();

  @override
  Future<Set<String>> uploadBoardings({
    required String departureId,
    required List<BoardingUploadDto> boardings,
  }) => throw UnimplementedError();

  @override
  Future<Set<String>> uploadCheckpoints({
    required String departureId,
    required List<PassageUploadDto> passages,
  }) => throw UnimplementedError();
}
