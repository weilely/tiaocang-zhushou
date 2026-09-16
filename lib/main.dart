import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/biometric_gate.dart';
import 'ui/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..init(),
      child: const InvestTrackerApp(),
    ),
  );
}

class InvestTrackerApp extends StatelessWidget {
  const InvestTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '调仓助手',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // 真机上把系统字体调很大时，行内数字会被挤到换行 / 溢出。
      // 这里把缩放卡在 1.3 倍以内：尊重「稍微大一点」的需求，又不会被拉爆版式。
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: BiometricGate(child: child ?? const SizedBox.shrink()),
      ),
      home: const HomeShell(),
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final isLight = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1F6FEB),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: isLight ? const Color(0xFFF3F4F6) : const Color(0xFF121417),
    cardColor: isLight ? Colors.white : const Color(0xFF1B1E22),
    appBarTheme: AppBarTheme(
      backgroundColor: isLight ? Colors.white : const Color(0xFF1B1E22),
      surfaceTintColor: Colors.transparent,
      elevation: 0.5,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isLight ? Colors.white : const Color(0xFF1B1E22),
      surfaceTintColor: Colors.transparent,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    listTileTheme: const ListTileThemeData(dense: false),
    dividerTheme: const DividerThemeData(space: 1, thickness: 0.5),
  );
}
