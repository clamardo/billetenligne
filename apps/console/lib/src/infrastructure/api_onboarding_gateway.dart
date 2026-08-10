import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/ports/onboarding_gateway.dart';

/// The real gateway: the shared typed client, nothing more.
final class ApiOnboardingGateway implements OnboardingGateway {
  const ApiOnboardingGateway(this._client);

  final BelApiClient _client;

  @override
  Future<OperatorApplicationDto?> mine() => _client.myApplication();

  @override
  Future<OperatorApplicationDto> start(String legalName) =>
      _client.startApplication(legalName);

  @override
  Future<OperatorApplicationDto> save(ApplicationFacts facts) =>
      _client.saveApplication(facts);

  @override
  Future<OperatorApplicationDto> submit() => _client.submitApplication();
}
