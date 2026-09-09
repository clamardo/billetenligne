import 'clock.dart';

/// How far a device's own clock sits from the server's, measured at a moment
/// when both could be seen at once.
///
/// **Why this exists.** The rotating code under a ticket is `HMAC(secret,
/// time_window)`, computed on the handset with no network — that is the whole
/// point of it, and it is why a passenger four hours down the RN1 with no
/// signal still shows a live code. What it does need is a roughly correct
/// clock, and a phone's clock is kept correct by NTP or by the cellular
/// network's own time signal. Both of those are exactly what this market's
/// users do not reliably have.
///
/// So a cheap handset that has been out of coverage for a week, or has come
/// back from a flat battery, can be minutes out — against a tolerance of
/// ninety seconds. The passenger is then shown digits that are perfectly
/// correct for a time nobody else is living in.
///
/// The fix is not to widen the tolerance. The tolerance is how long a
/// screenshot stays valid, and widening it trades the defence away in exact
/// proportion. The fix is to stop trusting the device's clock: measure the
/// difference at a moment when we can see both — every HTTP response carries
/// a `Date` — and correct against it afterwards.
///
/// **It can only improve the answer.** An offset that fails [trustedAt] is
/// discarded and the raw device clock is used, which is precisely today's
/// behaviour. Nothing here can strand a passenger who would otherwise have
/// boarded.
final class ClockOffset {
  const ClockOffset({required this.offset, required this.capturedAtDevice});

  /// `serverTime - deviceTime` at the moment of measurement. Positive when the
  /// handset is running slow.
  final Duration offset;

  /// What the **device** believed the time was when this was measured. Kept in
  /// device time on purpose: it is the only scale on which "has this clock
  /// jumped since?" is a question that can be asked at all.
  final DateTime capturedAtDevice;

  /// How stale a measurement may be and still be applied.
  ///
  /// Thirty days, against a sales horizon of twenty-one: a ticket cannot be
  /// bought further out than the horizon, so any offset still in play was
  /// measured inside this window unless the device's clock has been sitting
  /// wrong for longer than the product sells.
  static const maxAge = Duration(days: 30);

  /// Below this, correcting is not worth the risk of carrying a stale
  /// measurement — the tolerance is ±90 s and a handful of seconds is inside
  /// the noise of when the `Date` header was written versus read.
  static const negligible = Duration(seconds: 5);

  /// Whether this measurement should be applied at [deviceNow].
  ///
  /// Two ways to fail, and both are about the clock having *moved* rather than
  /// about the measurement being bad:
  ///
  ///   * **Backwards.** The device now believes it is earlier than when we
  ///     measured. Either the clock was corrected downwards or somebody set it
  ///     by hand; either way the difference we recorded is no longer the
  ///     difference that exists.
  ///   * **Too old.** A measurement older than [maxAge] of device time is
  ///     describing a device that has not spoken to us in longer than we sell
  ///     tickets for.
  bool trustedAt(DateTime deviceNow) {
    if (deviceNow.isBefore(capturedAtDevice)) return false;
    if (deviceNow.difference(capturedAtDevice) > maxAge) return false;
    return true;
  }

  /// The best available reading of the real time.
  ///
  /// Falls back to [deviceNow] untouched whenever the measurement cannot be
  /// trusted, which is the behaviour that existed before this type — so
  /// adopting it is never a regression for anybody.
  DateTime correct(DateTime deviceNow) {
    if (!trustedAt(deviceNow)) return deviceNow;
    if (offset.abs() < negligible) return deviceNow;
    return deviceNow.add(offset);
  }

  /// Measured from a server timestamp and the device's own reading of the same
  /// moment.
  factory ClockOffset.between({
    required DateTime serverTime,
    required DateTime deviceTime,
  }) => ClockOffset(
    offset: serverTime.toUtc().difference(deviceTime.toUtc()),
    capturedAtDevice: deviceTime.toUtc(),
  );

  Map<String, Object?> toJson() => {
    'offsetMs': offset.inMilliseconds,
    'capturedAtDevice': capturedAtDevice.toUtc().toIso8601String(),
  };

  static ClockOffset? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final ms = json['offsetMs'];
    final captured = json['capturedAtDevice'];
    if (ms is! int || captured is! String) return null;
    final at = DateTime.tryParse(captured);
    if (at == null) return null;
    return ClockOffset(
      offset: Duration(milliseconds: ms),
      capturedAtDevice: at.toUtc(),
    );
  }

  @override
  String toString() =>
      'ClockOffset(${offset.inSeconds}s @ ${capturedAtDevice.toIso8601String()})';
}

/// A [Clock] that answers with the server's time rather than the handset's,
/// as far as anybody knows it.
///
/// The offset is read through a callback rather than held, because it is
/// refreshed by **every** response the client receives — including refusals,
/// which carry a `Date` like everything else — and a screen holding a copy
/// taken at build time would keep showing the stale one.
///
/// **The residual, stated rather than hidden.** If a handset's clock is
/// corrected forwards while it is online and no request is made afterwards,
/// the stored measurement is wrong in a way nothing local can detect: a clock
/// that jumped and a week that passed look identical from inside. In practice
/// the correction happens *because* the device found a network, so the next
/// request is usually seconds away — and if it is not, the outcome at the door
/// is an amber `staleCode`, recoverable, with manual boarding behind it.
/// Nobody is left at the roadside by this.
final class CorrectedClock implements Clock {
  const CorrectedClock({
    required Clock device,
    required ClockOffset? Function() offset,
  }) : _device = device,
       _offset = offset;

  final Clock _device;
  final ClockOffset? Function() _offset;

  @override
  DateTime now() {
    final deviceNow = _device.now().toUtc();
    return _offset()?.correct(deviceNow) ?? deviceNow;
  }
}
