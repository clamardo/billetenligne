import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// The vitrine editor: form on the left, live preview on the right.
///
/// **The live preview is the whole point** (`03-operator-lifecycle.md` §2.4).
/// The right-hand pane renders the real widgets — the storefront hero, the
/// search row, the ticket band — so an operator sees exactly what a customer
/// will see *before* saving. Nothing in this product demonstrates the
/// shared-design-system bet better, and nothing sells the platform faster in
/// a room.
///
/// Everything here is bounded, and the bounds are not arbitrary:
///
///   * **eight accents, not a colour picker.** Each is pre-verified for
///     contrast against our surfaces and in direct sun. A free picker
///     guarantees that somebody eventually chooses a yellow that is invisible
///     on their own ticket, at the moment a conductor needs to read it;
///   * **three generated patterns, no photography.** A cover photo is 120 KB
///     on a metered prepaid bundle, and most operators have none usable
///     (ADR-0009);
///   * **30 characters of title, 60 of tagline, in both languages.** Long
///     enough to say something, short enough not to wrap on a 320 dp screen.
///
/// Defaults are good enough to skip: an operator who never opens this screen
/// gets a generated monogram in the house green and their legal name, and
/// still looks maintained rather than abandoned.
final class VitrineScreen extends StatefulWidget {
  const VitrineScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  @override
  State<VitrineScreen> createState() => _VitrineScreenState();
}

class _VitrineScreenState extends State<VitrineScreen> {
  final _titleFr = TextEditingController();
  final _titleEn = TextEditingController();
  final _taglineFr = TextEditingController();
  final _taglineEn = TextEditingController();

  String? _loadedFor;
  var _accent = AccentHue.foret;
  var _pattern = HeaderPattern.flat;

  @override
  void dispose() {
    _titleFr.dispose();
    _titleEn.dispose();
    _taglineFr.dispose();
    _taglineEn.dispose();
    super.dispose();
  }

  /// Fills the form from the server's copy, once per operator.
  ///
  /// Keyed on the operator rather than on "have I run yet", because a refresh
  /// after a save must not overwrite what somebody is in the middle of
  /// typing — and a screen that resets a half-typed tagline every poll is a
  /// screen people stop trusting.
  void _adopt(VitrineDto vitrine) {
    if (_loadedFor == vitrine.operatorId) return;
    _loadedFor = vitrine.operatorId;
    _titleFr.text = vitrine.titleFr ?? '';
    _titleEn.text = vitrine.titleEn ?? '';
    _taglineFr.text = vitrine.taglineFr ?? '';
    _taglineEn.text = vitrine.taglineEn ?? '';
    _accent = AccentHue.byName(vitrine.accentHue);
    _pattern = HeaderPattern.byName(vitrine.headerPattern);
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final vitrine = widget.workspace.vitrine;

    if (vitrine == null) {
      return KStateView(KLoading(context.t('common.state.loading')));
    }
    _adopt(vitrine);

    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final form = _Form(
      state: this,
      vitrine: vitrine,
      canSave: widget.workspace.can('vitrine.manage'),
      onSave: _save,
    );
    final preview = _Preview(
      state: this,
      vitrine: vitrine,
      language: context.language,
    );

    return Padding(
      padding: EdgeInsets.all(kilo.space.s4),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SingleChildScrollView(child: form)),
                SizedBox(width: kilo.space.s5),
                // A fixed pane, because the preview is a phone. Letting it
                // stretch to a laptop's width would preview a screen nobody
                // has.
                SizedBox(
                  width: 360,
                  child: SingleChildScrollView(child: preview),
                ),
              ],
            )
          : ListView(children: [preview, SizedBox(height: kilo.space.s5), form]),
    );
  }

  /// The form and the preview are two widgets over one piece of state, so
  /// they redraw together rather than each holding a copy that can disagree.
  void redraw() => setState(() {});

  void chooseAccent(AccentHue hue) => setState(() => _accent = hue);

  void choosePattern(HeaderPattern pattern) =>
      setState(() => _pattern = pattern);

  void _save() => widget.workspace.saveVitrine(
    SaveVitrineRequest(
      accentHue: _accent.name,
      headerPattern: _pattern.name,
      titleFr: _titleFr.text,
      titleEn: _titleEn.text,
      taglineFr: _taglineFr.text,
      taglineEn: _taglineEn.text,
    ),
  );
}

class _Form extends StatelessWidget {
  const _Form({
    required this.state,
    required this.vitrine,
    required this.canSave,
    required this.onSave,
  });

