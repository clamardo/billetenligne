import 'package:flutter/material.dart';

import 'kilo_scheme.dart';
import 'tokens/kilo_colors.dart';
import 'tokens/kilo_spacing.dart';
import 'tokens/kilo_typography.dart';

/// Component density. The same components render at [comfortable] on mobile
/// and [compact] in console tables — one component set, two densities
/// (ADR-0010 rule 10), never two parallel component libraries.
enum KiloDensity { comfortable, compact }

/// Kilo rides *on top of* Material 3 rather than replacing it, so we keep
/// accessibility, focus handling and platform behaviour for free and override
/// only appearance (ADR-0010 rule 2).
@immutable
final class KiloTheme extends ThemeExtension<KiloTheme> {
  KiloTheme({required this.color, this.density = KiloDensity.comfortable})
    : text = KiloTypography(color.contentPrimary),
      space = const KiloSpacing(),
      radius = const KiloRadius(),
      motion = const KiloMotion(),
      elevation = KiloElevation(color.contentPrimary);

  final KiloColors color;
  final KiloDensity density;
  final KiloTypography text;
  final KiloSpacing space;
  final KiloRadius radius;
  final KiloMotion motion;
  final KiloElevation elevation;

  /// Row height and control padding shrink in the console; touch targets on
  /// mobile never do.
  double get rowHeight =>
      density == KiloDensity.compact ? 40 : space.touchTarget;

  @override
  KiloTheme copyWith({KiloColors? color, KiloDensity? density}) =>
      KiloTheme(color: color ?? this.color, density: density ?? this.density);

  /// Themes are discrete, not interpolated: cross-fading between light and
  /// dark mid-animation produces muddy intermediate colours that pass no
  /// contrast check. Snap at the halfway point instead.
  @override
  KiloTheme lerp(ThemeExtension<KiloTheme>? other, double t) {
    if (other is! KiloTheme) return this;
    return t < 0.5 ? this : other;
  }

  /// The single place every surface in the product gets its appearance.
  ///
  /// Kilo's rule is that a screen never styles a component. If a `Card` needs
  /// a softer border or a `Chip` a different fill, it changes *here* and all
  /// four apps move together — which is the whole reason the design system is
  /// a package and not a folder of widgets.
  static ThemeData materialTheme({
    KiloBrightness brightness = KiloBrightness.light,
    KiloDensity density = KiloDensity.comfortable,
  }) {
    final colors = KiloColors.of(brightness);
    final kilo = KiloTheme(color: colors, density: density);
    final scheme = KiloScheme.of(brightness);
    final t = kilo.text;
    final r = kilo.radius;
    final s = kilo.space;
    final compact = density == KiloDensity.compact;
    final sun = brightness == KiloBrightness.pleinSoleil;

    // Plein soleil draws every edge at full strength: a hairline disappears
    // on a scratched panel in direct sun.
    final hairline = sun ? 2.0 : 1.0;
    final line = BorderSide(color: colors.borderSubtle, width: hairline);
    final lineStrong = BorderSide(color: colors.borderStrong, width: hairline);

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.surfaceBase,
      canvasColor: colors.surfaceBase,
      dividerColor: colors.borderSubtle,
      fontFamily: KiloTypography.family,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,

      textTheme: TextTheme(
        displayLarge: t.displayXl,
        displayMedium: t.display,
        displaySmall: t.h1,
        headlineLarge: t.display,
        headlineMedium: t.h1,
        headlineSmall: t.h2,
        titleLarge: t.h2,
        titleMedium: t.h3,
        titleSmall: KiloTypography.weight(t.body, FontWeight.w600),
        bodyLarge: t.bodyLg,
        bodyMedium: t.body,
        bodySmall: t.bodySm,
        labelLarge: KiloTypography.weight(t.body, FontWeight.w600),
        labelMedium: t.caption,
        labelSmall: t.label,
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: colors.surfaceBase,
        foregroundColor: colors.contentPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: t.h2,
        shape: Border(
          bottom: BorderSide(color: colors.borderSubtle, width: hairline),
        ),
      ),

      // Raised chrome is pinned to `surfaceRaised` rather than to an M3
      // container role, because the ramp runs in opposite directions in light
      // and dark: `surfaceContainerLowest` is the *whitest* surface in light
      // and the *blackest* in dark, so a card bound to it would sit above the
      // page by day and below it by night. The token means "raised" in every
      // theme; the role does not.
      cardTheme: CardThemeData(
        color: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shadowColor: colors.contentPrimary.withValues(alpha: 0.06),
        elevation: sun ? 0 : 1,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: r.cardBorder, side: line),
      ),

