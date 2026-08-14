import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// The two things about this app somebody is allowed to change.
///
/// **Why it did not exist.** `setLanguage` was threaded through the whole
/// widget tree — `Localized`, the scope, a `context.setLanguage` extension —
/// and called from nowhere in any of the four apps. `context.languages` was
/// there beside it, also unread. The machinery for switching language was
/// complete and unreachable, which is worse than absent: it reads as done.
///
/// **Language is the point of this screen.** The theme already had a one-tap
/// toggle on the hero; what it did not have was a way back to *follow the
/// handset* once somebody had left it, which is the state `KModeChoice`
/// exists to express and the reason it is here rather than a second toggle.
///
/// **Written in their own language.** `Français` reads `Français` on an
/// English screen, from the catalog's own `nativeName`. Somebody looking for
/// their language scans for the word they would write themselves, not for its
/// translation into a language they cannot read — which is the whole situation
/// this screen exists to get somebody out of.
final class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.onLanguage,
    required this.onBack,
    this.mode,
    super.key,
  });

  final void Function(String code) onLanguage;
  final VoidCallback onBack;

  /// Absent in tests and on any surface that has not wired persistence, in
  /// which case the appearance section is simply not drawn — the same contract
  /// `KModeToggle` already follows.
  final KiloModeController? mode;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final held = mode ?? KiloModeScope.maybeOf(context);
    final current = context.language;

    // The catalog's own manifest, in its own display order — never a list
    // compiled into this screen. A build that offered a language whose folder
    // is not in the bundle would render a screen of keys.
    final languages = [...context.languages]
      ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onBack),
        title: Text(context.t('travel.settings.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Text(context.t('travel.settings.language'), style: kilo.text.label),
            SizedBox(height: kilo.space.s2),
            KCard(
              // `KCard` is a decorated box, and a `ListTile` paints its ripple
              // on the nearest `Material` ancestor — which without this is the
              // page underneath, so the tap feedback is drawn behind the card
              // and never seen. Flutter asserts on exactly this in debug.
              child: Material(
                color: Colors.transparent,
                child: RadioGroup<String>(
                  groupValue: current,
                  onChanged: (picked) {
                    if (picked != null && picked != current) onLanguage(picked);
                  },
                  child: Column(
                    children: [
                      for (final language in languages)
                        RadioListTile<String>(
                          value: language.code,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            language.nativeName,
                            style: kilo.text.body,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: kilo.space.s2),
            // Said plainly, because the surprising half happens when the app
            // is shut: a receipt at two in the morning is written in whatever
            // this says, by a server that has never seen this screen.
            Text(
              context.t('travel.settings.languageNote'),
              style: kilo.text.bodySm.copyWith(color: kilo.color.contentMuted),
            ),

            if (held != null) ...[
              SizedBox(height: kilo.space.s5),
              Text(context.t('travel.settings.theme'), style: kilo.text.label),
              SizedBox(height: kilo.space.s2),
              KModeChoice(
                controller: held,
                systemLabel: context.t('travel.settings.themeSystem'),
                lightLabel: context.t('travel.settings.themeLight'),
                darkLabel: context.t('travel.settings.themeDark'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
