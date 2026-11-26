import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'chat_screen.dart';
import 'generation_protection.dart';
import 'local_store.dart';
import 'onboarding_flow_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GenerationProtection.initialize();
  runApp(const CwhaleApp());
}

class CwhaleApp extends StatelessWidget {
  const CwhaleApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: CwhaleTheme.darkMode,
    builder: (context, darkMode, _) {
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        SystemChrome.setSystemUIOverlayStyle(
          darkMode
              ? const SystemUiOverlayStyle(
                  statusBarColor: Color(0xff111214),
                  statusBarIconBrightness: Brightness.light,
                  systemNavigationBarColor: Color(0xff111214),
                  systemNavigationBarIconBrightness: Brightness.light,
                )
              : const SystemUiOverlayStyle(
                  statusBarColor: Color(0xfff8f9fb),
                  statusBarIconBrightness: Brightness.dark,
                  systemNavigationBarColor: Color(0xfff8f9fb),
                  systemNavigationBarIconBrightness: Brightness.dark,
                ),
        );
      }
      return MaterialApp(
        title: 'Cwhale',
        debugShowCheckedModeBanner: false,
        theme: CwhaleTheme.light,
        darkTheme: CwhaleTheme.dark,
        themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) {
          if (defaultTargetPlatform != TargetPlatform.windows) {
            return child ?? const SizedBox.shrink();
          }
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: _DesktopTypographyScaler(media.textScaler),
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: const _StartupGate(),
      );
    },
  );
}

/// Uses discrete native text sizes instead of fractional whole-window scaling.
class _DesktopTypographyScaler extends TextScaler {
  const _DesktopTypographyScaler(this.base);

  final TextScaler base;

  @override
  double scale(double fontSize) =>
      base.scale(CwhaleTheme.desktopFontSize(fontSize));

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  TextScaler clamp({
    double minScaleFactor = 0,
    double maxScaleFactor = double.infinity,
  }) => _DesktopTypographyScaler(
    base.clamp(minScaleFactor: minScaleFactor, maxScaleFactor: maxScaleFactor),
  );

  @override
  bool operator ==(Object other) =>
      other is _DesktopTypographyScaler && other.base == base;

  @override
  int get hashCode => base.hashCode;
}

class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  final _store = LocalStore();
  bool? _showOnboarding;

  @override
  void initState() {
    super.initState();
    _resolveStartup();
  }

  Future<void> _resolveStartup() async {
    try {
      final settings = await _store.loadSettings();
      CwhaleTheme.darkMode.value = settings.useDarkTheme;

      var completed = await _store.hasCompletedOnboarding();
      if (!completed) {
        if (await _store.hasStartedOnboarding()) {
          // Resume onboarding even if the user already saved a key or imported
          // conversations during an earlier, interrupted first run.
          await _store.markOnboardingStarted();
        } else if (await _store.hasExistingLocalData()) {
          // Preserve the existing local-first experience on app upgrades.
          await _store.markOnboardingCompleted();
          completed = true;
        } else {
          await _store.markOnboardingStarted();
        }
      }
      if (mounted) setState(() => _showOnboarding = !completed);
    } catch (_) {
      // Storage errors must not prevent access to existing chats.
      if (mounted) setState(() => _showOnboarding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showOnboarding = _showOnboarding;
    if (showOnboarding == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!showOnboarding) return const ChatScreen();
    return OnboardingFlowPage(
      onCompleted: () {
        if (mounted) setState(() => _showOnboarding = false);
      },
    );
  }
}
