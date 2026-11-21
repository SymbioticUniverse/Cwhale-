import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CwhaleTheme {
  CwhaleTheme._();

  static final ValueNotifier<bool> darkMode = ValueNotifier<bool>(false);

  static bool get isDark => darkMode.value;

  static Color get ink =>
      isDark ? const Color(0xfff1f2f4) : const Color(0xff1c1d21);
  static Color get muted =>
      isDark ? const Color(0xff999ba2) : const Color(0xff70737b);
  static Color get accent => const Color(0xff6686f5);
  static Color get background =>
      isDark ? const Color(0xff111214) : const Color(0xfff8f9fb);
  static Color get surface =>
      isDark ? const Color(0xff202124) : const Color(0xffffffff);
  static Color get raisedSurface =>
      isDark ? const Color(0xff27282b) : const Color(0xfff0f2f6);
  static Color get line =>
      isDark ? const Color(0xff36373b) : const Color(0xffe3e6ec);
  static Color get selectedSurface =>
      isDark ? const Color(0xff273451) : const Color(0xffe9edff);
  static Color get selectedMessage =>
      isDark ? const Color(0xff293858) : const Color(0xffeef1ff);

  static ThemeData get light => _buildTheme(dark: false);
  static ThemeData get dark => _buildTheme(dark: true);

  static ThemeData _buildTheme({required bool dark}) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    final background = dark ? const Color(0xff111214) : const Color(0xfff8f9fb);
    final surface = dark ? const Color(0xff222326) : Colors.white;
    const accent = Color(0xff6686f5);
    final ink = dark ? const Color(0xfff1f2f4) : const Color(0xff1c1d21);
    final line = dark ? const Color(0xff36373b) : const Color(0xffe3e6ec);
    final muted = dark ? const Color(0xff999ba2) : const Color(0xff70737b);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
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
          fontSize: 20,
          fontWeight: FontWeight.w700,
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