  final _VitrineScreenState state;
  final VitrineDto vitrine;
  final bool canSave;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('console.vitrine.title'), style: kilo.text.h1),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('console.vitrine.intro'),
          style: kilo.text.body.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s4),

        _LogoField(state: state, vitrine: vitrine, enabled: canSave),
        SizedBox(height: kilo.space.s4),

        _Field(
          label: context.t('console.vitrine.titleFr'),
          controller: state._titleFr,
          max: SaveVitrineRequest.titleMax,
          enabled: canSave,
          hint: vitrine.tradingName ?? vitrine.legalName,
          onChanged: state.redraw,
        ),
        _Field(
          label: context.t('console.vitrine.titleEn'),
          controller: state._titleEn,
          max: SaveVitrineRequest.titleMax,
          enabled: canSave,
          hint: vitrine.tradingName ?? vitrine.legalName,
          onChanged: state.redraw,
        ),
        _Field(
          label: context.t('console.vitrine.taglineFr'),
          controller: state._taglineFr,
          max: SaveVitrineRequest.taglineMax,
          enabled: canSave,
          onChanged: state.redraw,
        ),
        _Field(
          label: context.t('console.vitrine.taglineEn'),
          controller: state._taglineEn,
          max: SaveVitrineRequest.taglineMax,
          enabled: canSave,
          onChanged: state.redraw,
        ),

        SizedBox(height: kilo.space.s4),
        Text(context.t('console.vitrine.accent'), style: kilo.text.label),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('console.vitrine.accentHelp'),
          style: kilo.text.caption.copyWith(
            color: kilo.color.contentSecondary,
          ),
        ),
        SizedBox(height: kilo.space.s2),
        Wrap(
          spacing: kilo.space.s2,
          runSpacing: kilo.space.s2,
          children: [
            for (final hue in AccentHue.values)
              _Swatch(
                hue: hue,
                selected: state._accent == hue,
                label: context.t('console.vitrine.hue.${hue.name}'),
                onTap: canSave ? () => state.chooseAccent(hue) : null,
              ),
          ],
        ),

        SizedBox(height: kilo.space.s4),
        Text(context.t('console.vitrine.pattern'), style: kilo.text.label),
        SizedBox(height: kilo.space.s2),
        Wrap(
          spacing: kilo.space.s2,
          children: [
            for (final pattern in HeaderPattern.values)
              ChoiceChip(
                label: Text(
                  context.t('console.vitrine.patterns.${pattern.name}'),
                ),
                selected: state._pattern == pattern,
                onSelected: canSave
                    ? (_) => state.choosePattern(pattern)
                    : null,
              ),
          ],
        ),

        SizedBox(height: kilo.space.s5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: KButton(
            label: context.t('console.vitrine.save'),
            fullWidth: false,
            onPressed: canSave ? onSave : null,
            disabledHint: context.t('console.vitrine.notAllowed'),
          ),
        ),
      ],
    );
  }
}

/// A text field with a live character count against its limit.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.max,
    required this.enabled,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final TextEditingController controller;
  final int max;
  final bool enabled;
  final String? hint;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final length = controller.text.trim().length;

    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s3),
      child: KField(
        label: '$label   $length/$max',
        controller: controller,
        hint: hint,
        enabled: enabled,
        maxLength: max,
        // The count has to move as somebody types, and the limit has to be
        // felt before a save is refused. A server 400 about a length is a
        // round trip that teaches nothing.
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.hue,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final AccentHue hue;
  final bool selected;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: kilo.radius.controlBorder,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: hue.color,
            borderRadius: kilo.radius.controlBorder,
            border: Border.all(
              color: selected ? kilo.color.contentPrimary : hue.color,
              width: selected ? 3 : 1,
            ),
          ),
          // Never colour alone (ADR-0010). A check mark says which one is
          // chosen to somebody who cannot tell prune from brique.
          child: selected
              ? const Icon(Icons.check, color: Color(0xFFFFFFFF))
              : null,
        ),
      ),
    );
  }
}

