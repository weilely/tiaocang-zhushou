import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/biometric_gate.dart';
import 'ui/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // **全局竖屏**：这一版所有页面都是按竖屏排的（列表、底部导航、卡片），
  // 手机一横过来版式就塌（2026-09-29 在模拟器上把 400×880 转成 880×400 时
  // 一眼看到「指数看板」被拉横的样子）。唯一需要横屏的是「历史曲线」那张图 ——
  // 它自己那一页会临时放开横屏，退出时再锁回竖屏（见 `ui/macro_chart_page.dart`）。
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  runApp(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..init(),
      child: const InvestTrackerApp(),
    ),
  );
}

class InvestTrackerApp extends StatelessWidget {
  const InvestTrackerApp({super.key});

  static ThemeMode _modeOf(String m) => switch (m) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    return MaterialApp(
      title: '调仓助手',
      debugShowCheckedModeBanner: false,
      themeMode: _modeOf(st.themeMode),
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
