/// The single result type used across every layer (ADR-0001).
///
/// Hand-rolled rather than pulled from a package: sealed classes give
/// exhaustive `switch` in Dart 3, and the domain stays dependency-free.
sealed class Result<T, F> {
  const Result();

  bool get isOk => this is Ok<T, F>;
  bool get isErr => this is Err<T, F>;

  /// The value, or null when this is an [Err].
  T? get valueOrNull => switch (this) {
    Ok(:final value) => value,
    Err() => null,
  };

  /// The failure, or null when this is an [Ok].
  F? get failureOrNull => switch (this) {
    Ok() => null,
    Err(:final failure) => failure,
  };

  Result<R, F> map<R>(R Function(T) fn) => switch (this) {
    Ok(:final value) => Ok(fn(value)),
    Err(:final failure) => Err(failure),
  };

  Result<R, F> flatMap<R>(Result<R, F> Function(T) fn) => switch (this) {
    Ok(:final value) => fn(value),
    Err(:final failure) => Err(failure),
  };

  R fold<R>(R Function(T) onOk, R Function(F) onErr) => switch (this) {
    Ok(:final value) => onOk(value),
    Err(:final failure) => onErr(failure),
  };
}

final class Ok<T, F> extends Result<T, F> {
  const Ok(this.value);
  final T value;

  @override
  bool operator ==(Object other) => other is Ok<T, F> && other.value == value;
  @override
  int get hashCode => Object.hash('Ok', value);
  @override
  String toString() => 'Ok($value)';
}

final class Err<T, F> extends Result<T, F> {
  const Err(this.failure);
  final F failure;

  @override
  bool operator ==(Object other) =>
      other is Err<T, F> && other.failure == failure;
  @override
  int get hashCode => Object.hash('Err', failure);
  @override
  String toString() => 'Err($failure)';
}
