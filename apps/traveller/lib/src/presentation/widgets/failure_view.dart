import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Renders an [ApiFailure] as something a person can act on.
///
/// The one place the app turns a code into a sentence. Two rules:
///
///   * **Retry is offered only when retrying could work.** A seat that is
///     genuinely sold does not come back because somebody tapped again, and
///     offering the button teaches people that our buttons do nothing.
///   * **The trace id is always shown when we have one.** It is the string a
///     support agent needs, and it is read down a phone line.
final class FailureView extends StatelessWidget {
  const FailureView(
    this.failure, {
    this.onRetry,
    this.alternativeLabel,
    this.onAlternative,
    super.key,
  });

  final ApiFailure failure;
  final VoidCallback? onRetry;

  /// The way forward when retrying cannot help — "choose another seat".
  final String? alternativeLabel;
  final VoidCallback? onAlternative;

  @override
  Widget build(BuildContext context) {
    final params = failure is ServerRefused
        ? (failure as ServerRefused).params
        : const <String, Object?>{};

    final message = context.t(failure.messageKey, params);
    final offerRetry = failure.retryable && onRetry != null;

    if (!offerRetry && onAlternative != null && alternativeLabel != null) {
      return KStateView(
        KFailed(
          title: context.t('common.state.errorTitle'),
          body: message,
          retryLabel: alternativeLabel,
          onRetry: onAlternative,
          traceId: failure.traceId,
        ),
      );
    }

    return KStateView(
      failure is NetworkUnreachable
          ? KOffline(
              title: context.t('common.state.offline'),
              body: message,
              onRetry: onRetry,
            )
          : KFailed(
              title: context.t('common.state.errorTitle'),
              body: message,
              retryLabel: offerRetry ? context.t('common.actions.retry') : null,
              onRetry: offerRetry ? onRetry : null,
              traceId: failure.traceId,
            ),
    );
  }
}
