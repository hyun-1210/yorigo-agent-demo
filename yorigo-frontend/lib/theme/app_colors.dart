import 'package:flutter/material.dart';

class AppColors {
  // Primary colors (same for both themes)
  static const Color primary = Color(0xFFFF6900);
  static const Color primaryLight = Color(0xFFFFF5ED);
  static const Color primaryDark = Color(
    0xFFCC5500,
  ); // Darker orange for dark mode

  // Light mode colors
  static const Color lightTextPrimary = Color(0xFF333333);
  static const Color lightTextSecondary = Color(0xFF666666);
  static const Color lightTextTertiary = Color(0xFF999999);
  static const Color lightBackground = Color(0xFFFFFFFF);
  static const Color lightBackgroundSecondary = Color(0xFFF5F5F5);
  static const Color lightBackgroundTertiary = Color(0xFFF8F8F8);
  static const Color lightBorder = Color(0xFFF0F0F0);
  static const Color lightBorderSecondary = Color(0xFFE0E0E0);

  // Dark mode colors
  static const Color darkTextPrimary = Color(0xFFE0E0E0);
  static const Color darkTextSecondary = Color(0xFFB0B0B0);
  static const Color darkTextTertiary = Color(0xFF808080);
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkBackgroundSecondary = Color(0xFF1E1E1E);
  static const Color darkBackgroundTertiary = Color(0xFF2A2A2A);
  static const Color darkBorder = Color(0xFF2A2A2A);
  static const Color darkBorderSecondary = Color(0xFF3A3A3A);

  // Other colors (same for both themes)
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFB800);

  // Meal colors (same for both themes)
  static const Color breakfast = Color(0xFF8CD4C1);
  static const Color lunch = Color(0xFF4D94CE);
  static const Color dinner = Color(0xFFAB79CD);

  // Helper methods to get colors based on brightness
  static Color getTextPrimary(Brightness brightness) {
    return brightness == Brightness.dark ? darkTextPrimary : lightTextPrimary;
  }

  static Color getTextSecondary(Brightness brightness) {
    return brightness == Brightness.dark
        ? darkTextSecondary
        : lightTextSecondary;
  }

  static Color getTextTertiary(Brightness brightness) {
    return brightness == Brightness.dark ? darkTextTertiary : lightTextTertiary;
  }

  static Color getBackground(Brightness brightness) {
    return brightness == Brightness.dark ? darkBackground : lightBackground;
  }

  static Color getBackgroundSecondary(Brightness brightness) {
    return brightness == Brightness.dark
        ? darkBackgroundSecondary
        : lightBackgroundSecondary;
  }

  static Color getBackgroundTertiary(Brightness brightness) {
    return brightness == Brightness.dark
        ? darkBackgroundTertiary
        : lightBackgroundTertiary;
  }

  static Color getBorder(Brightness brightness) {
    return brightness == Brightness.dark ? darkBorder : lightBorder;
  }

  static Color getBorderSecondary(Brightness brightness) {
    return brightness == Brightness.dark
        ? darkBorderSecondary
        : lightBorderSecondary;
  }

  /// Letterbox / WebView chrome for Instagram — blue-black like in-app mobile browser, not pure `#000`.
  static const Color instagramBrowserLetterbox = Color(0xFF0B0F12);

  /// CSS `background` for injected embed layout — keep in sync with [instagramBrowserLetterbox].
  static const String instagramBrowserLetterboxCss = '#0b0f12';

  // Legacy getters for backward compatibility (default to light mode)
  static Color get textPrimary => lightTextPrimary;
  static Color get textSecondary => lightTextSecondary;
  static Color get textTertiary => lightTextTertiary;
  static Color get background => lightBackground;
  static Color get backgroundSecondary => lightBackgroundSecondary;
  static Color get backgroundTertiary => lightBackgroundTertiary;
  static Color get border => lightBorder;
  static Color get borderSecondary => lightBorderSecondary;
}
