import 'package:flutter/material.dart';

import 'tokens/kilo_colors.dart';

/// What the person actually chose, which is not the same as what they see.
///
/// [system] is the default and stays the default: most people never open a
/// theme setting, and following the handset is the right answer for them. The
/// other two exist because following the handset is the *wrong* answer often
/// enough to matter here — a shared phone set to dark by somebody else, a
/// battery-saver that forces dark at 15 %, an agent who works under a strip
/// light all day and finds dark unreadable.
enum KiloMode {
  system,
  light,
  dark;

  static KiloMode byName(String? raw) {
    for (final m in values) {
      if (m.name == raw) return m;
    }
    return system;
  }

  ThemeMode get materialMode => switch (this) {
    KiloMode.system => ThemeMode.system,
    KiloMode.light => ThemeMode.light,
    KiloMode.dark => ThemeMode.dark,
  };
}

/// Holds the choice and tells the app when it changes.
///
/// Persisting is the app's job, not the design system's: a package that draws
/// buttons has no business knowing whether this handset stores preferences in
/// SQLite, in local storage or nowhere at all. [onChanged] is how it gets out.
class KiloModeController extends ChangeNotifier {
  KiloModeController({KiloMode initial = KiloMode.system, this.onChanged})
    : _mode = initial;

  final void Function(KiloMode)? onChanged;
  KiloMode _mode;

  KiloMode get mode => _mode;

  set mode(KiloMode value) {
    if (value == _mode) return;
    _mode = value;
    onChanged?.call(value);
    notifyListeners();
  }

  /// What the toggle does on a tap. Two states, not three: cycling through
  /// *system* means a third of taps appear to do nothing whenever the handset
  /// already matches, which reads as a broken control. Choosing explicitly is
  /// the point of touching it at all.
  void toggle(BuildContext context) {
    final showing = mode == KiloMode.system
        ? MediaQuery.platformBrightnessOf(context)
        : (mode == KiloMode.dark ? Brightness.dark : Brightness.light);
    mode = showing == Brightness.dark ? KiloMode.light : KiloMode.dark;
  }
}

/// Puts the choice where any screen can reach it.
///
/// The alternative is threading a controller from the composition root down
/// through every screen that wants a toggle, which means the toggle can only
/// exist where somebody already thought to pass it — and the screens that
/// most need one are the ones nobody thought about.
class KiloModeScope extends InheritedNotifier<KiloModeController> {
  const KiloModeScope({
    required KiloModeController super.notifier,
    required super.child,
    super.key,
  });

  /// Null when no app wired one, so a screen can simply not draw a toggle
  /// rather than crash. Tests mount screens on their own all the time.
  static KiloModeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KiloModeScope>()?.notifier;
}

/// One tap, in an app bar. Labelled for screen readers and tooltipped for
/// everybody else, because a lone half-moon is not self-evident.
class KModeToggle extends StatelessWidget {
  const KModeToggle({
    super.key,
    this.controller,
    this.lightLabel = 'Thème clair',
    this.darkLabel = 'Thème sombre',
  });

  /// Falls back to the enclosing [KiloModeScope]. Draws nothing at all when
  /// there is neither — an app bar in a test should not sprout a control the
  /// app cannot honour.
  final KiloModeController? controller;
  final String lightLabel;
  final String darkLabel;

  @override
  Widget build(BuildContext context) {
    final held = controller ?? KiloModeScope.maybeOf(context);
    if (held == null) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: dark ? lightLabel : darkLabel,
      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      onPressed: () => held.toggle(context),
    );
  }
}

/// The explicit three-way choice, for a settings screen — including *follow
/// the handset*, which the one-tap toggle cannot express and which is the
/// only way back to the default once somebody has left it.
class KModeChoice extends StatelessWidget {
  const KModeChoice({
    required this.controller,
    super.key,
    this.systemLabel = 'Système',
    this.lightLabel = 'Clair',
    this.darkLabel = 'Sombre',
  });

  final KiloModeController controller;
  final String systemLabel;
  final String lightLabel;
  final String darkLabel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => SegmentedButton<KiloMode>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: KiloMode.system,
          icon: const Icon(Icons.brightness_auto_outlined, size: 18),
          label: Text(systemLabel),
        ),
        ButtonSegment(
          value: KiloMode.light,
          icon: const Icon(Icons.light_mode_outlined, size: 18),
          label: Text(lightLabel),
        ),
        ButtonSegment(
          value: KiloMode.dark,
          icon: const Icon(Icons.dark_mode_outlined, size: 18),
          label: Text(darkLabel),
        ),
      ],
      selected: {controller.mode},
      onSelectionChanged: (s) => controller.mode = s.first,
    ),
  );
}

/// The pair of themes an app hands to `MaterialApp`, so no surface has to
/// remember to wire the dark one — forgetting `darkTheme:` is invisible until
/// somebody with a dark handset opens the app.
extension KiloModeThemes on KiloMode {
  static KiloBrightness resolve(KiloMode mode, Brightness platform) =>
      switch (mode) {
        KiloMode.light => KiloBrightness.light,
        KiloMode.dark => KiloBrightness.dark,
        KiloMode.system =>
          platform == Brightness.dark
              ? KiloBrightness.dark
              : KiloBrightness.light,
      };
}
