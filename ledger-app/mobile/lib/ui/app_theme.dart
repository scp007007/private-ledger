import 'package:flutter/material.dart';

ThemeData ledgerTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final ink = dark ? const Color(0xFFE8EFF8) : const Color(0xFF21324A);
  final secondary = dark ? const Color(0xFFA5B6CC) : const Color(0xFF66748A);
  final background = dark ? const Color(0xFF151B25) : const Color(0xFFF3F5F9);
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3564A6), brightness: brightness,
  ).copyWith(
    primary: dark ? const Color(0xFF9EBDEB) : const Color(0xFF3564A6),
    onPrimary: dark ? const Color(0xFF18365D) : Colors.white,
    primaryContainer: dark ? const Color(0xFF2B3E5A) : const Color(0xFFE8EEF9),
    onPrimaryContainer: dark ? const Color(0xFFCDDCF3) : const Color(0xFF29466F),
    surface: dark ? const Color(0xFF202937) : Colors.white,
    onSurface: ink, onSurfaceVariant: secondary,
    outline: dark ? const Color(0xFF697C98) : const Color(0xFF8494AB),
    outlineVariant: dark ? const Color(0xFF354255) : const Color(0xFFE4E9F1),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: colors);
  final text = base.textTheme.apply(bodyColor: ink, displayColor: ink).copyWith(
    headlineLarge: TextStyle(fontSize: 38, height: 1.2, fontWeight: FontWeight.w600,
      letterSpacing: -1.2, color: ink, fontFeatures: const [FontFeature.tabularFigures()]),
    titleLarge: TextStyle(fontSize: 20, height: 1.3, fontWeight: FontWeight.w600, color: ink),
    titleMedium: TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w600, color: ink),
    titleSmall: TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w600, color: ink),
    bodyLarge: TextStyle(fontSize: 15, height: 1.5, color: ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: ink),
    bodySmall: TextStyle(fontSize: 12, height: 1.4, color: secondary),
    labelLarge: TextStyle(fontSize: 13, height: 1.4, fontWeight: FontWeight.w600, color: ink),
    labelSmall: TextStyle(fontSize: 11, height: 1.4, fontWeight: FontWeight.w500, color: secondary),
  );
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background, foregroundColor: ink,
      surfaceTintColor: Colors.transparent, centerTitle: false,
      elevation: 0, scrolledUnderElevation: 0, titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: colors.surface, surfaceTintColor: Colors.transparent,
      elevation: 0, margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface, indicatorColor: colors.primaryContainer,
      elevation: 0, height: 72,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: colors.surface,
      hintStyle: text.bodyMedium?.copyWith(color: secondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.outlineVariant)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.primary, width: 1.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48), side: BorderSide(color: colors.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    )),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: colors.surface, selectedColor: colors.primaryContainer,
      side: BorderSide(color: colors.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      labelStyle: text.bodySmall?.copyWith(color: ink),
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1, space: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.primary),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
  );
}
