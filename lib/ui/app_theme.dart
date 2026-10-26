/// Light and dark [ThemeData] for TG Media.
///
/// The two sets of values live here rather than in `main.dart` so the settings
/// page can render a preview and the shell can build either one without the
/// theme drifting between the two call sites.
///
/// Numbers come from `docs/PRODUCT-SPEC.md` §6.3: body 15, secondary 13,
/// title 17 semibold, feed headline 16 semibold, page padding 16, card radius
/// 12, minimum touch target 44.
library;

import 'package:flutter/material.dart';

class AppTheme {
  const AppTheme._();

  /// Telegram-adjacent blue. Only the seed: no brand assets are copied.
  static const Color seed = Color(0xFF2AABEE);

  static const double pagePadding = 16;
  static const double cardRadius = 12;
  static const double minTouchTarget = 44;

  /// The video page is always dark regardless of theme: a light chrome around a
  /// full-screen video is a flashlight in a dark room.
  static const Color feedBackground = Color(0xFF000000);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    final isDark = brightness == Brightness.dark;

    final textTheme = base.textTheme.copyWith(
      // 正文
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.35),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.35),
      // 次要信息（日期、来源、状态行）
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.3),
      // 页面标题
      titleMedium: base.textTheme.titleMedium
          ?.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
      // 视频页主标题
      titleSmall: base.textTheme.titleSmall
          ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 15),
    );

    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0E0E10) : const Color(0xFFF7F7F9),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor:
            isDark ? const Color(0xFF0E0E10) : const Color(0xFFF7F7F9),
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 12,
        contentPadding: EdgeInsets.symmetric(horizontal: pagePadding),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surfaceContainerHighest;
        }),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 0.5,
        color: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Rounded card used by grouped settings sections.
  static BoxDecoration card(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
    );
  }
}
