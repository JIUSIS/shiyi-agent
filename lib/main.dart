import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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

class _TextUnfocusCandidate {
  final FocusNode focus;
  final Offset start;
  final Duration downAt;
  bool cancelled = false;

  _TextUnfocusCandidate({
    required this.focus,
    required this.start,
    required this.downAt,
  });
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

  /// 首启启动序列：权限 → 回到前台 → 状态初始化。
  /// 欢迎页等它完成才进主页，避免「权限还没给完就进了软件」。
  late final Future<void> _startup;
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final _RuntimeRouteObserver _routeObserver = _RuntimeRouteObserver();
  final Map<int, _TextUnfocusCandidate> _outsideTextDismiss = {};

  @override
  void initState() {
    super.initState();
    shiyi = ShiyiState();
    _themeModeSetting = widget.initialThemeMode;
    shiyi.addListener(_handleShiyiChanged);
    _startup = _bootstrap();
    // 冷启动立即体检，与欢迎动画并行，不等主页出现再拉服务。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkDshOnLaunch());
    });
  }

  /// 首启顺序：权限全部走完（含「所有文件访问」设置页）→ 回到前台 →
  /// 再初始化状态。以前是 `runApp` 之后并发请求权限，初始化和系统弹窗
  /// 抢前台，首启会出现「初始化失败」和「权限没给完就进主页」。
  Future<void> _bootstrap() async {
    try {
      // 权限流程加个上限：任何一次系统调用卡住都不能让 App 停在欢迎页。
      // 超时后仍会等回到前台再初始化，不会在后台跑初始化。
      await PermissionService.ensureOnLaunch().timeout(
        const Duration(seconds: 60),
      );
    } catch (_) {}
    await _waitForForeground();
    await shiyi.init();
  }

  /// 等 App 回到前台：授权设置页停留期间不要跑初始化。
  Future<void> _waitForForeground() async {
    final binding = WidgetsBinding.instance;
    for (var i = 0; i < 300; i++) {
      final state = binding.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) return;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
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
    if (shiyi.settings.agentEngine != 'dsh') return;
    if (!DshService.instance.managesLocalProcess) {
      await DshService.instance.refreshStatus();
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

  Rect? _focusedTextRect(FocusNode? focus) {
    final context = focus?.context;
    if (context == null) return null;
    // 用整个输入框（TextField / CupertinoTextField / TextFormField）的
    // 范围判定“点外面”，不要用最里层 EditableText 的文字核心，否则带图标、
    // 标签、内边距的输入框会把框内空白误判成框外。
    RenderBox? box;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is TextField ||
          widget is CupertinoTextField ||
          widget is TextFormField) {
        final renderObject = element.renderObject;
        if (renderObject is RenderBox) box = renderObject;
        return false;
      }
      return true;
    });
    if (box == null) {
      final renderObject = context.findRenderObject();
      if (renderObject is RenderBox) box = renderObject;
    }
    final resolved = box;
    if (resolved == null) return null;
    final origin = resolved.localToGlobal(Offset.zero);
    return origin & resolved.size;
  }

  bool _hasVisibleTextSelection() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return false;
    var visible = false;
    void visit(Element element) {
      if (visible) return;
      final type = element.widget.runtimeType.toString();
      if (type.contains('TextSelectionToolbar') ||
          type.contains('SelectionHandle')) {
        visible = true;
        return;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return visible;
  }

  void _onTextDismissPointerDown(PointerDownEvent event) {
    final focus = FocusManager.instance.primaryFocus;
    final rect = _focusedTextRect(focus);
    if (focus == null || rect == null) return;
    if (rect.contains(event.position)) {
      _outsideTextDismiss.remove(event.pointer);
      return;
    }
    _outsideTextDismiss[event.pointer] = _TextUnfocusCandidate(
      focus: focus,
      start: event.position,
      downAt: event.timeStamp,
    );
  }

  void _onTextDismissPointerMove(PointerMoveEvent event) {
    final candidate = _outsideTextDismiss[event.pointer];
    if (candidate == null) return;
    if ((event.position - candidate.start).distance > 24) {
      candidate.cancelled = true;
    }
  }

  void _onTextDismissPointerUp(PointerUpEvent event) {
    final candidate = _outsideTextDismiss.remove(event.pointer);
    if (candidate == null || candidate.cancelled) return;
    if (event.timeStamp - candidate.downAt >
        const Duration(milliseconds: 600)) {
      return;
    }
    if (!candidate.focus.hasFocus) return;
    // 选择菜单 / 手柄还在时，点它外面可能是要点“复制、粘贴”，先不抢焦点，
    // 否则菜单会一收一弹，复制不了。
    if (_hasVisibleTextSelection()) return;
    final rect = _focusedTextRect(candidate.focus);
    if (rect == null || rect.contains(event.position)) return;
    final focus = candidate.focus;
    scheduleMicrotask(() {
      if (focus.hasFocus) {
        focus.unfocus(disposition: UnfocusDisposition.scope);
      }
    });
  }

  void _onTextDismissPointerCancel(PointerCancelEvent event) {
    _outsideTextDismiss.remove(event.pointer);
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
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
      locale: const Locale('zh'),
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
        // 点击输入框之外的轻点才失焦；长按、拖动选择、复制工具条不打断。
        content = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onTextDismissPointerDown,
          onPointerMove: _onTextDismissPointerMove,
          onPointerUp: _onTextDismissPointerUp,
          onPointerCancel: _onTextDismissPointerCancel,
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
      home: WelcomeScreen(shiyi: shiyi, startup: _startup),
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
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
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
