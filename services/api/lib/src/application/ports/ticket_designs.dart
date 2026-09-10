import 'package:bel_contracts/bel_contracts.dart';

/// An operator's printed-ticket stationery.
///
/// One port, three callers, and the third is the reason the other two are
/// worth building: a vendor's till, an operator editing in the console, and
/// the **print route**, which has to resolve a design for a booking whose
/// holder is anonymous and whose link carries no operator credentials.
///
/// Every scope boundary is in the adapter. [forOperator], [save] and [remove]
/// run under the tenant's own scope; [defaultFor] runs under the public one,
/// because the page that needs it is `/b/{token}` and the reader is standing
/// at a counter with no account (ADR-0013). That asymmetry is deliberate and
/// narrow: a design is the company's own branding, already printed on every
/// ticket they hand out, and nothing in it is anybody's private business.
abstract interface class TicketDesigns {
  /// Everything this operator has saved, newest first, defaults first within
  /// a format.
  Future<List<TicketDesignDto>> forOperator(String operatorId);

  /// Creates or updates one, and answers with the stored row.
  ///
  /// Answers with what was *stored* rather than echoing the request: the
  /// design vocabulary is bounded and `TicketDesign.fromJson` drops what it
  /// does not recognise, so the console must be told what is actually live.
  ///
  /// When [SaveTicketDesignRequest.makeDefault] is set, clearing the previous
  /// default for that format happens **in the same transaction**. Two calls
  /// would leave a window in which a till has two defaults or none.
  Future<TicketDesignDto?> save({
    required String operatorId,
    required SaveTicketDesignRequest edit,
  });

  Future<bool> remove({required String operatorId, required String id});

  /// The design a ticket prints in, keyed by the operator's public code.
  ///
  /// **By code, not by id, because of who is calling.** The reader is holding
  /// a link and has no account; `LinkedTicket` carries the code — the same
  /// one on every storefront URL — and not the internal id. Resolving the id
  /// here rather than widening what a link discloses is the smaller change.
  ///
  /// Null when this operator has never saved one, which is most of them most
  /// of the time and is why the starters exist. A counter must be able to
  /// print on its first day.
  Future<TicketDesignDto?> defaultFor({
    required String operatorCode,
    required String format,
  });
}
