import 'package:bel_contracts/bel_contracts.dart';

import '../../application/ports/city_catalogue.dart';

/// Congo-Brazzaville's intercity network, in a list.
///
/// The fakes composition, and the honest reason it is only six cities: that is
/// how many the network has. This list was hardcoded in the traveller app's
/// `main.dart` until the endpoint existed — moving it here is the point of the
/// slice, because the app must not hold a copy of anything an operator can
/// change.
final class MemoryCityCatalogue implements CityCatalogue {
  const MemoryCityCatalogue();

  static const _cities = <(String, String, String, double, double)>[
    ('BZV', 'Brazzaville', 'Brazzaville', -4.2634, 15.2429),
    ('PNR', 'Pointe-Noire', 'Pointe-Noire', -4.7761, 11.8636),
    ('DLS', 'Dolisie', 'Dolisie', -4.1994, 12.6667),
    ('NKY', 'Nkayi', 'Nkayi', -4.1830, 13.2870),
    ('OWE', 'Owando', 'Owando', -0.4814, 15.8994),
    ('OYO', 'Oyo', 'Oyo', -1.1500, 15.9833),
  ];

  @override
  Future<List<CityDto>> servedCities({required String language}) async => [
    for (final (code, fr, en, lat, lng) in _cities)
      CityDto(
        code: code,
        name: language == 'en' ? en : fr,
        lat: lat,
        lng: lng,
      ),
  ];
}
