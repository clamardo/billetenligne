import 'package:flutter/material.dart';

import '../kilo_theme.dart';
import 'k_button.dart';

/// Every screen defines loading, empty, error, offline **and** success.
/// Four out of five is not done — so the four that are not success live here,
/// in one component, and a screen that forgets one is a screen that will not
/// compile against a sealed switch.
sealed class KScreenState {
  const KScreenState();
}

final class KLoading extends KScreenState {
  const KLoading([this.message]);

  /// Never a naked spinner. A wait with no sentence attached is the fastest
  /// way to make somebody believe the app has frozen, and on 2G the wait is
  /// long enough for them to decide that.
  final String? message;
}

final class KEmpty extends KScreenState {
  const KEmpty({
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;
}

final class KFailed extends KScreenState {
  const KFailed({
    required this.title,
    this.body,
    this.retryLabel,
    this.onRetry,
    this.traceId,
  });

  final String title;
  final String? body;
  final String? retryLabel;

  /// Absent when retrying cannot possibly help. Offering "try again" for a
  /// seat that is genuinely sold is advice that wastes somebody's data.
  final VoidCallback? onRetry;

  /// Shown small, and selectable. It is the one string a support agent needs,
  /// and a traveller can read it down a phone line.
  final String? traceId;
}

final class KOffline extends KScreenState {
  const KOffline({required this.title, this.body, this.onRetry, this.cached});

  final String title;
  final String? body;
  final VoidCallback? onRetry;

  /// What we can still show from the last successful load. Offline does not
  /// mean blank: a ticket bought yesterday must render in a tunnel today.
  final Widget? cached;
}

/// Renders the four non-success states, consistently, everywhere.
final class KStateView extends StatelessWidget {
  const KStateView(this.state, {super.key});

  final KScreenState state;

  @override
  Widget build(BuildContext context) => switch (state) {
    KLoading(:final message) => _Centered(
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        if (message != null) _Body(message),
      ],
    ),
    KEmpty(:final title, :final body, :final actionLabel, :final onAction) =>
      _Centered(
        icon: Icons.search_off,
        children: [
          _Title(title),
          if (body != null) _Body(body),
          if (actionLabel != null && onAction != null)
            _Action(actionLabel, onAction, tone: KButtonTone.secondary),
        ],
      ),
    KFailed(
      :final title,
      :final body,
      :final retryLabel,
      :final onRetry,
      :final traceId,
    ) =>
      _Centered(
        icon: Icons.error_outline,
        tone: _Tone.danger,
        children: [
          _Title(title),
          if (body != null) _Body(body),
          if (retryLabel != null && onRetry != null)
            _Action(retryLabel, onRetry),
          if (traceId != null) _Trace(traceId),
        ],
      ),
    KOffline(:final title, :final body, :final onRetry, :final cached) =>
      cached != null
          ? _OfflineBanner(title: title, body: body, child: cached)
          : _Centered(
              icon: Icons.wifi_off,
              tone: _Tone.warning,
              children: [
                _Title(title),
                if (body != null) _Body(body),
                if (onRetry != null) _Action('', onRetry),
              ],
            ),
  };
}

enum _Tone { neutral, warning, danger }

class _Centered extends StatelessWidget {
  const _Centered({
    required this.children,
    this.icon,
    this.tone = _Tone.neutral,
  });

  final List<Widget> children;
  final IconData? icon;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final colour = switch (tone) {
      _Tone.neutral => kilo.color.contentMuted,
      _Tone.warning => kilo.color.warning,
      _Tone.danger => kilo.color.danger,
    };

    return Center(
      child: Padding(
        padding: EdgeInsets.all(kilo.space.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 40, color: colour),
              SizedBox(height: kilo.space.s4),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, textAlign: TextAlign.center, style: context.kilo.text.h2);
}

class _Body extends StatelessWidget {
  const _Body(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(top: kilo.space.s2),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: kilo.text.body.copyWith(color: kilo.color.contentSecondary),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.label, this.onPressed, {this.tone = KButtonTone.primary});

  final String label;
  final VoidCallback onPressed;
  final KButtonTone tone;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(top: kilo.space.s5),
      child: KButton(
        label: label,
        onPressed: onPressed,
        tone: tone,
        fullWidth: false,
      ),
    );
  }
}

class _Trace extends StatelessWidget {
  const _Trace(this.traceId);
  final String traceId;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(top: kilo.space.s5),
      child: SelectableText(
        traceId,
        style: kilo.text.caption.copyWith(color: kilo.color.contentMuted),
      ),
    );
  }
}

/// Offline **with** something to show: a thin bar above content that is known
/// to be stale, rather than a wall instead of it.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.title, required this.child, this.body});

  final String title;
  final String? body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: kilo.space.s4,
            vertical: kilo.space.s2,
          ),
          color: kilo.color.warningSoft,
          child: Row(
            children: [
              Icon(Icons.wifi_off, size: 16, color: kilo.color.warning),
              SizedBox(width: kilo.space.s2),
              Expanded(
                child: Text(
                  body == null ? title : '$title · $body',
                  style: kilo.text.bodySm.copyWith(color: kilo.color.warning),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