/// The right-hand pane: the real widgets, at a phone's width.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.state,
    required this.vitrine,
    required this.language,
  });

  final _VitrineScreenState state;
  final VitrineDto vitrine;
  final String language;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    // What the *server* would store, rendered by the same widgets the public
    // page uses. Building a preview from the form's raw text rather than from
    // a second shape is what keeps the promise honest.
    final pending = VitrineDto(
      operatorId: vitrine.operatorId,
      code: vitrine.code,
      legalName: vitrine.legalName,
      tradingName: vitrine.tradingName,
      accentHue: state._accent.name,
      headerPattern: state._pattern.name,
      titleFr: state._titleFr.text,
      titleEn: state._titleEn.text,
      taglineFr: state._taglineFr.text,
      taglineEn: state._taglineEn.text,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t('console.vitrine.preview'), style: kilo.text.h3),
        SizedBox(height: kilo.space.s2),

        ClipRRect(
          borderRadius: kilo.radius.controlBorder,
          child: KBrandHeader(
            title: pending.titleFor(language),
            tagline: pending.taglineFor(language),
            accent: state._accent,
            pattern: state._pattern,
            logo: _logoMark(vitrine, 56),
          ),
        ),
        SizedBox(height: kilo.space.s2),
        Text(
          context.t('console.vitrine.previewStorefront'),
          style: kilo.text.caption.copyWith(
            color: kilo.color.contentSecondary,
          ),
        ),
        SizedBox(height: kilo.space.s4),

        // The search row, because the 4 px accent band on it is where most
        // travellers actually meet an operator's brand.
        KTripCard(
          departureTime: '06:00',
          arrivalTime: '13:30',
          operatorName: pending.titleFor(language),
          durationLabel: context.t('common.units.hours', {'count': 7}),
          totalFormatted: '9 000 FCFA',
          seatsLabel: context.tPlural('common.units.seatsLeft', 12, {
            'count': 12,
          }),
          accentColor: state._accent.color,
          onTap: null,
        ),
        SizedBox(height: kilo.space.s2),
        Text(
          context.t('console.vitrine.previewSearch'),
          style: kilo.text.caption.copyWith(
            color: kilo.color.contentSecondary,
          ),
        ),
        SizedBox(height: kilo.space.s4),

        ClipRRect(
          borderRadius: kilo.radius.controlBorder,
          child: KBrandHeader(
            title: pending.titleFor(language),
            accent: state._accent,
            pattern: state._pattern,
            compact: true,
            logo: _logoMark(vitrine, 40),
          ),
        ),
        SizedBox(height: kilo.space.s2),
        Text(
          context.t('console.vitrine.previewTicket'),
          style: kilo.text.caption.copyWith(
            color: kilo.color.contentSecondary,
          ),
        ),
      ],
    );
  }
}

/// The uploaded mark, or null so [KBrandHeader] falls back to its monogram.
///
/// Keyed off the **URL** rather than the storage key: a deployment with no
/// storage configured still has a key in the row it cannot serve, and a broken
/// image is worse than the generated tile that was always the documented
/// default.
Widget? _logoMark(VitrineDto vitrine, double size) {
  final url = vitrine.logoUrl;
  if (url == null) return null;

  return Image.network(
    url,
    width: size,
    height: size,
    fit: BoxFit.contain,
    // A logo that 404s — storage moved, the blob was deleted underneath us —
    // falls back to nothing, which is what makes the header draw its monogram
    // instead of a broken-image glyph on somebody's storefront.
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  );
}

/// The logo control: what is there now, and the two things you can do to it.
class _LogoField extends StatelessWidget {
  const _LogoField({
    required this.state,
    required this.vitrine,
    required this.enabled,
  });

  final _VitrineScreenState state;
  final VitrineDto vitrine;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final workspace = state.widget.workspace;
    final url = vitrine.logoUrl;

    // No picker means no browser — a widget test, or any build that is not
    // the console's. Offering a button that cannot open a dialog is worse
    // than saying what the default is.
    if (!workspace.canUploadAssets) {
      return KCard(
        tone: kilo.color.surfaceSunken,
        child: Row(
          children: [
            Icon(Icons.image_outlined, color: kilo.color.contentSecondary),
            SizedBox(width: kilo.space.s3),
            Expanded(
              child: Text(
                context.t('console.vitrine.logoNotYet'),
                style: kilo.text.bodySm.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return KCard(
      tone: kilo.color.surfaceSunken,
      child: Row(
        children: [
          // The mark at the size it is actually read at, next to the button
          // that changes it. A 200 px preview of a 32 dp mark would flatter a
          // logo that is unreadable where it lands.
          SizedBox(
            width: 56,
            height: 56,
            child: url == null
                ? KMonogram(
                    name: vitrine.titleFor(context.language),
                    accent: state._accent,
                    size: 56,
                  )
                : _logoMark(vitrine, 56),
          ),
          SizedBox(width: kilo.space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.t('console.vitrine.logo'),
                  style: kilo.text.label,
                ),
                SizedBox(height: kilo.space.s1),
                // The constraints, before the dialog rather than after the
                // refusal. Every one of them is enforced server-side, and
                // reading them here is what keeps somebody from exporting the
                // wrong file twice.
                Text(
                  context.t('console.vitrine.logoRules'),
                  style: kilo.text.caption.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: kilo.space.s3),
          // Bounded, because `KButton` stretches by default and a Row gives
          // its non-flexible children unbounded width. A ceiling rather than a
          // fixed size: "Remplacer" and "Replace" are not the same length, and
          // a hard width would clip one of them.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: KButton(
              label: context.t(
                url == null
                    ? 'console.vitrine.logoUpload'
                    : 'console.vitrine.logoReplace',
              ),
              tone: KButtonTone.secondary,
              icon: Icons.upload_outlined,
              fullWidth: false,
              onPressed: enabled && !workspace.busy
                  ? () => workspace.uploadVitrineAsset('logo')
                  : null,
            ),
          ),
          if (url != null) ...[
            SizedBox(width: kilo.space.s2),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: context.t('console.vitrine.logoRemove'),
              onPressed: enabled && !workspace.busy
                  ? () => workspace.removeVitrineAsset('logo')
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}
