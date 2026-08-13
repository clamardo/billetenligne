import 'package:postgres/postgres.dart';

/// The wallet a `source` refund goes back to, or null when there is not one.
///
/// **Read at approval and copied onto the refund**, never read again when the
/// money is sent. The same argument `payout_runs.destination` makes: a
/// traveller who changes handsets on Thursday must not silently redirect
/// Tuesday's approved refund, and a payment row corrected by support must not
/// move money.
///
/// Null is an ordinary answer, not a failure. A ticket bought with notes at a
/// counter has no wallet; a card payment has a PAN this system has never seen
/// and never will. Both are refunded at a counter, and the caller turns a null
/// here into a claim code rather than a row that cannot be paid.
///
/// The **latest captured collection** wins. A booking can have several intents
/// — an abandoned attempt, a retry from a relative's handset, a paid change —
/// and the money should go back to the wallet it last came from, which is the
/// one the person standing there was actually using.
Future<String?> refundWalletFor(TxSession tx, String bookingId) async {
  final rows = await tx.execute(
    Sql.named('''
      SELECT msisdn
        FROM payment_intents
       WHERE booking_id = @booking
         AND direction = 'collect'
         AND state = 'captured'
         AND msisdn IS NOT NULL
         AND msisdn <> ''
       ORDER BY terminal_at DESC NULLS LAST
       LIMIT 1
    '''),
    parameters: {'booking': TypedValue(Type.uuid, bookingId)},
  );
  return rows.isEmpty ? null : rows.first.toColumnMap()['msisdn'] as String?;
}
