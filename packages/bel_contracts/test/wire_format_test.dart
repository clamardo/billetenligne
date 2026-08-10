import 'dart:convert';
import 'dart:io';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// Round-trips a DTO through real JSON text, not just a map. Encoding to a
/// string is what catches a value `jsonEncode` cannot represent.
T roundTrip<T>(
  Map<String, Object?> Function() encode,
  T Function(Map<String, Object?>) decode,
) {
  final text = jsonEncode(encode());
  return decode(jsonDecode(text) as Map<String, Object?>);
}

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 5, 0);

  group('Money on the wire is exact', () {
    test('encodes as minor units plus a currency code', () {
      expect(Wire.money(const Money.xaf(9300)), {
        'minor': 9300,
        'currency': 'XAF',
      });
    });

    test('9 000 XAF survives a round trip unchanged', () {
      final text = jsonEncode(Wire.money(const Money.xaf(9000)));
      final back = Wire.readMoney(jsonDecode(text));
      expect(back, const Money.xaf(9000));
      expect(back.currency.exponent, 0);
    });

    test('a float amount is rejected rather than silently truncated', () {
      // This is the bug this encoding exists to prevent.
      expect(
        () => Wire.readMoney({'minor': 9300.5, 'currency': 'XAF'}),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('an unknown currency is rejected, not defaulted', () {
      expect(
        () => Wire.readMoney({'minor': 100, 'currency': 'ZZZ'}),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('a two-decimal currency keeps its exponent', () {
      final back = Wire.readMoney(Wire.money(const Money(9000, Currency.eur)));
      expect(back.minor, 9000);
      expect(back.currency.exponent, 2);
    });

    test('no amount is ever sent pre-formatted', () {
      // A formatted string would force the server to guess the reader's
      // locale, and it would eventually guess wrong.
      final encoded = Wire.money(const Money.xaf(9000));
      expect(encoded.values.whereType<String>(), ['XAF']);
    });
  });

  group('timestamps and enums', () {
    test('instants are UTC ISO-8601', () {
      final local = DateTime(2026, 8, 15, 6);
      final wire = Wire.instant(local);
      expect(wire, endsWith('Z'));
      expect(Wire.readInstant(wire).isUtc, isTrue);
    });

    test('enums travel by name, so inserting a value is safe', () {
      // An index would reorder silently and take production with it.
      expect(
        Wire.readEnum('sold', SeatStatusDto.values, field: 'status'),
        SeatStatusDto.sold,
      );
      expect(
        () => Wire.readEnum('0', SeatStatusDto.values, field: 'status'),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('a field name is always in the error', () {
      // "type 'Null' is not a subtype of type 'String'" in a production log
      // tells you nothing about which endpoint broke.
      try {
        Wire.requireString(null, 'passenger.fullName');
        fail('should have thrown');
      } on WireFormatException catch (e) {
        expect(e.field, 'passenger.fullName');
        expect(e.toString(), contains('passenger.fullName'));
      }
    });
  });

  group('errors carry keys, never prose', () {
    test('an error serialises to a code and a catalog key', () {
      const err = ApiError(
        code: ErrorCode.paymentInsufficientFunds,
        params: {'operator': 'Airtel Money'},
        traceId: '01JABC',
      );
      final json = err.toJson()['error']! as Map<String, Object?>;

      expect(json['code'], 'payment.insufficient_funds');
      expect(json['messageKey'], 'errors.payment.insufficient_funds');
      expect(json['retryable'], isTrue);
      expect(
        json.containsKey('message'),
        isFalse,
        reason: 'a prose message would be rendered in the wrong language',
      );
    });

    test('round-trips', () {
      final back = roundTrip(
        () =>
            const ApiError(code: ErrorCode.holdExpired, traceId: 'x').toJson(),
        ApiError.fromJson,
      );
      expect(back.code, ErrorCode.holdExpired);
      expect(back.traceId, 'x');
      expect(back.retryable, isFalse);
    });

    test('retryability is honest', () {
      // Offering "try again" on a non-retryable failure is a lie that costs
      // trust and generates support load.
      expect(const ApiError(code: ErrorCode.paymentWrongPin).retryable, isTrue);
      expect(
        const ApiError(code: ErrorCode.paymentSubscriberBarred).retryable,
        isFalse,
      );
      expect(
        const ApiError(code: ErrorCode.holdExpiredDuringPayment).retryable,
        isFalse,
      );
    });
  });

  group('every domain failure code has a wire code', () {
    test('payment failure codes are all present in ErrorCode', () {
      // The domain and the wire must not drift: a code the domain can produce
      // but the API cannot name would surface as a generic 500.
      final declared = _errorCodeConstants();
      for (final code in PaymentFailureCode.values) {
        expect(
          declared,
          contains(code.wire),
          reason: '${code.name} -> "${code.wire}" is missing from ErrorCode',
        );
      }
    });

    test('every declared code maps to a catalog key', () {
      for (final code in _errorCodeConstants()) {
        expect(ErrorCode.messageKey(code), 'errors.$code');
      }
    });
  });

  group('market config is server-driven', () {
    test('a market round-trips with its rails', () {
      final dto = MarketDto.fromDomain(Market.congoBrazzaville);
      final back = roundTrip(dto.toJson, MarketDto.fromJson);

      expect(back.code, 'CG');
      expect(back.currency, 'XAF');
      expect(back.currencyExponent, 0);
      expect(back.diallingCode, '242');
      expect(back.rails, hasLength(Market.congoBrazzaville.rails.length));
      expect(back.serviceFee, const Money.xaf(300));
    });

    test('the currency exponent is sent explicitly', () {
      // So a client never has to know that XAF is zero-decimal. Hardcoding
      // that assumption is how a 9 000 XAF fare becomes 90 XAF.
      final dto = MarketDto.fromDomain(Market.congoBrazzaville);
      expect(dto.currencyExponent, 0);
    });

    test('the client resolves a rail from a number with no local table', () {
      final dto = MarketDto.fromDomain(Market.congoBrazzaville);
      expect(dto.railForNational('061234567')?.id, 'cg.mtn_momo');
      expect(dto.railForNational('051234567')?.id, 'cg.airtel_money');
      expect(dto.railForNational('091234567'), isNull);
    });

    test('a disabled rail is advertised with a reason, not hidden', () {
      final dto = MarketDto.fromDomain(Market.congoBrazzaville);
      final orange = dto.rails.firstWhere((r) => r.id == 'cg.orange_money');
      expect(orange.enabled, isFalse);
      expect(orange.disabledReasonKey, isNotNull);
    });

    test('a mobile money rail always carries its USSD fallback', () {
      final dto = MarketDto.fromDomain(Market.congoBrazzaville);
      for (final r in dto.rails.where((r) => r.kind == 'mobileMoney')) {
        expect(r.ussdCode, isNotNull, reason: r.id);
      }
    });
  });

  group('booking and ticket DTOs', () {
    test('a hold round-trips with its expiry as an instant', () {
      final hold = HoldDto(
        id: 'h1',
        departureId: 'd1',
        seatLabels: const ['14A', '14B'],
        expiresAt: t0.add(const Duration(minutes: 15)),
        total: const Money.xaf(18600),
        fare: const Money.xaf(18000),
        serviceFee: const Money.xaf(600),
        state: 'active',
      );
      final back = roundTrip(hold.toJson, HoldDto.fromJson);

      expect(back.seatLabels, ['14A', '14B']);
      expect(back.total, const Money.xaf(18600));
      // Sent as an instant, not a remaining duration, so a slow response
      // cannot make the countdown lie.
      expect(back.remaining(t0), const Duration(minutes: 15));
      expect(back.remaining(t0.add(const Duration(hours: 1))), Duration.zero);
    });

    test('a ticket carries everything needed to render offline', () {
      final ticket = TicketDto(
        id: 't1',
        bookingRef: 'BEL-7QK4M2',
        seatLabel: '14A',
        passengerName: 'Aline M.',
        qrPayload: 'NCF3...',
        rotatingSecret: 'seed',
        keyId: 2,
        issuedAt: t0,
      );
      final back = roundTrip(ticket.toJson, TicketDto.fromJson);

      expect(
        back.qrPayload,
        isNotEmpty,
        reason: 'the QR must not need a fetch',
      );
      expect(
        back.rotatingSecret,
        isNotEmpty,
        reason: 'the freshness code is computed on-device',
      );
      expect(back.keyId, 2, reason: 'key rotation must be seamless');
      expect(back.isVoid, isFalse);
    });

    test('a voided ticket says so', () {
      final ticket = TicketDto(
        id: 't1',
        bookingRef: 'BEL-7QK4M2',
        seatLabel: '14A',
        passengerName: 'Aline M.',
        qrPayload: 'x',
        rotatingSecret: 's',
        keyId: 1,
        issuedAt: t0,
        voidedAt: t0.add(const Duration(hours: 1)),
      );
      expect(roundTrip(ticket.toJson, TicketDto.fromJson).isVoid, isTrue);
    });

    test('a passenger phone is separate from the purchaser', () {
      // The field that makes "buy a ticket for my mother" first-class.
      const p = PassengerDto(fullName: 'Aline M.', phone: '242061234567');
      final back = roundTrip(p.toJson, PassengerDto.fromJson);
      expect(back.phone, '242061234567');
    });
  });

  group('payment DTOs', () {
    test('an in-flight intent tells the client when to poll again', () {
      final intent = PaymentIntent(
        id: 'pi1',
        bookingId: 'b1',
        railId: 'cg.airtel_money',
        amount: const Money.xaf(9300),
        idempotencyKey: 'k',
        createdAt: t0,
        state: PaymentState.pending,
      );
      final dto = PaymentIntentDto.fromDomain(intent, ussdCode: '*128#');

      expect(dto.isInFlight, isTrue);
      expect(dto.pollAfterSeconds, 5, reason: 'server-driven backoff');
      expect(dto.ussdCode, '*128#');
    });

    test('a settled intent stops polling', () {
      final intent = PaymentIntent(
        id: 'pi1',
        bookingId: 'b1',
        railId: 'cg.airtel_money',
        amount: const Money.xaf(9300),
        idempotencyKey: 'k',
        createdAt: t0,
        state: PaymentState.captured,
      );
      final dto = PaymentIntentDto.fromDomain(intent, bookingRef: 'BEL-7QK4M2');

      expect(dto.isSettled, isTrue);
      expect(dto.pollAfterSeconds, isNull);
      expect(dto.bookingRef, 'BEL-7QK4M2');
    });

    test('a failure code selects the message and the recovery', () {
      final intent = PaymentIntent(
        id: 'pi1',
        bookingId: 'b1',
        railId: 'cg.airtel_money',
        amount: const Money.xaf(9300),
        idempotencyKey: 'k',
        createdAt: t0,
        state: PaymentState.failed,
        failureCode: PaymentFailureCode.insufficientFunds,
      );
      final back = roundTrip(
        PaymentIntentDto.fromDomain(intent).toJson,
        PaymentIntentDto.fromJson,
      );
      expect(back.failureCode, 'payment.insufficient_funds');
      expect(
        ErrorCode.messageKey(back.failureCode!),
        'errors.payment.insufficient_funds',
      );
    });

    test('a refund quote is produced by the shared domain function', () {
      // The number here and the number the server charges with come from the
      // same call — that is the whole argument for Dart end to end.
      final departure = t0.add(const Duration(days: 3));
      final quote = quoteRefund(
        faceValue: const Money.xaf(9000),
        serviceFee: const Money.xaf(300),
        departsAt: departure,
        now: t0,
        policy: RefundPolicy.souple(),
      ).valueOrNull!;

      final dto = RefundQuoteDto.fromDomain(quote, bookingRef: 'BEL-7QK4M2');
      final back = roundTrip(dto.toJson, RefundQuoteDto.fromJson);

      expect(back.paid, const Money.xaf(9300));
      expect(back.refundable, const Money.xaf(9000));
      expect(back.retained, const Money.xaf(300));
      expect(back.rateBps, 10000);
      expect(
        back.refundable + back.retained,
        back.paid,
        reason: 'a quote must always account for every franc paid',
      );
    });

    test('an operator-caused refund is marked involuntary', () {
      final departure = t0.add(const Duration(minutes: 30));
      final quote = quoteRefund(
        faceValue: const Money.xaf(9000),
        serviceFee: const Money.xaf(300),
        departsAt: departure,
        now: t0,
        policy: RefundPolicy.strict(),
        operatorCaused: true,
      ).valueOrNull!;

      final dto = RefundQuoteDto.fromDomain(quote, bookingRef: 'BEL-7QK4M2');
      expect(dto.involuntary, isTrue);
      expect(
        dto.refundable,
        const Money.xaf(9300),
        reason: 'the platform floor refunds our fee too',
      );
      expect(dto.destination, 'source');
    });
  });

  group('the back office', () {
    test('an operator survives the round trip, commission included', () {
      final dto = AdminOperatorDto(
        id: 'op-1',
        code: 'ODN',
        legalName: 'Ocean du Nord SARL',
        status: 'under_review',
        marketCode: 'CG',
        createdAt: DateTime.utc(2026, 8, 1, 9),
        // Basis points on the wire. A rate that arrives as `0.075` is one
        // somebody eventually sends as `7.5`, and the difference is a
        // hundredfold error in what we take from a fare.
        commissionBps: 750,
        rccmNumber: 'CG-BZV-01-2019-B12-00345',
        documentCount: 4,
        expiringDocumentCount: 1,
      );

      final back = AdminOperatorDto.fromJson(dto.toJson());
      expect(back.commissionBps, 750);
      expect(back.rccmNumber, dto.rccmNumber);
      expect(back.expiringDocumentCount, 1);
      expect(back.isPending, isTrue);
    });

    test('a decision carries its reason, because an audit needs one', () {
      const request = OperatorDecisionRequest(
        decision: 'suspend',
        reason: 'insurance lapsed',
      );
      final back = OperatorDecisionRequest.fromJson(request.toJson());
      expect(back.decision, 'suspend');
      expect(back.reason, 'insurance lapsed');
      expect(
        () => OperatorDecisionRequest.fromJson(const {'decision': 'x'}),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('the audit trail is readable and carries no secrets', () {
      final entry = AuditEntryDto(
        action: 'operator.approve',
        actorType: 'platform_staff',
        actorId: 'u-1',
        reason: 'documents complete',
        createdAt: DateTime.utc(2026, 8, 2, 11),
      );
      final json = entry.toJson();
      // Before/after states stay server-side: they can hold a settlement
      // account number, and a trail rendered in a browser does not need one.
      expect(
        json.keys,
        unorderedEquals([
          'action',
          'actorType',
          'actorId',
          'reason',
          'createdAt',
        ]),
      );
      expect(AuditEntryDto.fromJson(json).reason, 'documents complete');
    });
  });

  group('a disruption on the wire', () {
    test('a declaration round-trips through the wire and back', () {
      final request = DeclareDisruptionRequest(
        kind: DisruptionKind.breakdownEnRoute,
        cause: DisruptionCause.mechanical,
        note: 'moteur, km 180 RN1',
        location: 'RN1 près de Dolisie',
        estimatedResolution: t0.add(const Duration(hours: 3)),
      );

      final back = DeclareDisruptionRequest.fromJson(request.toJson());
      expect(back.kind, DisruptionKind.breakdownEnRoute);
      expect(back.cause, DisruptionCause.mechanical);
      expect(back.note, 'moteur, km 180 RN1');
      expect(back.estimatedResolution, request.estimatedResolution);
    });

    test('a kind nobody knows is refused rather than guessed at', () {
      // A delay is the one kind that entitles nobody to anything, so an
      // unreadable kind quietly becoming one is the worst available default.
      expect(
        () => DeclareDisruptionRequest.fromJson({
          'kind': 'volcano',
          'cause': 'weather',
        }),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('a cause nobody knows becomes "other"', () {
      // The asymmetry is the point: the cause feeds statistics and the kind
      // decides entitlements. A slightly wrong chart is not a passenger told
      // the wrong thing.
      final back = DeclareDisruptionRequest.fromJson({
        'kind': 'cancellation',
        'cause': 'locusts',
      });
      expect(back.cause, DisruptionCause.other);
    });

    test('what the passenger is sent carries keys, never prose', () {
      final dto = DisruptionDto(
        id: 'd-1',
        kind: DisruptionKind.delay,
        cause: DisruptionCause.checkpoint,
        declaredAt: t0,
        marksInvoluntary: false,
        revisedDepartsAt: t0.add(const Duration(minutes: 40)),
      );

      // ADR-0008: the server emits keys and the client renders the sentence
      // in the reader's own language.
      expect(dto.kindKey, 'disruption.kind.delay');
      expect(dto.causeKey, 'disruption.cause.checkpoint');
      expect(dto.isOpen, isTrue);

      final back = DisruptionDto.fromJson(dto.toJson());
      expect(back.revisedDepartsAt, dto.revisedDepartsAt);
      expect(back.marksInvoluntary, isFalse);
    });

    test('a booking carries what is happening to its coach', () {
      final json = BookingDto(
        id: 'b-1',
        ref: 'BEL-7QK4M2',
        state: 'confirmed',
        departureId: 'dep-1',
        operatorName: 'Océan du Nord',
        originCity: 'BZV',
        destinationCity: 'PNR',
        departsAt: t0,
        arrivesAt: t0.add(const Duration(hours: 8)),
        passengers: const [PassengerDto(fullName: 'Aline M.')],
        total: const Money.xaf(9300),
        createdAt: t0,
        involuntaryChange: true,
        disruption: DisruptionDto(
          id: 'd-1',
          kind: DisruptionKind.breakdownEnRoute,
          cause: DisruptionCause.mechanical,
          declaredAt: t0,
          marksInvoluntary: true,
        ),
      ).toJson();

      final back = BookingDto.fromJson(json);
      expect(back.disruption!.kind, DisruptionKind.breakdownEnRoute);
      // Two different questions: what this traveller is entitled to, and what
      // is happening to their coach.
      expect(back.involuntaryChange, isTrue);
    });

    test('a booking with nothing wrong carries no disruption', () {
      final json = BookingDto(
        id: 'b-1',
        ref: 'BEL-7QK4M2',
        state: 'confirmed',
        departureId: 'dep-1',
        operatorName: 'Océan du Nord',
        originCity: 'BZV',
        destinationCity: 'PNR',
        departsAt: t0,
        arrivesAt: t0.add(const Duration(hours: 8)),
        passengers: const [PassengerDto(fullName: 'Aline M.')],
        total: const Money.xaf(9300),
        createdAt: t0,
      ).toJson();

      expect(json.containsKey('disruption'), isFalse);
      expect(BookingDto.fromJson(json).disruption, isNull);
    });

    test('a rescue reports who moved, and who did not', () {
      final applied = const RescueAppliedDto(
        departureId: 'dep-1',
        registration: 'ODN-902',
        moves: [
          SeatMoveDto(from: '1A', to: '1A'),
          SeatMoveDto(from: '1D', to: '1E'),
        ],
        passengersTold: 2,
        ticketsReissued: 1,
        holdsReleased: 1,
      );

      // The unchanged seats travel too. A dispatcher reading "1 moved" needs
      // the other one accounted for before they will believe it — and a
      // client that counted the list would report both.
      final back = RescueAppliedDto.fromJson(applied.toJson());
      expect(back.moves, hasLength(2));
      expect(back.moved, 1);
      expect(back.moves.first.isUnchanged, isTrue);
      expect(back.holdsReleased, 1);
    });

    test('a rescue with no coach named is refused', () {
      // The one field the server cannot guess. A swap onto "whatever is
      // free" is a swap onto a coach nobody has looked at.
      expect(
        () => RescueCoachRequest.fromJson({'note': 'le car de secours'}),
        throwsA(isA<WireFormatException>()),
      );
    });
  });

  group('nulls are omitted', () {
    test('absent optional fields do not travel', () {
      // Absent and null mean the same thing to every client, and omitting
      // them is meaningfully fewer bytes on a metered prepaid bundle.
      final json = const PassengerDto(fullName: 'Aline M.').toJson();
      expect(json.keys, ['fullName']);
    });
  });
}

/// Reads the string constants declared on [ErrorCode] straight from source,
/// so the test cannot drift from the class by being updated separately.
Set<String> _errorCodeConstants() {
  final file =
      [
        File('lib/src/error/error_code.dart'),
        File('packages/bel_contracts/lib/src/error/error_code.dart'),
      ].firstWhere(
        (f) => f.existsSync(),
        orElse: () => throw StateError('cannot locate error_code.dart'),
      );

  // `\s*` around the `=` so a declaration wrapped across two lines by the
  // formatter is still seen. Without it this guard quietly under-reports.
  return RegExp(
    r"static const \w+\s*=\s*'([^']+)';",
  ).allMatches(file.readAsStringSync()).map((m) => m.group(1)!).toSet();
}
