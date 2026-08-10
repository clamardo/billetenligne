import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

/// The self-signup surface, as the console talks to it.
///
/// Separate from `ConsoleGateway` and deliberately so: that one is the
/// tenant's own API and every call on it needs an operator. The applicant has
/// none — that is the entire situation — so folding these four methods into
/// it would put calls that must work without a tenant behind a port whose
/// every other method cannot.
abstract interface class OnboardingGateway {
  /// Null when this account has never applied, which is what almost every
  /// account looks like.
  Future<OperatorApplicationDto?> mine();

  Future<OperatorApplicationDto> start(String legalName);

  Future<OperatorApplicationDto> save(ApplicationFacts facts);

  Future<OperatorApplicationDto> submit();
}
