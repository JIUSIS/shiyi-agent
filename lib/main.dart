import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_state.dart';
import 'core/media_query_fix.dart';
import 'services/permission_service.dart';
import 'core/app_theme.dart';
import 'services/dsh_service.dart';
import 'services/runtime_logger.dart';
import 'screens/welcome_screen.dart';
import 'widgets/macos_window_buttons.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      RuntimeLogger.instance.error(
        'Flutter',
        'uncaught_error',
        result: 'failed',
        data: {
          'exception': '${details.exception}',
          'stack': '${details.stack ?? ''}',
        },
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      RuntimeLogger.instance.error(
        'Dart',
        'uncaught_error',
        result: 'failed',
        data: {'exception': '$error', 'stack': '$stack'},
      ),
    );
    return true;
  };
  // 强制 edge-to-edge：状态栏/导航栏透明沉浸（targetSdk 35+ 系统强制，
  // 显式开启保持旧版本一致体验）。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final initialThemeMode = await _readInitialThemeMode();
  unawaited(
    RuntimeLogger.instance.info(
      'App',
      'startup',
      data: {'platform': Platform.operatingSystem, 'version': '2.6.1'},
    ),
  );
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

bool _focusUsesTextInput(FocusNode? focus) {
  if (focus == null || !focus.hasFocus) return false;
  final focusContext = focus.context;
  if (focusContext == null) return false;
  return focusContext.widget is EditableText ||
      focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
}

class ShiyiAgentApp extends StatefulWidget {
  final String initialThemeMode;
  const ShiyiAgentApp({super.key, required this.initialThemeMode});

  @override
  State<ShiyiAgentApp> createState() => _ShiyiAgentAppState();
}

class _ShiyiAgentAppState extends State<ShiyiAgentApp> {
  late final ShiyiState shiyi;
  late String _themeModeSetting;
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final _RuntimeRouteObserver _routeObserver = _RuntimeRouteObserver();

  @override
  void initState() {
    super.initState();
    shiyi = ShiyiState();
    _themeModeSetting = widget.initialThemeMode;
    shiyi.addListener(_handleShiyiChanged);
    shiyi.init();
    // 冷启动立即体检，与欢迎动画并行，不等主页出现再拉服务。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkDshOnLaunch());
    });
  }

  Future<void> _checkDshOnLaunch() async {
    if (!Platform.isAndroid) return;
    if (!shiyi.loaded) {
      void onLoaded() {
        shiyi.loadedNotifier.removeListener(onLoaded);
        unawaited(_checkDshOnLaunch());
      }

      shiyi.loadedNotifier.addListener(onLoaded);
      return;
    }
    DshService.instance.applyConnection(shiyi.settings);
    if (!DshService.instance.managesLocalProcess) {
      if (shiyi.settings.agentEngine == 'dsh') {
        await DshService.instance.refreshStatus();
      }
      return;
    }
    final ok = await DshService.instance.ensureAvailableOnLaunch();
    if (ok) return;
    _messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('DeepSeek Harness 未安装，请到 Agent 引擎页安装')),
    );
  }

  void _handleShiyiChanged() {
    final nextMode = shiyi.loaded
        ? shiyi.settings.themeMode
        : widget.initialThemeMode;
    if (nextMode == _themeModeSetting || !mounted) return;
    setState(() => _themeModeSetting = nextMode);
  }

  @override
  void dispose() {
    shiyi.removeListener(_handleShiyiChanged);
    super.dispose();
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
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = _resolveThemeMode(_themeModeSetting);
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
      navigatorObservers: [_routeObserver],
      scaffoldMessengerKey: _messengerKey,
      theme: MacTheme.light(),
      darkTheme: MacTheme.dark(),
      themeMode: themeMode,
      // Windows 无边框窗口：全局顶部挂 macOS 风格标题栏（红黄绿三键），
      // 所有路由页面都在标题栏下方。Android 小窗先修正异常 MediaQuery padding。
      builder: (context, child) {
        Widget content = child ?? const SizedBox.shrink();
        if (Platform.isWindows) {
          content = Column(
            children: [
              const MacTitleBar(),
              Expanded(child: content),
            ],
          );
        }
        // 点击当前输入框之外的位置时释放焦点，避免光标和输入法残留。
        content = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            final focus = FocusManager.instance.primaryFocus;
            final renderObject = focus?.context?.findRenderObject();
            if (focus == null || renderObject is! RenderBox) return;
            final origin = renderObject.localToGlobal(Offset.zero);
            final rect = origin & renderObject.size;
            if (!rect.contains(event.position)) {
              focus.unfocus(disposition: UnfocusDisposition.scope);
            }
          },
          child: content,
        );
        // 小米 HyperOS 小窗会把 viewPadding.top 报成窗口高度，SafeArea 把界面挤没。
        final media = adaptSmallScreenText(
          sanitizeMediaQuery(
            MediaQuery.of(context),
            keyboardExpected: _focusUsesTextInput(
              FocusManager.instance.primaryFocus,
            ),
          ),
        );
        return MediaQuery(data: media, child: content);
      },
      home: WelcomeScreen(shiyi: shiyi),
    );
  }
}

/// 观察根导航器，把当前页面（route）反馈给 RuntimeLogger，让错误日志带上
/// 「在哪一屏出错」。best-effort：无 name 的路由用运行时类型作标签。
class _RuntimeRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    RuntimeLogger.instance.uiRoute(_labelFor(route));
  }

  @override
  void didReplace({
    Route<dynamic>? newRoute,
    Route<dynamic>? oldRoute,
  }) {
    if (newRoute != null) RuntimeLogger.instance.uiRoute(_labelFor(newRoute));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    RuntimeLogger.instance.uiRoute(_labelFor(previousRoute));
  }

  static String _labelFor(Route<dynamic>? route) {
    if (route == null) return '';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return route.runtimeType.toString();
  }
}
