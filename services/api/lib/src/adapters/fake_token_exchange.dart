import '../application/ports/token_exchange.dart';

/// The exchange, without Google (J11).
///
/// Mirrors the shortcut [FakeAuthGateway] takes: a custom token here comes
/// back as a bearer that same gateway will accept, so a fresh clone can open a
/// cookie session over a real socket with nothing installed.
///
/// **It rotates.** Every refresh answers with a *different* refresh token, the
/// way Firebase does, and refuses the one it replaced. Without that the test
/// that matters here — two tabs must not race to spend one token — would pass
/// against a fake that could not fail.
final class FakeTokenExchange implements TokenExchange {
  FakeTokenExchange({this.expiresIn = const Duration(hours: 1)});

  final Duration expiresIn;

  /// Refresh tokens that are still spendable, to the bearer they belong to.
  final _live = <String, String>{};

  /// Every refresh asked for, so a test can count them. Two tabs waking
  /// together must produce one.
  final refreshes = <String>[];

  /// The refresh tokens still spendable. A test uses this to spend one from
  /// somewhere else, which is what revocation looks like from here.
  List<String> get live => _live.keys.toList();

  var _counter = 0;

  @override
  Future<ExchangedSession> exchangeCustomToken(String customToken) async {
    // `fake:<uid>` in, the same string out as the bearer: the fake auth
    // gateway registers minted tokens as bearers, so this keeps a session
    // resolvable end to end.
    final refresh = 'refresh-${_counter++}';
    _live[refresh] = customToken;
    return ExchangedSession(
      idToken: customToken,
      refreshToken: refresh,
      expiresIn: expiresIn,
    );
  }

  @override
  Future<ExchangedSession> refresh(String refreshToken) async {
    refreshes.add(refreshToken);

    final bearer = _live.remove(refreshToken);
    if (bearer == null) {
      // Spent, or never ours. Firebase answers the same way, and a fake that
      // accepted it twice would hide exactly the bug this exists to catch.
      throw const TokenExchangeRefused('TOKEN_EXPIRED');
    }

    final next = 'refresh-${_counter++}';
    _live[next] = bearer;
    return ExchangedSession(
      idToken: bearer,
      refreshToken: next,
      expiresIn: expiresIn,
    );
  }
}
