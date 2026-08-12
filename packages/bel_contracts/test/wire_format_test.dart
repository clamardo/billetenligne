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

    // A card rail is not pushed to a handset, so the two fields a wallet
    // payment cannot do without are exactly the two a card payment has no
    // value for. The wire format has to allow both shapes, and an old client
    // reading a new response must not see a card rail as a broken wallet.
    test('a card option carries no wallet to debit', () {
      const card = PaymentOptionDto(
        railId: 'cg.card',
        operatorId: 'psp',
        labelKey: 'enum.PaymentRailKind.card',
        collectionMsisdn: '',
        collectionName: '',
        hostedCheckout: true,
      );

      final back = roundTrip(card.toJson, PaymentOptionDto.fromJson);
      expect(back.hostedCheckout, isTrue);
      expect(back.collectionMsisdn, isEmpty);
    });

    test('a wallet option says nothing about checkouts', () {
      const wallet = PaymentOptionDto(
        railId: 'cg.mtn_momo',
        operatorId: 'mtn',
        labelKey: 'enum.MobileOperator.mtn',
        collectionMsisdn: '242060000001',
        collectionName: 'Ocean du Nord',
      );

      // Absent rather than `false`: every rail before the card one was a
      // wallet, and a field only the exception carries is a field nobody has
      // to migrate.
      expect(wallet.toJson().containsKey('hostedCheckout'), isFalse);
      expect(
        PaymentOptionDto.fromJson(wallet.toJson()).hostedCheckout,
        isFalse,
      );
    });

    test('a card payment names where to come back to, and no payer', () {
      const request = StartPaymentRequest(
        bookingId: 'bk-1',
        railId: 'cg.card',
        returnUrl: 'billetenligne://payment/return',
      );

      final json = request.toJson();
      expect(json.containsKey('payerMsisdn'), isFalse);

      final back = StartPaymentRequest.fromJson(json);
      expect(back.payerMsisdn, isNull);
      expect(back.returnUrl, 'billetenligne://payment/return');
    });

    test('the page to open travels on the intent', () {
      final intent = PaymentIntent(
        id: 'pi1',
        bookingId: 'b1',
        railId: 'cg.card',
        amount: const Money.xaf(9300),
        idempotencyKey: 'k',
        createdAt: t0,
        state: PaymentState.pending,
      );
      final back = roundTrip(
        PaymentIntentDto.fromDomain(
          intent,
          redirectUrl: 'https://checkout.invalid/pay/pi1',
        ).toJson,
        PaymentIntentDto.fromJson,
      );

      expect(back.redirectUrl, 'https://checkout.invalid/pay/pi1');
      // Still an ordinary in-flight intent: the outcome is settled by asking
      // the server, never by whether a browser came back (ADR-0005).
      expect(back.isInFlight, isTrue);
      expect(back.pollAfterSeconds, 5);
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

    test('a wave reports who is still standing at the roadside', () {
      final applied = RebookingAppliedDto(
        departureId: 'dep-1',
        replacementDepartureId: 'dep-2',
        replacementDepartsAt: t0.add(const Duration(hours: 8)),
        moved: const [
          RebookedPartyDto(
            bookingId: 'b-1',
            ref: 'BEL-7QK4M2',
            seatLabels: ['3A', '3B'],
          ),
        ],
        passengersMoved: 18,
        passengersLeft: 24,
      );

      final back = RebookingAppliedDto.fromJson(applied.toJson());
      expect(back.passengersLeft, 24);
      expect(back.coversEverybody, isFalse);
      expect(back.moved.single.seatLabels, ['3A', '3B']);
      expect(back.replacementDepartsAt, applied.replacementDepartsAt);
    });

    test('a wave that covered everybody still says so out loud', () {
      // Zero travels rather than being omitted. A client inferring "nobody
      // left" from a missing field will one day infer it from a field that
      // was dropped for a different reason.
      final json = RebookingAppliedDto(
        departureId: 'dep-1',
        replacementDepartureId: 'dep-2',
        replacementDepartsAt: t0,
        moved: const [],
        passengersMoved: 42,
        passengersLeft: 0,
      ).toJson();

      expect(json['passengersLeft'], 0);
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

  group('a statement on the wire', () {
    PayoutRunDto run({int net = 3516000}) => PayoutRunDto(
      id: 'p-1',
      operatorId: 'op-1',
      operatorName: 'Océan du Nord',
      periodStart: t0,
      periodEnd: t0.add(const Duration(days: 7)),
      onlineSalesCount: 412,
      onlineGross: const Money.xaf(3708000),
      cashSalesCount: 188,
      cashGross: const Money.xaf(1692000),
      commission: const Money.xaf(185400),
      serviceFees: const Money.xaf(180000),
      refunds: const Money.xaf(126000),
      payable: const Money.xaf(3708000),
      tills: const Money.xaf(192000),
      net: Money.xaf(net),
      state: 'approved',
      preparedAt: t0,
      destination: 'MoMo ****4471',
    );

    test('the cash sales travel, even though they are never paid out', () {
      // "Where is my cash money?" is the first question an operator asks
      // about a statement, every time. Omitting the line that answers it
      // would generate the phone call the statement exists to prevent.
      final back = PayoutRunDto.fromJson(run().toJson());

      expect(back.cashSalesCount, 188);
      expect(back.cashGross, const Money.xaf(1692000));
      expect(back.tills, const Money.xaf(192000));
    });

    test('the net is signed, and a reader can check it', () {
      // Both halves of the difference travel. A reader who cannot see the
      // payable and the tills cannot verify the number they are being paid.
      final back = PayoutRunDto.fromJson(run().toJson());
      expect(back.payable.minor - back.tills.minor, back.net.minor);
      expect(back.isPayable, isTrue);

      final owing = PayoutRunDto.fromJson(run(net: -54000).toJson());
      expect(owing.operatorOwesUs, isTrue);
      expect(owing.isPayable, isFalse);
    });

    test('a run nobody has paid yet carries no payment date', () {
      final json = run().toJson();
      expect(json.containsKey('paidAt'), isFalse);
      expect(PayoutRunDto.fromJson(json).paidAt, isNull);
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

  group('changing departure on the wire', () {
    ChangeOptionDto row({
      int fare = 9000,
      int? fee,
      int? difference,
      int? owed,
      String? refusalCode,
      Map<String, Object?> refusalParams = const {},
    }) => ChangeOptionDto(
      departureId: 'dep-later',
      departsAt: DateTime.utc(2026, 8, 11, 14),
      arrivesAt: DateTime.utc(2026, 8, 11, 22),
      fare: Money(fare, Currency.xaf),
      seatsAvailable: 12,
      fee: fee == null ? null : Money(fee, Currency.xaf),
      fareDifference: difference == null
          ? null
          : Money(difference, Currency.xaf),
      owed: owed == null ? null : Money(owed, Currency.xaf),
      refusalCode: refusalCode,
      refusalParams: refusalParams,
    );

    test('a priced row survives the round trip whole', () {
      final back = ChangeOptionDto.fromJson(
        row(fare: 10500, fee: 900, difference: 1500, owed: 2400).toJson(),
      );

      // §8.1 wants all three on the row before selection, and all three are
      // separate numbers: a traveller reading "+2 400" wants to know how much
      // of it is the operator's fee.
      expect(back.fee, const Money.xaf(900));
      expect(back.fareDifference, const Money.xaf(1500));
      expect(back.owed, const Money.xaf(2400));
      expect(back.isFree, isFalse);
      expect(back.isTakeable, isTrue);
    });

    test('a free row keeps its zeroes rather than dropping them', () {
      final back = ChangeOptionDto.fromJson(
        row(fee: 0, difference: 0, owed: 0).toJson(),
      );

      // `Wire.compact` drops nulls, not zeroes. A zero that vanished would
      // read as "not priced" and the row would render its fare instead.
      expect(back.owed, const Money.xaf(0));
      expect(back.isFree, isTrue);
    });

    test('a refused row carries its reason and its numbers', () {
      final back = ChangeOptionDto.fromJson(
        row(
          refusalCode: 'change.does_not_fit',
          refusalParams: const {'needed': 3, 'available': 2},
        ).toJson(),
      );

      expect(back.isTakeable, isFalse);
      expect(back.refusalParams['available'], 2);
    });

    test('the screen carries its terms and its party size', () {
      final back = ChangeOptionsDto.fromJson(
        ChangeOptionsDto(
          bookingRef: 'BEL-7QK4M2',
          originCity: 'BZV',
          destinationCity: 'PNR',
          seatsNeeded: 3,
          currentDepartureId: 'dep-now',
          currentDepartsAt: DateTime.utc(2026, 8, 11, 6),
          paidFare: const Money.xaf(9000),
          options: [row(fee: 0, difference: 0, owed: 0)],
          policyLines: ChangePolicy.standard.describe(),
        ).toJson(),
      );

      expect(back.seatsNeeded, 3);
      expect(back.options, hasLength(1));
      expect(back.policyLines, contains('policy.change.free|24'));
      expect(back.isOpen, isTrue);
    });

    test('a closed window travels as one refusal, not as empty rows', () {
      final back = ChangeOptionsDto.fromJson(
        ChangeOptionsDto(
          bookingRef: 'BEL-7QK4M2',
          originCity: 'BZV',
          destinationCity: 'PNR',
          seatsNeeded: 1,
          currentDepartureId: 'dep-now',
          currentDepartsAt: DateTime.utc(2026, 8, 11, 6),
          paidFare: const Money.xaf(9000),
          options: const [],
          refusalCode: 'change.too_late',
          refusalParams: const {'hours': 2},
        ).toJson(),
      );

      // The difference matters on screen: no rows plus no reason is a blank
      // page somebody reads as a bug.
      expect(back.isOpen, isFalse);
      expect(back.refusalParams['hours'], 2);
    });

    test('the receipt names the new seats', () {
      final back = ChangeAppliedDto.fromJson(
        ChangeAppliedDto(
          bookingRef: 'BEL-7QK4M2',
          departureId: 'dep-later',
          departsAt: DateTime.utc(2026, 8, 11, 14),
          seatLabels: const ['3C', '3D'],
        ).toJson(),
      );

      expect(back.seatLabels, ['3C', '3D']);
      expect(back.departsAt, DateTime.utc(2026, 8, 11, 14));
    });
  });

  group('cancelling on the wire', () {
    CancellationOfferDto roundTrip(CancellationOfferDto offer) =>
        CancellationOfferDto.fromJson(offer.toJson());

    final base = CancellationOfferDto(
      bookingRef: 'BEL-7QK4M2',
      kind: 'claimAtCounter',
      departsAt: DateTime.utc(2026, 8, 11, 6),
      originCity: 'BZV',
      destinationCity: 'PNR',
      seatCount: 2,
      fare: const Money.xaf(18000),
      serviceFee: const Money.xaf(600),
      refundable: const Money.xaf(16200),
      retained: const Money.xaf(2400),
      rateBps: 9000,
      policyLines: const ['policy.line.tierFull|24'],
    );

    test('an offer survives the round trip whole', () {
      final back = roundTrip(base);

      expect(back.kind, 'claimAtCounter');
      expect(back.refundable, const Money.xaf(16200));
      expect(back.retained, const Money.xaf(2400));
      expect(back.seatCount, 2);
      expect(back.policyLines, ['policy.line.tierFull|24']);
      expect(back.owesMoney, isTrue);
      expect(back.isPossible, isTrue);
    });

    test('a release owes nothing, and says so rather than quoting zero', () {
      final back = roundTrip(
        CancellationOfferDto(
          bookingRef: base.bookingRef,
          kind: 'release',
          departsAt: base.departsAt,
          originCity: base.originCity,
          destinationCity: base.destinationCity,
          seatCount: 1,
          fare: base.fare,
          serviceFee: base.serviceFee,
        ),
      );

      // The difference the screen turns on: no refundable field at all, not a
      // refundable of nought.
      expect(back.owesMoney, isFalse);
      expect(back.refundable, isNull);
    });

    test('a refusal carries a code and no kind', () {
      final back = roundTrip(
        CancellationOfferDto(
          bookingRef: base.bookingRef,
          kind: null,
          departsAt: base.departsAt,
          originCity: base.originCity,
          destinationCity: base.destinationCity,
          seatCount: 1,
          fare: base.fare,
          serviceFee: base.serviceFee,
          refusalCode: 'cancel.coach_has_left',
        ),
      );

      expect(back.isPossible, isFalse);
      expect(back.refusalCode, 'cancel.coach_has_left');
    });

    test('zero back is a real answer and survives as one', () {
      final back = roundTrip(
        CancellationOfferDto(
          bookingRef: base.bookingRef,
          kind: 'claimAtCounter',
          departsAt: base.departsAt,
          originCity: base.originCity,
          destinationCity: base.destinationCity,
          seatCount: 1,
          fare: base.fare,
          serviceFee: base.serviceFee,
          refundable: const Money.xaf(0),
          givesNothingBack: true,
        ),
      );

      // `Wire.compact` drops nulls, not zeroes — a refundable of nought that
      // vanished on the wire would render as "nothing was paid".
      expect(back.refundable, const Money.xaf(0));
      expect(back.givesNothingBack, isTrue);
    });

    test('the receipt carries the code and when it dies', () {
      final done = CancellationDoneDto.fromJson(
        CancellationDoneDto(
          bookingRef: 'BEL-7QK4M2',
          kind: 'claimAtCounter',
          refunded: const Money.xaf(16200),
          claimCode: 'K7M2QRTV',
          claimExpiresAt: DateTime.utc(2026, 11, 9),
        ).toJson(),
      );

      expect(done.claimCode, 'K7M2QRTV');
      expect(done.claimExpiresAt, DateTime.utc(2026, 11, 9));
      expect(done.refunded, const Money.xaf(16200));
    });

    test('a release receipt carries no money at all', () {
      final done = CancellationDoneDto.fromJson(
        const CancellationDoneDto(
          bookingRef: 'BEL-7QK4M2',
          kind: 'release',
        ).toJson(),
      );

      expect(done.refunded, isNull);
      expect(done.claimCode, isNull);
    });
  });

  group('a change waiting to be paid for', () {
    test('the order survives the wire, applied half and all', () {
      final dto = ChangeOrderDto(
        id: 'chg-1',
        bookingId: 'bk-1',
        bookingRef: 'BEL-7QK4M2',
        departureId: 'dep-2',
        departsAt: DateTime.utc(2026, 8, 12, 14),
        owed: Money(2400, Currency.xaf),
        expiresAt: DateTime.utc(2026, 8, 11, 6, 15),
        state: 'awaiting_payment',
        fee: Money(900, Currency.xaf),
        fareDifference: Money(1500, Currency.xaf),
        seatLabels: const ['5A', '5B'],
      );

      final back = ChangeOrderDto.fromJson(
        jsonDecode(jsonEncode(dto.toJson())) as Map<String, Object?>,
      );

      expect(back.owed, const Money.xaf(2400));
      expect(back.fee, const Money.xaf(900));
      expect(back.fareDifference, const Money.xaf(1500));
      expect(back.seatLabels, ['5A', '5B']);
      expect(back.isAwaitingPayment, isTrue);
      expect(back.applied, isNull);
    });

    // The price fell between the list and the tap, so there was never a
    // promise to keep — only a movement that happened.
    test('an order that owed nothing carries what it did', () {
      final dto = ChangeOrderDto(
        id: '',
        bookingId: 'bk-1',
        bookingRef: 'BEL-7QK4M2',
        departureId: 'dep-2',
        departsAt: DateTime.utc(2026, 8, 12, 14),
        owed: Money(0, Currency.xaf),
        expiresAt: DateTime.utc(2026, 8, 11, 6),
        state: 'applied',
        applied: ChangeAppliedDto(
          bookingRef: 'BEL-7QK4M2',
          departureId: 'dep-2',
          departsAt: DateTime.utc(2026, 8, 12, 14),
          seatLabels: const ['5A'],
        ),
      );

      final back = ChangeOrderDto.fromJson(
        jsonDecode(jsonEncode(dto.toJson())) as Map<String, Object?>,
      );

      expect(back.isApplied, isTrue);
      expect(back.applied!.seatLabels, ['5A']);
    });

    // A client names *which* debt and never *how much*: the amount comes from
    // the order's own row inside the transaction that opens the intent.
    test('a payment request can name a change, and carries no amount', () {
      final request = const StartPaymentRequest(
        bookingId: 'bk-1',
        railId: 'cg.fake_money',
        payerMsisdn: '242061234567',
        changeId: 'chg-1',
      );

      final json = request.toJson();
      expect(json['changeId'], 'chg-1');
      expect(json.keys, isNot(contains('amount')));
      expect(StartPaymentRequest.fromJson(json).changeId, 'chg-1');

      // And an ordinary fare says nothing about changes at all.
      final plain = const StartPaymentRequest(
        bookingId: 'bk-1',
        railId: 'cg.fake_money',
        payerMsisdn: '242061234567',
      ).toJson();
      expect(plain.containsKey('changeId'), isFalse);
    });

    test('the list carries the order the traveller already holds', () {
      final screen = ChangeOptionsDto(
        bookingRef: 'BEL-7QK4M2',
        originCity: 'BZV',
        destinationCity: 'PNR',
        seatsNeeded: 2,
        currentDepartureId: 'dep-1',
        currentDepartsAt: DateTime.utc(2026, 8, 12, 5),
        paidFare: const Money(9000, Currency.xaf),
        options: const [],
        pending: ChangeOrderDto(
          id: 'chg-1',
          bookingId: 'bk-1',
          bookingRef: 'BEL-7QK4M2',
          departureId: 'dep-2',
          departsAt: DateTime.utc(2026, 8, 12, 14),
          owed: const Money(2400, Currency.xaf),
          expiresAt: DateTime.utc(2026, 8, 11, 6, 15),
          state: 'awaiting_payment',
          seatLabels: const ['5A', '5B'],
        ),
      );

      final back = ChangeOptionsDto.fromJson(
        jsonDecode(jsonEncode(screen.toJson())) as Map<String, Object?>,
      );

      expect(back.pending!.id, 'chg-1');
      expect(back.pending!.owed, const Money.xaf(2400));
      expect(back.pending!.isAwaitingPayment, isTrue);
    });

    test('and says nothing at all when there is none', () {
      final screen = ChangeOptionsDto(
        bookingRef: 'BEL-7QK4M2',
        originCity: 'BZV',
        destinationCity: 'PNR',
        seatsNeeded: 1,
        currentDepartureId: 'dep-1',
        currentDepartsAt: DateTime.utc(2026, 8, 12, 5),
        paidFare: const Money(9000, Currency.xaf),
        options: const [],
      );

      // Absent rather than null: nearly every one of these screens has no
      // order behind it, and `Wire.compact` keeps the payload small.
      expect(screen.toJson().containsKey('pending'), isFalse);
      expect(ChangeOptionsDto.fromJson(screen.toJson()).pending, isNull);
    });
  });

  group('the terms an operator writes', () {
    test('the change terms ride on the policy, and survive the round trip', () {
      final dto = RefundPolicyDto.fromDomain(
        RefundPolicy.standard(),
        name: 'Maison',
        isDefault: true,
        change: const ChangePolicy(
          freeBefore: Duration(hours: 48),
          feeBps: 1500,
          cutoff: Duration(hours: 6),
        ),
      );

      final back = RefundPolicyDto.fromJson(
        jsonDecode(jsonEncode(dto.toJson())) as Map<String, Object?>,
      );

      expect(back.change.freeBeforeHours, 48);
      expect(back.change.feeBps, 1500);
      expect(back.change.cutoffHours, 6);
      // Rendered by the domain on both ends, never sent as prose.
      expect(back.changeToDomain().describe().first, 'policy.change.free|48');
    });

    // A server that predates 0025 answers without the block. The right
    // assumption is D-08's numbers, because that is what every policy stored
    // before the columns existed has in fact been behaving as.
    test('an absent change block is the platform default, not nothing', () {
      final json = {
        'id': 'p-1',
        'version': 3,
        'name': 'Maison',
        'tiers': <Object?>[],
        'destination': 'agencyCash',
        'processingHours': 72,
        'refundServiceFee': false,
        'nonRefundableFares': <Object?>[],
        'isDefault': true,
      };

      final dto = RefundPolicyDto.fromJson(json);

      expect(dto.change.freeBeforeHours, 24);
      expect(dto.change.feeBps, 1000);
      expect(dto.change.cutoffHours, 2);
      expect(dto.changeToDomain().isWellFormed, isTrue);
    });
  });

  group('the funnel', () {
    FunnelDayDto day(
      String d, {
      int held = 0,
      int reserved = 0,
      int paid = 0,
      int lapsed = 0,
      int failed = 0,
    }) => FunnelDayDto(
      day: d,
      held: held,
      reserved: reserved,
      paid: paid,
      holdsLapsed: lapsed,
      paymentsFailed: failed,
    );

    test('a quiet day has no rate at all, rather than nought percent', () {
      final quiet = day('2026-08-09');

      expect(quiet.holdToReservation, isNull);
      expect(quiet.reservationToPaid, isNull);
      expect(quiet.holdToPaid, isNull);
    });

    test('the rates are of the step before, not of the top', () {
      final d = day('2026-08-09', held: 40, reserved: 20, paid: 15);

      expect(d.holdToReservation, 50);
      // 15 of 20 booked, not 15 of 40 held: the second rate answers "of the
      // people who got as far as a booking, how many paid".
      expect(d.reservationToPaid, 75);
      expect(d.holdToPaid, 38);
    });

    test('the worst day-over-day fall is what the alert fires on', () {
      // Newest first, as the server sends it: 60% on the 10th, 90% on the 9th.
      final funnel = FunnelDto(
        days: [
          day('2026-08-10', held: 10, paid: 6, reserved: 8),
          day('2026-08-09', held: 10, paid: 9, reserved: 10),
          day('2026-08-08', held: 10, paid: 8, reserved: 9),
        ],
      );

      expect(funnel.worstDrop, 30);
    });

    test('a rise is not a fall, and a quiet day breaks no comparison', () {
      final climbing = FunnelDto(
        days: [
          day('2026-08-10', held: 10, reserved: 10, paid: 9),
          day('2026-08-09'),
          day('2026-08-08', held: 10, reserved: 10, paid: 4),
        ],
      );

      // The 9th carries no figure, so it is skipped rather than read as a
      // collapse to zero and a recovery — which is what a naive chart draws.
      expect(climbing.worstDrop, isNull);
    });

    test('the day survives the round trip as a date, not an instant', () {
      final sent = FunnelDto(
        days: [day('2026-08-10', held: 3, reserved: 2, paid: 1, lapsed: 1)],
        operatorId: 'op-1',
      );

      final back = FunnelDto.fromJson(sent.toJson());

      expect(back.days.single.day, '2026-08-10');
      expect(back.days.single.holdsLapsed, 1);
      expect(back.countsFrom, 'hold');
      expect(back.operatorId, 'op-1');
    });
  });

  group('paging the results', () {
    // Pagination. A cursor is the server's own bookmark handed back to it,
    // and the only thing a client may do with it is return it.
    test('a cursor survives the round trip it was built for', () {
      final cursor = SearchCursor(
        departsAt: DateTime.utc(2026, 8, 15, 6, 30),
        id: 'dep-1',
      );

      final back = SearchCursor.decode(cursor.encode());
      expect(back.departsAt, DateTime.utc(2026, 8, 15, 6, 30));
      expect(back.id, 'dep-1');
    });

    test('a cursor carries the row as well as the minute', () {
      // Two companies scheduling the 06:00 on the same road is the ordinary
      // case here. A cursor holding only the instant drops one of them.
      final a = SearchCursor(
        departsAt: DateTime.utc(2026, 8, 15, 6),
        id: 'dep-a',
      ).encode();
      final b = SearchCursor(
        departsAt: DateTime.utc(2026, 8, 15, 6),
        id: 'dep-b',
      ).encode();

      expect(a, isNot(b));
    });

    test('a cursor nobody minted is refused, not ignored', () {
      // Falling back to the first page is how a client scrolls forever
      // without ever noticing it is reading the same rows.
      expect(
        () => SearchCursor.decode('not-a-cursor'),
        throwsA(isA<WireFormatException>()),
      );
      expect(
        () => SearchCursor.decode(''),
        throwsA(isA<WireFormatException>()),
      );
    });

    test('a cursor is safe in a query string', () {
      final encoded = SearchCursor(
        departsAt: DateTime.utc(2026, 8, 15, 6),
        id: 'dep-1',
      ).encode();

      // Base64url and unpadded: `+`, `/` and `=` all mean something else in a
      // URL, and a cursor that had to be escaped would be one every client
      // has to remember to escape.
      expect(encoded, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    });

    test('a page says whether there is another one', () {
      const page = TripPageDto(items: [], nextCursor: 'abc');
      expect(page.hasMore, isTrue);
      expect(TripPageDto.fromJson(page.toJson()).nextCursor, 'abc');

      // The last page says nothing rather than saying false: absent is what
      // a client that predates paging already reads as "no more".
      const last = TripPageDto(items: []);
      expect(last.hasMore, isFalse);
      expect(last.toJson().containsKey('nextCursor'), isFalse);
    });

    test('the search query carries the page it is asking for', () {
      final first = SearchDeparturesQuery(
        originCity: 'BZV',
        destinationCity: 'PNR',
        date: DateTime.utc(2026, 8, 15),
        passengers: 2,
      );

      expect(first.toQuery().containsKey('cursor'), isFalse);

      final next = first.nextPage('abc');
      // Everything else is carried across: a second page of a different
      // search is not a second page.
      expect(next.originCity, 'BZV');
      expect(next.passengers, 2);
      expect(next.toQuery()['cursor'], 'abc');
      expect(SearchDeparturesQuery.fromQuery(next.toQuery()).cursor, 'abc');
    });
  });

  group('the yard', () {
    test('a terminal survives the round trip, directions included', () {
      const sent = StationDto(
        id: 'st-1',
        cityCode: 'BZV',
        name: 'Gare de Mikalou',
        lat: -4.2,
        lng: 15.25,
        boardingNotes: 'Entrée par la rue derrière la station Total',
      );

      final back = StationDto.fromJson(sent.toJson());

      expect(back.name, 'Gare de Mikalou');
      expect(back.cityCode, 'BZV');
      expect(back.boardingNotes, sent.boardingNotes);
      expect(back.hasCoordinates, isTrue);
      expect(back.active, isTrue);
    });

    test('a ticket carries the yard without repeating the city', () {
      final booking = BookingDto(
        id: 'b-1',
        ref: 'BEL-7QK4M2',
        state: 'confirmed',
        departureId: 'd-1',
        operatorName: 'Océan du Nord',
        originCity: 'BZV',
        destinationCity: 'PNR',
        departsAt: DateTime.utc(2026, 8, 20, 5),
        arrivesAt: DateTime.utc(2026, 8, 20, 13),
        passengers: const [],
        total: const Money(12000, Currency.xaf),
        createdAt: DateTime.utc(2026, 8, 19),
        originStation: const StationDto(
          id: 'st-1',
          name: 'Gare de Mikalou',
          boardingNotes: 'Guichet 3',
        ),
      );

      final back = BookingDto.fromJson(booking.toJson());

      expect(back.originStation?.name, 'Gare de Mikalou');
      expect(back.originStation?.boardingNotes, 'Guichet 3');
      // The journey already says Brazzaville. Repeating it under the yard's
      // name is noise on a small screen, so it never leaves the server.
      expect(back.originStation?.cityCode, isNull);
      expect(back.destinationStation, isNull);
    });

    test('a search row with no terminal named says nothing at all', () {
      final row = DepartureSummaryDto(
        id: 'd-1',
        operatorId: 'op-1',
        operatorName: 'Océan du Nord',
        mode: 'bus',
        originCity: 'BZV',
        destinationCity: 'PNR',
        departsAt: DateTime.utc(2026, 8, 20, 5),
        arrivesAt: DateTime.utc(2026, 8, 20, 13),
        fare: const Money(12000, Currency.xaf),
        serviceFee: const Money(500, Currency.xaf),
        seatsAvailable: 12,
        capacity: 52,
        seatSelectionEnabled: true,
      );

      final json = row.toJson();

      // Absent rather than null: `Wire.compact` keeps the payload small, and
      // most rows in this market will never name a yard.
      expect(json.containsKey('originStation'), isFalse);
      expect(DepartureSummaryDto.fromJson(json).originStation, isNull);
    });
  });

  group('the passenger who was late', () {
    test('a priced row survives the round trip, yard and all', () {
      final sent = MissedOptionDto(
        departureId: 'd-9',
        departsAt: DateTime.utc(2026, 8, 10, 8, 30),
        arrivesAt: DateTime.utc(2026, 8, 10, 16),
        fare: const Money(13500, Currency.xaf),
        seatsAvailable: 4,
        stationName: 'Gare de Kinsoundi',
        boardingNotes: 'Guichet 2',
        sameStation: false,
        fee: const Money(3000, Currency.xaf),
        fareDifference: const Money(1500, Currency.xaf),
        owed: const Money(4500, Currency.xaf),
      );

      final back = MissedOptionDto.fromJson(sent.toJson());

      expect(back.stationName, 'Gare de Kinsoundi');
      // The one flag an agent must not misread: this coach leaves from the
      // other side of the city.
      expect(back.sameStation, isFalse);
      expect(back.owed, const Money(4500, Currency.xaf));
      expect(back.isTakeable, isTrue);
      expect(back.isFree, isFalse);
    });

    test('the common case says nothing about the yard being the same', () {
      final row = MissedOptionDto(
        departureId: 'd-9',
        departsAt: DateTime.utc(2026, 8, 10, 8, 30),
        arrivesAt: DateTime.utc(2026, 8, 10, 16),
        fare: const Money(12000, Currency.xaf),
        seatsAvailable: 4,
        owed: const Money(0, Currency.xaf),
      );

      final json = row.toJson();

      // Absent, not `true`: one yard is the ordinary case, and a flag on
      // every row of every screen is bytes on a 2G connection.
      expect(json.containsKey('sameStation'), isFalse);
      final back = MissedOptionDto.fromJson(json);
      expect(back.sameStation, isTrue);
      expect(back.isFree, isTrue);
    });

    test('a coach that cannot be taken says why, and carries no price', () {
      final row = MissedOptionDto(
        departureId: 'd-9',
        departsAt: DateTime.utc(2026, 8, 10, 8, 30),
        arrivesAt: DateTime.utc(2026, 8, 10, 16),
        fare: const Money(12000, Currency.xaf),
        seatsAvailable: 0,
        refusalCode: 'change.does_not_fit',
      );

      final back = MissedOptionDto.fromJson(row.toJson());

      expect(back.isTakeable, isFalse);
      expect(back.owed, isNull);
      expect(back.isFree, isFalse);
    });

    test('the screen carries the terms as keys, never as sentences', () {
      final screen = MissedOptionsDto(
        bookingRef: 'BEL-K4M2QX',
        originCity: 'BZV',
        destinationCity: 'PNR',
        seatsNeeded: 2,
        departedAt: DateTime.utc(2026, 8, 10, 5),
        paidFare: const Money(12000, Currency.xaf),
        options: const [],
        terms: const ['policy.missed.fee|12|25'],
        fromStationName: 'Gare de Mikalou',
      );

      final back = MissedOptionsDto.fromJson(screen.toJson());

      // ADR-0008: the server emits a key and the surface renders it, so the
      // agent reads the company's promise in the company's own words rather
      // than a sentence this DTO invented.
      expect(back.terms.single, 'policy.missed.fee|12|25');
      expect(back.fromStationName, 'Gare de Mikalou');
      expect(back.seatsNeeded, 2);
      expect(back.isPossible, isTrue);
      expect(back.involuntary, isFalse);
    });

    test('nothing can be done, and the reason is a code', () {
      final screen = MissedOptionsDto(
        bookingRef: 'BEL-K4M2QX',
        originCity: 'BZV',
        destinationCity: 'PNR',
        seatsNeeded: 1,
        departedAt: DateTime.utc(2026, 8, 10, 5),
        paidFare: const Money(12000, Currency.xaf),
        options: const [],
        refusalCode: 'missed.not_offered',
      );

      final json = screen.toJson();
      expect(json.containsKey('involuntary'), isFalse);
      expect(json.containsKey('terms'), isFalse);

      final back = MissedOptionsDto.fromJson(json);
      expect(back.isPossible, isFalse);
      expect(back.refusalCode, 'missed.not_offered');
    });

    test('what the counter did survives the round trip', () {
      final done = MissedTransferDto(
        bookingRef: 'BEL-K4M2QX',
        departureId: 'd-9',
        departsAt: DateTime.utc(2026, 8, 10, 8, 30),
        seatLabels: const ['4C', '4D'],
        paid: const Money(2700, Currency.xaf),
        stationName: 'Gare de Kinsoundi',
        boardingNotes: 'Guichet 2',
      );

      final back = MissedTransferDto.fromJson(done.toJson());

      expect(back.seatLabels, ['4C', '4D']);
      expect(back.paid, const Money(2700, Currency.xaf));
      expect(back.stationName, 'Gare de Kinsoundi');
      expect(back.boardingNotes, 'Guichet 2');
    });

    test('terms an operator never wrote are zero and zero', () {
      const policy = MissedPolicyDto();

      expect(policy.toJson(), {'windowHours': 0, 'feeBps': 0});
      // Zero and zero is "not offered", and a policy stored before this
      // field existed answers exactly that.
      expect(MissedPolicyDto.fromJson(const {}).toDomain().isOffered, isFalse);
      expect(
        MissedPolicyDto.fromDomain(
          const MissedPolicy(window: Duration(hours: 12), feeBps: 2500),
        ).toJson(),
        {'windowHours': 12, 'feeBps': 2500},
      );
    });
  });

  group('waiting for a seat', () {
    test('an alert survives the round trip', () {
      final sent = SeatAlertDto(
        id: 'alert-1',
        departureId: 'dep-1',
        seatsWanted: 3,
        createdAt: DateTime.utc(2026, 8, 15, 9, 12),
      );

      final back = SeatAlertDto.fromJson(sent.toJson());

      expect(back.id, 'alert-1');
      expect(back.departureId, 'dep-1');
      expect(back.seatsWanted, 3);
      expect(back.createdAt, DateTime.utc(2026, 8, 15, 9, 12));
      expect(back.isWaiting, isTrue);
    });

    test('a spent alert says when it fired, and is no longer waiting', () {
      // Kept rather than deleted: "I was told, late" and "I was never told"
      // are different complaints, and only a kept row tells them apart.
      final sent = SeatAlertDto(
        id: 'alert-2',
        departureId: 'dep-2',
        seatsWanted: 1,
        createdAt: DateTime.utc(2026, 8, 15, 9),
        notifiedAt: DateTime.utc(2026, 8, 15, 11, 30),
      );

      final back = SeatAlertDto.fromJson(sent.toJson());

      expect(back.notifiedAt, DateTime.utc(2026, 8, 15, 11, 30));
      expect(back.isWaiting, isFalse);
    });

    test('a waiting alert omits the moment it has not reached', () {
      final json = SeatAlertDto(
        id: 'alert-3',
        departureId: 'dep-3',
        seatsWanted: 1,
        createdAt: DateTime.utc(2026, 8, 15),
      ).toJson();

      expect(json.containsKey('notifiedAt'), isFalse);
    });

    test('the request carries the party, not a promise', () {
      // One field, and it is the number that decides whether a message is
      // worth sending at all: a family of four is not served by one seat.
      const request = WatchSeatsRequest(seatsWanted: 4);
      expect(request.toJson(), {'seatsWanted': 4});
      expect(WatchSeatsRequest.fromJson(request.toJson()).seatsWanted, 4);
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
