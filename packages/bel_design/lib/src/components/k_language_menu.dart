import 'package:flutter/material.dart';

/// One language, as this menu needs it: what to store and what to show.
///
/// A record rather than the catalog's own `SupportedLanguage`, because the
/// design system does not depend on the translation catalog and must not start
/// — the tokens would then have to be rebuilt to add a language.
typedef KLanguageOption = ({String code, String nativeName});

/// The language switcher for a surface with no room for a settings screen.
///
/// **Why a menu and not a screen.** The traveller app has a settings screen
/// because a traveller has somewhere to go; a console, a back office and a
/// scanner are one workspace each, open all day, and a person who cannot read
/// the navigation is not going to find a settings screen behind it. So the
/// control sits in the frame, beside the theme toggle, and costs two taps from
/// anywhere.
///
/// **Each language is written in its own name**, which is the whole point:
/// somebody looking for their language scans for the word they would write
/// themselves, not for its translation into one they cannot read. That is also
/// why the labels are not translated strings and why this widget needs no
/// translator — a native name is the same in every language by definition.
class KLanguageMenu extends StatelessWidget {
  const KLanguageMenu({
    required this.languages,
    required this.current,
    required this.onChanged,
    super.key,
    this.tooltip = 'Langue',
  });

  /// In the order they should be offered — the catalog's own display order,
  /// never a list compiled into a screen.
  final List<KLanguageOption> languages;

  final String current;

  /// Called only when the choice actually changes. Re-picking the language
  /// already in use is not an event: it would write a preference, call the
  /// server and rebuild the tree to arrive exactly where it started.
  final ValueChanged<String> onChanged;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    // One language is not a choice, and a menu with a single entry is a
    // control that can only disappoint. Deployments genuinely run this way —
    // a market file naming one language is the normal case, not a broken one.
    if (languages.length < 2) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: tooltip,
      icon: const Icon(Icons.translate_outlined),
      initialValue: current,
      onSelected: (code) {
        if (code != current) onChanged(code);
      },
      itemBuilder: (context) => [
        for (final language in languages)
          PopupMenuItem<String>(
            value: language.code,
            child: Row(
              children: [
                // A fixed slot rather than a leading widget, so the names line
                // up whether or not one of them is the current choice — a list
                // that reflows as you read it is a list you read twice.
                SizedBox(
                  width: 28,
                  child: language.code == current
                      ? const Icon(Icons.check, size: 18)
                      : null,
                ),
                Text(language.nativeName),
              ],
            ),
          ),
      ],
    );
  }
}
