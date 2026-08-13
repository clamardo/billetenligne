import 'dart:convert';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/ports/boarding_gateway.dart';

/// The real gateway: three calls to the console surface, none at the door.
///
/// Thin on purpose. The interesting work is the translation below — a wire
/// manifest into the domain one the verifier decides with — and that is where
/// the base64 stops and the bytes begin.
final class ApiBoardingGateway implements BoardingGateway {
  const ApiBoardingGateway(this._client, {required Clock clock})
    : _clock = clock;

  final BelApiClient _client;
  final Clock _clock;

  @override
  Future<List<BoardingDepartureDto>> coachesOn(DateTime localDate) =>
      _client.boardingDay(localDate);

  @override
  Future<PinnedDeparture> pin(String departureId) async {
    final dto = await _client.pinForBoarding(departureId);

    final verifier = Ed25519TicketVerifier({
      for (final e in dto.keys.entries) e.key: base64Decode(e.value),
    });

    return PinnedDeparture(
      manifest: BoardingManifest(
        departureId: dto.departureId,
        operatorCode: dto.operatorCode,
        routeCode: dto.routeCode,
        departsAt: dto.departsAt,
        entries: {
          for (final t in dto.tickets)
            BoardingManifest.keyFor(t.bookingRef, t.seatLabel): ManifestEntry(
              bookingRef: t.bookingRef,
              seatLabel: t.seatLabel,
              passengerName: t.passengerName,
              rotatingSecret: base64Decode(t.rotatingSecret),
              boardsAt: t.boardsAt,
              alightsAt: t.alightsAt,
            ),
        },
        voidedTicketRefs: dto.voided.toSet(),
        // Stamped here rather than server-side: what the conductor needs to
        // know is how long ago *this device* last heard, and a server clock
        // cannot answer that.
        pinnedAt: _clock.now(),
      ),
      signatures: verifier,
      preparer: verifier,
    );
  }

  @override
  Future<Set<String>> uploadBoardings({
    required String departureId,
    required List<BoardingUploadDto> boardings,
  }) async {
    final result = await _client.uploadBoardings(
      departureId: departureId,
      boardings: boardings,
    );
    // Both lists leave the outbox. `unknown` is not a failure to be retried —
    // it is a ticket this coach has never heard of, and it will still be one
    // tomorrow.
    return {...result.recorded, ...result.unknown};
  }
}
