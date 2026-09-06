import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a role cloned with a subset of the caller\'s own capabilities is fine',
    () {
      final refusal = CustomRoleDefinition.validate(
        name: 'ticket_seller',
        capabilities: const {'booking.read', 'booking.sell'},
        callerCapabilities: const {
          'booking.read',
          'booking.sell',
          'booking.refund',
        },
        callerIsWholeOrg: true,
      );
      expect(refusal, isNull);
    },
  );

  test('a role naming every capability the caller holds is fine', () {
    final refusal = CustomRoleDefinition.validate(
      name: 'shadow_owner',
      capabilities: const {'booking.read', 'booking.sell'},
      callerCapabilities: const {'booking.read', 'booking.sell'},
      callerIsWholeOrg: true,
    );
    expect(refusal, isNull);
  });

  test('a station-scoped caller may never design a role, whatever it asks', () {
    final refusal = CustomRoleDefinition.validate(
      name: 'ticket_seller',
      capabilities: const {'booking.read'},
      callerCapabilities: const {'booking.read'},
      callerIsWholeOrg: false,
    );
    expect(refusal, CustomRoleRefusal.callerNotWholeOrg);
  });

  test('an empty name is refused', () {
    final refusal = CustomRoleDefinition.validate(
      name: '   ',
      capabilities: const {'booking.read'},
      callerCapabilities: const {'booking.read'},
      callerIsWholeOrg: true,
    );
    expect(refusal, CustomRoleRefusal.nameRequired);
  });

  test('a name that collides with a built-in role is refused', () {
    final refusal = CustomRoleDefinition.validate(
      name: 'finance',
      capabilities: const {'booking.read'},
      callerCapabilities: const {'booking.read'},
      callerIsWholeOrg: true,
    );
    expect(refusal, CustomRoleRefusal.nameCollidesWithDefault);
  });

  test('no capabilities at all is refused', () {
    final refusal = CustomRoleDefinition.validate(
      name: 'ticket_seller',
      capabilities: const {},
      callerCapabilities: const {'booking.read'},
      callerIsWholeOrg: true,
    );
    expect(refusal, CustomRoleRefusal.noCapabilities);
  });

  test('a capability the caller does not themselves hold is refused — this is '
      'also how an unknown or mistyped capability string is caught, with no '
      'need to duplicate the Capability universe in this package', () {
    final refusal = CustomRoleDefinition.validate(
      name: 'ticket_seller',
      capabilities: const {'booking.read', 'payout.approve'},
      callerCapabilities: const {'booking.read', 'booking.sell'},
      callerIsWholeOrg: true,
    );
    expect(refusal, CustomRoleRefusal.exceedsOwnCapabilities);
  });
}
