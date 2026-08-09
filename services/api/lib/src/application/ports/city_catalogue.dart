import 'package:bel_contracts/bel_contracts.dart';

/// The cities this market sells between.
///
/// A port of its own rather than a method on `DepartureCatalogue`, because the
/// two have opposite change profiles: the departure catalogue is the hottest
/// read in the product and changes every minute, while this list changes when
/// an operator opens a new route — which in Congo is a handful of times a
/// year. Conflating them would mean the same cache policy for both, and one of
/// those two answers is safe to cache for a day.
abstract interface class CityCatalogue {
  /// Cities with at least one active route, in the reader's language.
  ///
  /// **Only cities you can actually reach.** A picker that offers a city with
  /// no departures produces an empty result screen, and an empty result screen
  /// after three taps reads as a broken app rather than as a gap in the
  /// network.
  Future<List<CityDto>> servedCities({required String language});
}
