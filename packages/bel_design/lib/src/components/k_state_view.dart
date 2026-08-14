import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../art/kilo_art.dart';
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
    this.art = KArt.emptyBox,
  });
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// The picture. Empty is the state a screen spends most of its life in
  /// before it has anything to show, and it is the one most often left as a
  /// grey icon and a sentence — which is exactly the moment somebody decides
  /// the product is unfinished. Pass the drawing that matches the absence:
  /// `noTrips` for a search with no coaches, `noTickets` for a wallet nobody
  /// has bought into yet.
  final KArt art;
}

final class KFailed extends KScreenState {
  const KFailed({
    required this.title,
    this.body,
    this.retryLabel,
    this.onRetry,
    this.traceId,
    this.art = KArt.error,
  });

  final String title;
  final String? body;
  final String? retryLabel;
  final KArt art;

  /// Absent when retrying cannot possibly help. Offering "try again" for a
  /// seat that is genuinely sold is advice that wastes somebody's data.
  final VoidCallback? onRetry;

  /// Shown small, and selectable. It is the one string a support agent needs,
  /// and a traveller can read it down a phone line.
  final String? traceId;
}

final class KOffline extends KScreenState {
  const KOffline({
    required this.title,
    this.body,
    this.retryLabel,
    this.onRetry,
    this.cached,
  });

  final String title;
  final String? body;

  /// Required alongside [onRetry]. It used to be absent, and the view drew a
  /// button with an empty label — a real control, correctly sized, with
  /// nothing written on it, which is worse than no button at all.
  final String? retryLabel;
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
    KEmpty(
      :final title,
      :final body,
      :final actionLabel,
      :final onAction,
      :final art,
    ) =>
      _Centered(
        art: art,
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
      :final art,
    ) =>
      _Centered(
        art: art,
        children: [
          _Title(title),
          if (body != null) _Body(body),
          if (retryLabel != null && onRetry != null)
            _Action(retryLabel, onRetry),
          if (traceId != null) _Trace(traceId),
        ],
      ),
    KOffline(
      :final title,
      :final body,
      :final retryLabel,
      :final onRetry,
      :final cached,
    ) =>
      cached != null
          ? _OfflineBanner(title: title, body: body, child: cached)
          : _Centered(
              art: KArt.offline,
              children: [
                _Title(title),
                if (body != null) _Body(body),
                if (retryLabel != null && onRetry != null)
                  _Action(retryLabel, onRetry),
              ],
            ),
  };
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children, this.art});

  final List<Widget> children;
  final KArt? art;

  /// Below this, the illustration is dropped rather than shrunk. A state
  /// squeezed into a sheet or a half-height panel is one where the words are
  /// the whole point, and a 60 px drawing above them is decoration nobody
  /// asked for.
  static const _artNeeds = 320.0;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : double.infinity;
        final size = math.min(220.0, constraints.maxWidth * 0.62);
        final showArt = art != null && room >= _artNeeds && size >= 120;

        return Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(kilo.space.s6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showArt) ...[
                  KIllustration(art!, size: size),
                  SizedBox(height: kilo.space.s5),
                ],
                ...children,
              ],
            ),
          ),
        );
      },
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