      dividerTheme: DividerThemeData(
        color: colors.borderSubtle,
        thickness: hairline,
        space: s.s4,
      ),

      listTileTheme: ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? s.s3 : s.s4,
          vertical: compact ? 0 : s.s1,
        ),
        minVerticalPadding: compact ? s.s2 : s.s3,
        iconColor: colors.contentSecondary,
        textColor: colors.contentPrimary,
        titleTextStyle: KiloTypography.weight(t.body, FontWeight.w600),
        subtitleTextStyle: t.bodySm.copyWith(color: colors.contentSecondary),
        shape: RoundedRectangleBorder(borderRadius: r.controlBorder),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.brandPrimary,
          foregroundColor: colors.onBrandPrimary,
          disabledBackgroundColor: colors.borderSubtle,
          disabledForegroundColor: colors.contentMuted,
          minimumSize: Size(0, compact ? 40 : s.touchTarget),
          padding: EdgeInsets.symmetric(horizontal: s.s5),
          textStyle: KiloTypography.weight(t.body, FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: r.controlBorder),
          elevation: 0,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.contentPrimary,
          side: lineStrong,
          minimumSize: Size(0, compact ? 40 : s.touchTarget),
          padding: EdgeInsets.symmetric(horizontal: s.s5),
          textStyle: KiloTypography.weight(t.body, FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: r.controlBorder),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.brandPrimary,
          minimumSize: Size(0, compact ? 36 : s.touchTarget),
          padding: EdgeInsets.symmetric(horizontal: s.s3),
          textStyle: KiloTypography.weight(t.body, FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: r.controlBorder),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colors.contentSecondary,
          minimumSize: Size.square(compact ? 36 : s.touchTarget),
          shape: RoundedRectangleBorder(borderRadius: r.controlBorder),
        ),
      ),

      iconTheme: IconThemeData(color: colors.contentSecondary, size: 20),
      primaryIconTheme: IconThemeData(color: colors.onBrandPrimary, size: 20),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        selectedColor: colors.brandPrimarySoft,
        disabledColor: scheme.surfaceContainerHigh,
        checkmarkColor: scheme.onPrimaryContainer,
        labelStyle: t.bodySm.copyWith(color: colors.contentPrimary),
        secondaryLabelStyle: t.bodySm.copyWith(
          color: scheme.onPrimaryContainer,
        ),
        side: line,
        padding: EdgeInsets.symmetric(horizontal: s.s3, vertical: s.s2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(r.pill)),
        showCheckmark: true,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: sun ? colors.surfaceRaised : scheme.surfaceContainer,
        hintStyle: t.body.copyWith(color: colors.contentMuted),
        labelStyle: t.bodySm.copyWith(color: colors.contentSecondary),
        floatingLabelStyle: t.bodySm.copyWith(color: colors.brandPrimary),
        helperStyle: t.caption.copyWith(color: colors.contentSecondary),
        errorStyle: t.caption.copyWith(color: colors.danger),
        prefixIconColor: colors.contentMuted,
        suffixIconColor: colors.contentMuted,
        // Horizontal padding stays at 12 even in the comfortable density.
        // A field carries a prefix icon, a label and a suffix, and every
        // point of side padding is one the label loses — the console's
        // three-across leg editor overflows at 16.
        contentPadding: EdgeInsets.symmetric(
          horizontal: s.s3,
          vertical: compact ? s.s3 : s.s4,
        ),
        border: OutlineInputBorder(
          borderRadius: r.controlBorder,
          borderSide: line,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: r.controlBorder,
          borderSide: line,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: r.controlBorder,
          borderSide: BorderSide(color: colors.brandPrimary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: r.controlBorder,
          borderSide: BorderSide(color: colors.danger, width: hairline),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: r.controlBorder,
          borderSide: BorderSide(color: colors.danger, width: 2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: r.controlBorder,
          borderSide: BorderSide(color: colors.borderSubtle, width: hairline),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.brandPrimarySoft,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(r.pill),
        ),
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? KiloTypography.weight(
                  t.caption,
                  FontWeight.w600,
                ).copyWith(color: colors.contentPrimary)
              : t.caption.copyWith(color: colors.contentSecondary),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : colors.contentSecondary,
          ),
        ),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colors.surfaceRaised,
        indicatorColor: colors.brandPrimarySoft,
        elevation: 0,
        selectedLabelTextStyle: KiloTypography.weight(
          t.caption,
          FontWeight.w600,
        ).copyWith(color: colors.contentPrimary),
        unselectedLabelTextStyle: t.caption.copyWith(
          color: colors.contentSecondary,
        ),
        selectedIconTheme: IconThemeData(
          size: 22,
          color: scheme.onPrimaryContainer,
        ),
        unselectedIconTheme: IconThemeData(
          size: 22,
          color: colors.contentSecondary,
        ),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: scheme.surfaceContainer,
          foregroundColor: colors.contentSecondary,
          selectedBackgroundColor: colors.brandPrimarySoft,
          selectedForegroundColor: scheme.onPrimaryContainer,
          side: line,
          textStyle: KiloTypography.weight(t.bodySm, FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: r.controlBorder),
        ),
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: colors.contentPrimary,
        unselectedLabelColor: colors.contentSecondary,
        labelStyle: KiloTypography.weight(t.body, FontWeight.w600),
        unselectedLabelStyle: t.body,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: colors.borderSubtle,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: colors.brandPrimary, width: 2.5),
          insets: EdgeInsets.symmetric(horizontal: s.s2),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.contentPrimary,
        contentTextStyle: t.body.copyWith(color: colors.contentInverse),
        actionTextColor: scheme.inversePrimary,
        behavior: SnackBarBehavior.floating,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: r.controlBorder),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        titleTextStyle: t.h2,
        contentTextStyle: t.body.copyWith(color: colors.contentSecondary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(r.xl),
          side: line,
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        showDragHandle: true,
        dragHandleColor: colors.borderStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: r.xl),
        ),
      ),

      badgeTheme: BadgeThemeData(
        backgroundColor: colors.danger,
        textColor: colors.contentInverse,
        textStyle: KiloTypography.weight(t.caption, FontWeight.w700),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.contentPrimary,
          borderRadius: BorderRadius.all(r.sm),
        ),
        textStyle: t.bodySm.copyWith(color: colors.contentInverse),
        padding: EdgeInsets.symmetric(horizontal: s.s3, vertical: s.s2),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.brandPrimary,
        linearTrackColor: scheme.surfaceContainerHigh,
        circularTrackColor: scheme.surfaceContainerHigh,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? colors.onBrandPrimary
              : colors.surfaceRaised,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? colors.brandPrimary
              : scheme.surfaceContainerHigh,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? colors.brandPrimary
              : colors.borderStrong,
        ),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? colors.brandPrimary
              : Colors.transparent,
        ),
        checkColor: WidgetStateProperty.all(colors.onBrandPrimary),
        side: lineStrong,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(r.sm)),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? colors.brandPrimary
              : colors.borderStrong,
        ),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: colors.brandPrimary,
        inactiveTrackColor: scheme.surfaceContainerHigh,
        thumbColor: colors.brandPrimary,
        overlayColor: colors.brandPrimary.withValues(alpha: 0.12),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.brandPrimary,
        foregroundColor: colors.onBrandPrimary,
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(r.lg)),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        textStyle: t.body,
        shape: RoundedRectangleBorder(borderRadius: r.cardBorder, side: line),
      ),

      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceRaised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: r.cardBorder, side: line),
          ),
        ),
      ),

      drawerTheme: DrawerThemeData(
        backgroundColor: colors.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(),
      ),

      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainer),
        headingTextStyle: t.label.copyWith(color: colors.contentSecondary),
        dataTextStyle: t.bodySm,
        dividerThickness: hairline,
        headingRowHeight: compact ? 40 : 48,
        dataRowMinHeight: compact ? 36 : 48,
        dataRowMaxHeight: compact ? 44 : 60,
      ),

      expansionTileTheme: ExpansionTileThemeData(
        backgroundColor: scheme.surfaceContainer,
        collapsedBackgroundColor: Colors.transparent,
        iconColor: colors.brandPrimary,
        collapsedIconColor: colors.contentSecondary,
        textColor: colors.contentPrimary,
        collapsedTextColor: colors.contentPrimary,
        shape: RoundedRectangleBorder(borderRadius: r.cardBorder),
        collapsedShape: RoundedRectangleBorder(borderRadius: r.cardBorder),
      ),

      extensions: [kilo],
    );
  }
}

/// `context.kilo.color.brandPrimary` — the only way application code reaches a
/// token. A raw `Color(0x…)` or a magic `EdgeInsets` number outside this
/// package is a build failure, not a review comment (ADR-0010 rule 1).
extension KiloThemeContext on BuildContext {
  KiloTheme get kilo =>
      Theme.of(this).extension<KiloTheme>() ??
      KiloTheme(color: KiloColors.light);
}
