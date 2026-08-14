import 'dart:convert';
import 'dart:math';

import 'package:bel_api/src/infrastructure/config/ticket_signing_key.dart';
import 'package:test/test.dart';

/// The seed every ticket in this system is signed with.
///
/// The reason these tests exist is that the seed used to be a literal in the
/// adapter and `Services.resolve` handed it to the database composition as
/// readily as to the fakes — so a deployment would have signed real tickets
/// with 32 bytes printed in a public repository, and anybody who could read
/// the source could have minted a ticket for any seat on any coach.
void main() {
  String fresh() =>
      base64Encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));

  final messages = <String>[];
  void announce(String m) => messages.add(m);

  setUp(messages.clear);

  group('a configured seed', () {
    test('is used, whatever else the environment says', () {
      final seed = fresh();
      expect(
        base64Encode(
          TicketSigningKey.from({
            'TICKETS__SIGNINGSEED': seed,
          }, usingDatabase: true),
        ),
        seed,
      );
    });

    test('surrounding whitespace is not part of the key', () {
      final seed = fresh();
      expect(
        TicketSigningKey.from({
          'TICKETS__SIGNINGSEED': '  $seed\n',
        }, usingDatabase: true),
        base64Decode(seed),
      );
    });

    test('a short one is refused rather than padded', () {
      // A seed somebody pasted half of is a key nobody can reproduce, and
      // every ticket signed with it stops verifying the day it is corrected.
      expect(
        () => TicketSigningKey.from({
          'TICKETS__SIGNINGSEED': base64Encode(List.filled(16, 7)),
        }, usingDatabase: true),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('16')),
        ),
      );
    });

    test('a passphrase is refused by name, not decoded to something', () {
      expect(
        () => TicketSigningKey.from({
          'TICKETS__SIGNINGSEED': 'correct horse battery staple',
        }, usingDatabase: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('base64'),
          ),
        ),
      );
    });

    test('the development seed is refused as a value', () {
      // It is in the source. Copying it into a secret manager is the same
      // accident wearing a costume, and naming it is the only way to catch it.
      expect(
        () => TicketSigningKey.from({
          'TICKETS__SIGNINGSEED': base64Encode(TicketSigningKey.development),
        }, usingDatabase: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('forgeable'),
          ),
        ),
      );
    });
  });

  group('no seed at all', () {
    test('a process on a real database refuses to start', () {
      expect(
        () => TicketSigningKey.from(const {}, usingDatabase: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TICKETS__SIGNINGSEED'),
          ),
        ),
      );
    });

    test(
      'and forgetting to say which environment it is fails the same way',
      () {
        // Production is the default on purpose: the variable that has to be set
        // to make a process strict is the variable somebody forgets.
        expect(
          () => TicketSigningKey.from({
            'BEL__ENV': 'staging',
          }, usingDatabase: true),
          throwsStateError,
        );
      },
    );

    test('a local stack says so, and gets the fixed seed', () {
      final seed = TicketSigningKey.from(
        {'BEL__ENV': 'development'},
        usingDatabase: true,
        announce: announce,
      );
      expect(seed, TicketSigningKey.development);
      expect(messages.single, contains('forgeable'));
    });

    test('the fakes composition needs no ceremony and says nothing', () {
      final seed = TicketSigningKey.from(
        const {},
        usingDatabase: false,
        announce: announce,
      );
      expect(seed, TicketSigningKey.development);
      expect(messages, isEmpty);
    });
  });

  test('the development seed is 32 bytes and the same every time', () {
    expect(TicketSigningKey.development, hasLength(32));
    expect(TicketSigningKey.development, TicketSigningKey.development);
  });

  test('nobody can mutate the development seed under another caller', () {
    TicketSigningKey.development[0] = 0xFF;
    expect(TicketSigningKey.development[0], isNot(0xFF));
  });
}
