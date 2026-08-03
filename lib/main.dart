import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_state.dart';
import 'services/permission_service.dart';
import 'core/app_theme.dart';
import 'screens/welcome_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialThemeMode = await _readInitialThemeMode();
  runApp(ShiyiAgentApp(initialThemeMode: initialThemeMode));
  unawaited(PermissionService.ensureOnLaunch());
}

/// 在首帧渲染前读取持久化的主题设置，避免先按默认深色主题渲染造成闪黑。
Future<String> _readInitialThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('shiyi_settings_v1');
    if (raw == null || raw.isEmpty) return 'dark';
    final value = jsonDecode(raw);
    if (value is Map && value['themeMode'] is String) {
      return value['themeMode'] as String;
    }
    return 'dark';
  } catch (_) {
    return 'dark';
  }
}

class ShiyiAgentApp extends StatefulWidget {
  final String initialThemeMode;
  const ShiyiAgentApp({super.key, required this.initialThemeMode});

  @override
  State<ShiyiAgentApp> createState() => _ShiyiAgentAppState();
}

class _ShiyiAgentAppState extends State<ShiyiAgentApp> {
  late final ShiyiState shiyi;

  @override
  void initState() {
    super.initState();
    shiyi = ShiyiState();
    shiyi.init();
  }

  ThemeMode _resolveThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.dark;
    }
  }

  void _syncStatusBar(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: isDark
            ? const Color(0xFF1E1E20)
            : const Color(0xFFF2F2F7),
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: shiyi,
      builder: (context, _) {
        // 设置异步加载完成前，用启动时读到的主题渲染首帧，避免闪黑/闪白。
        final mode = shiyi.loaded
            ? shiyi.settings.themeMode
            : widget.initialThemeMode;
        final themeMode = _resolveThemeMode(mode);
        final platformDark =
            MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        final isDark =
            themeMode == ThemeMode.dark ||
            (themeMode == ThemeMode.system && platformDark);
        // 状态栏/导航栏亮度与主题同步。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _syncStatusBar(isDark ? Brightness.dark : Brightness.light);
        });
        return MaterialApp(
          title: '拾忆',
          debugShowCheckedModeBanner: false,
          theme: MacTheme.light(),
          darkTheme: MacTheme.dark(),
          themeMode: themeMode,
          home: WelcomeScreen(shiyi: shiyi),
        );
      },
    );
  }
}
