/// What both back offices share above the gateway.
///
/// The operator console and the admin app are separate binaries with separate
/// navigation and separate ports, and that separation is deliberate. Their
/// **way in** is not: both are staffed surfaces, both are obliged to hold a
/// second factor, and two implementations of that obligation is two chances
/// for one of them to forget the enrolment gate and quietly let somebody
/// through.
library;

export 'src/back_office_sign_in.dart';
export 'src/second_factor_enrolment.dart';
