import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:bel_scanner/src/application/departure_close.dart';
import 'package:bel_scanner/src/application/ports/boarding_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one write on this handset that cannot be queued (J4).
///
/// Everything else the scanner sends is a record of something that already
/// happened and stays true however late it arrives. Closing a departure is an
/// instruction — it stops new sales — so it has to fail rather than wait.
void main() {
  late _Server server;

  setUp(() => server = _Server());

  DepartureClose close([DepartureState state = DepartureState.scheduled]) =>
      DepartureClose(gateway: server, departureId: 'dep-1', state: state);

  group('what the coach can still be told', () {
    test('one still in the yard has left', () {
      for (final state in const [
        DepartureState.scheduled,
        DepartureState.delayed,
        DepartureState.boarding,
      ]) {
        expect(close(state).next, DepartureState.departed, reason: state.name);
      }
    });

    test('one on the road has arrived', () {
      expect(close(DepartureState.departed).next, DepartureState.arrived);
    });

    // The button is drawn from this, so a coach that has finished draws none
    // rather than one whose only outcome is a refusal.
    test('and one that has finished has nothing left', () {
      expect(close(DepartureState.arrived).next, isNull);
      expect(close(DepartureState.cancelled).next, isNull);
    });
  });

  group('saying it', () {
    test('sends the state the coach is going to', () async {
      await close()();

      expect(server.sent, ['dep-1:departed']);
    });

    test('and the answer is what the next tap is offered from', () async {
      final departed = await close()();

      expect(departed.next, DepartureState.arrived);
      expect((await departed()).next, isNull);
      expect(server.sent, ['dep-1:departed', 'dep-1:arrived']);
    });

    // The server is the authority on what this coach is. A handset that
    // pinned an hour ago may be wrong about it — somebody in the office may
    // have closed it already — and the answer, not the request, is what the
    // next button is drawn from.
    test('the server may answer with something else entirely', () async {
      server.answersWith = 'arrived';

      expect((await close()()).next, isNull);
    });

    test('a coach with nothing left to say sends nothing', () async {
      await close(DepartureState.arrived)();

      expect(server.sent, isEmpty);
    });

    // No network. It throws rather than queueing, and the page turns that
    // into one sentence: try again where there is signal.
    test('no signal is a failure, not a queued row', () async {
      server.refuses = true;

      await expectLater(close()(), throwsA(isA<StateError>()));
    });
  });
}

final class _Server implements BoardingGateway {
  final sent = <String>[];
  bool refuses = false;
  String? answersWith;

  @override
  Future<DepartureStateDto> setDepartureState({
    required String departureId,
    required String state,
  }) async {
    if (refuses) throw StateError('no network');
    sent.add('$departureId:$state');
    return DepartureStateDto(
      state: answersWith ?? state,
      at: DateTime.utc(2026, 8, 15, 6),
    );
  }

  @override
  Future<List<BoardingDepartureDto>> coachesOn(DateTime localDate) =>
      throw UnimplementedError();

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
