import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'chat_screen.dart';
import 'generation_protection.dart';

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
      return MaterialApp(
        title: 'Cwhale',
        debugShowCheckedModeBanner: false,
        theme: CwhaleTheme.light,
        darkTheme: CwhaleTheme.dark,
        themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
        home: const ChatScreen(),
      );
    },
  );
}
