/// What kind of vehicle operates a departure (ADR-0017).
///
/// v1 exposes [bus] only. [air] exists in the model from day one so the same
/// console configures an aircraft later without a schema migration — the
/// domain is ~85% identical; only boarding, passenger requirements and
/// baggage differ, and those live behind three narrow interfaces.
enum TransportMode { bus, air }
