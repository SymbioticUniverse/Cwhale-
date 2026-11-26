import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DesktopTypographySettings {
  const DesktopTypographySettings({this.fontFamily = '', this.scale = 1.0});

  final String fontFamily;
  final double scale;
}

class CwhaleTheme {
  CwhaleTheme._();

  static final ValueNotifier<bool> darkMode = ValueNotifier<bool>(false);
  static final ValueNotifier<DesktopTypographySettings> desktopTypography =
      ValueNotifier<DesktopTypographySettings>(
        const DesktopTypographySettings(),
      );

  static bool get isDark => darkMode.value;
  static bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;

  /// A consistent Windows type scale; mobile font sizes stay unchanged.
  static double desktopFontSize(double size) {
    if (defaultTargetPlatform != TargetPlatform.windows) return size;
    final normalized = size <= 12
        ? 13.0
        : size <= 14
        ? 14.0
        : size <= 16
        ? 16.0
        : size <= 18
        ? 18.0
        : size;
    return normalized * desktopTypography.value.scale.clamp(0.9, 1.3);
  }

  static Color get ink =>
      isDark ? const Color(0xfff1f2f4) : const Color(0xff1c1d21);
  static Color get muted => isDark
      ? (_isWindows ? const Color(0xffb6b8c0) : const Color(0xff999ba2))
      : (_isWindows ? const Color(0xff555b66) : const Color(0xff70737b));
  static Color get accent => const Color(0xff6686f5);
  static Color get background => isDark
      ? const Color(0xff111214)
      : (_isWindows ? const Color(0xfff4f6f9) : const Color(0xfff8f9fb));
  static Color get surface =>
      isDark ? const Color(0xff202124) : const Color(0xffffffff);
  static Color get raisedSurface => isDark
      ? const Color(0xff27282b)
      : (_isWindows ? const Color(0xffedf1f5) : const Color(0xfff0f2f6));
  static Color get line => isDark
      ? const Color(0xff36373b)
      : (_isWindows ? const Color(0xffd9e0e8) : const Color(0xffe3e6ec));
  static Color get selectedSurface => isDark
      ? const Color(0xff273451)
      : (_isWindows ? const Color(0xffe9efff) : const Color(0xffe9edff));
  static Color get selectedMessage => isDark
      ? const Color(0xff293858)
      : (_isWindows ? const Color(0xffedf2ff) : const Color(0xffeef1ff));

  static ThemeData get light => _buildTheme(dark: false);
  static ThemeData get dark => _buildTheme(dark: true);

  static ThemeData _buildTheme({required bool dark}) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final background = dark
        ? const Color(0xff111214)
        : (isWindows ? const Color(0xfff4f6f9) : const Color(0xfff8f9fb));
    final surface = dark ? const Color(0xff222326) : Colors.white;
    const accent = Color(0xff6686f5);
    final ink = dark ? const Color(0xfff1f2f4) : const Color(0xff1c1d21);
    final line = dark
        ? const Color(0xff36373b)
        : (isWindows ? const Color(0xffd9e0e8) : const Color(0xffe3e6ec));
    final muted = dark
        ? (isWindows ? const Color(0xffb6b8c0) : const Color(0xff999ba2))
        : (isWindows ? const Color(0xff555b66) : const Color(0xff70737b));
    final customFontFamily = desktopTypography.value.fontFamily.trim();

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: isWindows
          ? (customFontFamily.isEmpty ? 'Microsoft YaHei UI' : customFontFamily)
          : null,
      fontFamilyFallback: isWindows
          ? const ['Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI']
          : null,
      visualDensity: isWindows
          ? VisualDensity.standard
          : VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        surface: surface,
      ).copyWith(primary: accent, secondary: accent),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xff222326) : Colors.white,
        hintStyle: TextStyle(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: accent, width: 1.4),
        ),
      ),
      popupMenuTheme: isWindows
          ? PopupMenuThemeData(
              color: surface,
              surfaceTintColor: Colors.transparent,
              elevation: 10,
              shadowColor: Colors.black.withValues(alpha: 0.16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: line),
              ),
              menuPadding: const EdgeInsets.symmetric(vertical: 6),
              textStyle: TextStyle(
                color: ink,
                fontSize: isWindows ? 14 : null,
                fontWeight: FontWeight.w400,
              ),
            )
          : null,
      listTileTheme: isWindows
          ? ListTileThemeData(
              textColor: ink,
              iconColor: muted,
              titleTextStyle: TextStyle(
                color: ink,
                fontSize: isWindows ? desktopFontSize(15) : null,
                fontWeight: FontWeight.w500,
              ),
              subtitleTextStyle: TextStyle(
                color: muted,
                fontSize: isWindows ? desktopFontSize(13) : null,
                height: 1.4,
              ),
            )
          : null,
      drawerTheme: DrawerThemeData(backgroundColor: background),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: dark ? const Color(0xff1b1c1f) : Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: desktopFontSize(20),
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(color: muted, height: 1.5),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: dark
            ? const Color(0xff292a2e)
            : const Color(0xff292b31),
        contentTextStyle: const TextStyle(color: Colors.white),
      ),
      dividerColor: line,
    );
  }
}
