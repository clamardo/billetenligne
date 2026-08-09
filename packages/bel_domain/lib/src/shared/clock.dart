/// Time as a dependency, so every policy calculation is testable without
/// waiting for a clock to tick.
abstract interface class Clock {
  DateTime now();
}

final class SystemClock implements Clock {
  const SystemClock();
  @override
  DateTime now() => DateTime.now().toUtc();
}

final class FixedClock implements Clock {
  const FixedClock(this._instant);
  final DateTime _instant;
  @override
  DateTime now() => _instant;
}
