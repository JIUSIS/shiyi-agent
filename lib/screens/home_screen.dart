import 'dart:async';
import 'dart:io';

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/home_list_order.dart';
import '../core/home_tabs.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../services/dsh_endpoint.dart';
import '../services/dsh_service.dart';
import '../services/update_service.dart';
import '../widgets/home_drag.dart';
import '../widgets/home_group_chats.dart';
import '../widgets/home_group_header.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/staggered_sessions.dart';
import '../widgets/swipe_actions.dart';
import '../widgets/traffic_lights_button.dart';
import '../widgets/welcome_avatar.dart';
import 'chat_screen.dart';
import 'dsh_center_screen.dart';
import 'dsh_features_tab.dart';
import 'dsh_files_tab.dart';
import 'dsh_workspaces_tab.dart';
import 'features_screen.dart';
import 'files_screen.dart';
import 'project_actions.dart';
import 'settings_screen.dart';
import 'terminal_screen.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosRed = Color(0xFFFF3B30);
const _iosGray = Color(0xFF8E8E93);

const shiyiProjectExpandedPrefsKey = 'shiyi_project_expanded_v1';

/// 拾忆会话卡片左滑：删除保持最右。
const shiyiSessionSwipeLabels = ['重命名', '项目', '复制 ID', '删除'];

/// 读回项目展开状态；键不存在返回 null（首次启动默认展开未分类）。
Future<List<String>?> shiyiLoadExpandedProjectIds() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(shiyiProjectExpandedPrefsKey);
}

Future<void> shiyiSaveExpandedProjectIds(Iterable<String> ids) async {
  final prefs = await SharedPreferences.getInstance();
  final list = ids.toSet().toList()..sort();
  await prefs.setStringList(shiyiProjectExpandedPrefsKey, list);
}

/// 首次无偏好只展开未分类；已保存的 id 只保留仍存在的项目和未分类。
Set<String> shiyiRestoreExpandedProjectIds({
  required List<String>? saved,
  required Iterable<String> knownProjectIds,
}) {
  if (saved == null) return {''};
  final known = knownProjectIds.toSet()..add('');
  return saved.where(known.contains).toSet();
}

class HomeScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const HomeScreen({super.key, required this.shiyi});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _tab = 0;
  int _groupRefresh = 0;

  /// 桌面侧边栏宽度（拖拽把手调整，150~300）。
  double _sidebarWidth = 190;
  final int _sessionsResetRevision = 0;
  // tab 懒缓存：切换过的页面保留不重建（页面切换卡顿根因=每次全量重建+DB重查）。
  final Map<int, Widget> _tabCache = {};
  String _lastDshPageKey = '';
  // 切换淡入：IndexedStack 常驻全部 tab，切换零构建、立即响应。
  late final AnimationController _fadeController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _fadeController,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastAgentEngine = widget.shiyi.settings.agentEngine;
    _lastDshPageKey = _dshPageKey();
    _fadeController.value = 1;
    _prebuildTabs();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleLaunchUpdateCheck();
    });
    // Agent 引擎切换（拾忆/DSH）时：tab 内容随引擎变化，清缓存重建。
    widget.shiyi.addListener(_onShiyiEngineChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.shiyi.removeListener(_onShiyiEngineChanged);
    widget.shiyi.loadedNotifier.removeListener(_onLoadedForUpdateCheck);
    _fadeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.detached) {
      // 进程销毁（杀后台/卸载等）时按用户开关决定是否停 DSH；
      // 仅退后台不杀，避免每次重开都等 dsh 冷启动。
      if (widget.shiyi.settings.dshStopOnExit &&
          DshService.instance.managesLocalProcess) {
        unawaited(DshService.instance.stop());
      }
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_checkDshOnLaunch());
    }
  }

  /// 打开 app 时自动体检：未安装提示；未开启自动拉起；已开启刷新状态。
  Future<void> _checkDshOnLaunch() async {
    DshService.instance.applyConnection(widget.shiyi.settings);
    if (!DshService.instance.managesLocalProcess) {
      if (widget.shiyi.settings.agentEngine == 'dsh') {
        await DshService.instance.refreshStatus();
      }
      return;
    }
    final ok = await DshService.instance.ensureAvailableOnLaunch();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('DeepSeek Harness 未安装，请到 Agent 引擎页安装')),
      );
    }
  }

  String _lastAgentEngine = 'shiyi';

  void _onShiyiEngineChanged() {
    final engine = widget.shiyi.settings.agentEngine;
    final pageKey = _dshPageKey();
    final engineChanged = engine != _lastAgentEngine;
    final dshConnectionChanged = pageKey != _lastDshPageKey;
    if (!engineChanged && !dshConnectionChanged) return;
    _lastAgentEngine = engine;
    _lastDshPageKey = pageKey;
    final keep = <int, Widget>{};
    for (final i in HomeTabs.keepAcrossEngineSwitch) {
      final w = _tabCache[i];
      if (w != null) keep[i] = w;
    }
    _tabCache
      ..clear()
      ..addAll(keep);
    if (mounted) setState(() {});
  }

  /// 启动自动检查更新：等 app 初始化完成后触发，避免弹窗压住加载页。
  void _scheduleLaunchUpdateCheck() {
    if (!widget.shiyi.loaded) {
      widget.shiyi.loadedNotifier.addListener(_onLoadedForUpdateCheck);
      return;
    }
    unawaited(UpdateService.checkOnLaunch(context));
  }

  void _onLoadedForUpdateCheck() {
    if (!widget.shiyi.loaded) return;
    widget.shiyi.loadedNotifier.removeListener(_onLoadedForUpdateCheck);
    if (mounted) unawaited(UpdateService.checkOnLaunch(context));
  }

  // 启动后逐帧预构建其余 tab，首次切换不再卡顿（构建成本分摊到空闲帧）。
  void _prebuildTabs() {
    var i = 1;
    void next() {
      if (!mounted || i > HomeTabs.terminalIndex) return;
      if (!_usesLiveDshPages) {
        _tabCache[i] = _buildTabFor(i);
        setState(() {});
      }
      i++;
      WidgetsBinding.instance.addPostFrameCallback((_) => next());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => next());
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _selectTab(int tab) {
    if (tab == _tab) return;
    _dismissKeyboard();
    if (_usesLiveDshPages) {
      // 局域网 / 公网每次进入页面都重建，由页面 initState 拉取目标 DSH
      // 的最新数据，不复用手机内存中的旧页面。
      _tabCache.remove(tab);
      _tabCache.remove(_tab);
    }
    setState(() {
      _tab = tab;
      if (tab == 0) _groupRefresh++;
    });
    _fadeController.forward(from: 0);
  }

  bool get _usesLiveDshPages =>
      widget.shiyi.settings.agentEngine == 'dsh' &&
      DshEndpoint.requiresLivePageData(widget.shiyi.settings);

  String _dshPageKey() {
    final s = widget.shiyi.settings;
    return [
      s.agentEngine,
      DshEndpoint.modeOf(s),
      DshEndpoint.urlOf(s),
      s.dshRemoteHost,
      s.dshRemoteToken,
      s.dshApiSource,
    ].join('\u0000');
  }

  Future<void> _handleBack() async {
    // 非主页 tab 先退回会话页，层层返回。
    if (_tab != 0) {
      _selectTab(0);
      return;
    }
    // 已在主页，二次确认后退出。
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: CupertinoAlertDialog(
          title: const Text('退出拾忆'),
          content: const Text('确定要退出应用吗？'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      // 显式退出按用户开关决定是否停服务；退后台保持常驻，重开即用。
      if (widget.shiyi.settings.dshStopOnExit &&
          DshService.instance.managesLocalProcess) {
        await DshService.instance.stop();
      }
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shiyi = widget.shiyi;
    // Windows 宽窗口：桌面侧边导航；窄窗口/手机：底部 Tab。
    final desktopNav =
        Platform.isWindows && MediaQuery.sizeOf(context).width >= 720;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final tabBarGap = desktopNav
        ? 0.0
        : (_mobileTabBarHeight - keyboardInset)
              .clamp(0.0, _mobileTabBarHeight)
              .toDouble();
    // 引擎决定主页 tab 套件：拾忆（会话/功能/文件/终端）或 DS Harness
    //（工作数据/功能/文件/终端）。终端两端都接内嵌 proot。
    final tabs = shiyi.settings.agentEngine == 'dsh'
        ? HomeTabs.dsh
        : HomeTabs.shiyi;
    final content = ListenableBuilder(
      listenable: Listenable.merge([
        shiyi.loadedNotifier,
        shiyi.initErrorNotifier,
      ]),
      builder: (context, _) {
        if (!shiyi.loaded) {
          if (shiyi.initError != null) {
            return SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '初始化失败：${shiyi.initError}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            );
          }
          return const SafeArea(
            child: Center(child: CircularProgressIndicator()),
          );
        }
        // IndexedStack 常驻全部 tab：切换零构建、立即响应；切换时淡入。
        // 桌面宽窗口下内容区居中限宽，避免手机布局被横向拉伸。
        // 只缓存真实 tab，SizedBox 占位不入缓存：引擎切换清缓存后，
        // 首次切到某个 tab 会当场重建，不会一直显示空页。
        final stack = FadeTransition(
          opacity: _fade,
          child: IndexedStack(
            index: _tab,
            children: [
              for (var i = 0; i <= HomeTabs.terminalIndex; i++)
                if (i == _tab)
                  _tabCache[i] ??= _buildTabFor(i)
                else
                  _tabCache[i] ?? const SizedBox.shrink(),
            ],
          ),
        );
        // 裁剪在 SafeArea 内侧，会话卡片挤开位移不能画进状态栏。
        // 手机端底部 Tab 悬浮覆盖，内容留出同高空白，避免最后一张卡片被遮。
        // 键盘弹起时清掉这段空白：内层 Scaffold 已按 viewInsets 垫底，
        // 再叠 58px 会在输入法上方多出一条空带。
        if (!desktopNav) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: tabBarGap),
              child: ClipRect(child: stack),
            ),
          );
        }
        return SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: stack,
            ),
          ),
        );
      },
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      // Windows 桌面快捷键：Ctrl+N 新建会话、Ctrl+, 打开设置。
      child: Focus(
        autofocus: Platform.isWindows,
        onKeyEvent: _handleGlobalKeys,
        child: Scaffold(
          backgroundColor: iosGroupedBackground(context),
          // 键盘只应压缩当前 tab 的内容，不能把悬浮侧边栏一起压矮。
          // 终端页自己读 viewInsets 垫底，主页不整体抬底栏。
          resizeToAvoidBottomInset: false,
          body: desktopNav
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DesktopNavBar(
                      currentIndex: _tab,
                      onTap: _selectTab,
                      onOpenSettings: _openSettingsForCurrentEngine,
                      tabs: tabs,
                      width: _sidebarWidth,
                    ),
                    _SidebarResizer(
                      width: _sidebarWidth,
                      onChanged: (w) =>
                          setState(() => _sidebarWidth = w.clamp(150.0, 300.0)),
                    ),
                    Expanded(child: content),
                  ],
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    content,
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _IosTabBar(
                        currentIndex: _tab,
                        onTap: _selectTab,
                        tabs: tabs,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  void _openSettings() {
    _dismissKeyboard();
    Navigator.push(
      context,
      MacPageRoute(builder: (_) => SettingsScreen(shiyi: widget.shiyi)),
    );
  }

  /// 设置入口跟随 Agent 引擎：DS Harness 引擎下打开 DS Harness 中心
  ///（含引擎切换、模型/预设/工作区/技能/设置）；拾忆引擎下打开拾忆设置。
  void _openSettingsForCurrentEngine() {
    _dismissKeyboard();
    if (widget.shiyi.settings.agentEngine == 'dsh') {
      Navigator.push(
        context,
        MacPageRoute(builder: (_) => DshCenterScreen(shiyi: widget.shiyi)),
      );
    } else {
      _openSettings();
    }
  }

  Widget _buildTabFor(int i) {
    final shiyi = widget.shiyi;
    // Agent 引擎：DS Harness 时主页 tab 整体切换（外观复用拾忆，
    // 数据源为 DeepSeek Harness）：工作数据 / 功能 / 文件 / 终端。
    if (shiyi.settings.agentEngine == 'dsh') {
      switch (i) {
        case 0:
          return DshWorkspacesTab(shiyi: shiyi);
        case 1:
          return DshFeaturesTab(shiyi: shiyi);
        case 2:
          return buildFilesTabForEngine(shiyi);
        case 3:
          return TerminalScreen(shiyi: shiyi);
      }
      return const SizedBox.shrink();
    }
    switch (i) {
      case 0:
        return _SessionsTab(
          shiyi: shiyi,
          resetRevision: _sessionsResetRevision,
          groupRefresh: _groupRefresh,
          onOpenSettings: _openSettings,
        );
      case 1:
        return FeaturesScreen(shiyi: shiyi);
      case 2:
        return FilesScreen(shiyi: shiyi);
      case 3:
        return TerminalScreen(shiyi: shiyi);
    }
    return const SizedBox.shrink();
  }

  /// Windows 桌面快捷键（macOS 惯例：⌘ = Ctrl）：
  /// Ctrl+N 新建会话、Ctrl+, 打开设置。
  KeyEventResult _handleGlobalKeys(FocusNode node, KeyEvent event) {
    if (!Platform.isWindows || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (!HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyN:
        unawaited(_newSessionShortcut());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.comma:
        _openSettingsForCurrentEngine();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Future<void> _newSessionShortcut() async {
    if (_tab != 0) _selectTab(0);
    try {
      await widget.shiyi.newSession();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('新建会话失败：$e')));
      }
    }
  }
}

/// 返回当前 Agent 引擎对应的文件页。
/// DSH 使用主机目录 API；拾忆使用本地文件工作区。
/// 单独保留为纯路由选择点，避免两个引擎的文件数据源再次串线。
Widget buildFilesTabForEngine(ShiyiState shiyi) {
  return shiyi.settings.agentEngine == 'dsh'
      ? DshFilesTab(shiyi: shiyi)
      : FilesScreen(shiyi: shiyi);
}

/// iOS 风格底部 Tab：毛玻璃背景、选中胶囊、SF 风格图标+文字。
const double _mobileTabBarHeight = 58;

class _IosTabBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<HomeTabSpec> tabs;
  const _IosTabBar({
    required this.currentIndex,
    required this.onTap,
    required this.tabs,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final barBg = dark ? const Color(0xE61C1C1E) : const Color(0xE6F2F2F7);
    final hairline = dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    return Container(
      decoration: BoxDecoration(
        color: barBg,
        border: Border(top: BorderSide(color: hairline)),
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: _mobileTabBarHeight,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _IosTabItem(
                        icon: tabs[i].icon,
                        selectedIcon: tabs[i].selectedIcon,
                        label: tabs[i].label,
                        selected: i == currentIndex,
                        onTap: () => onTap(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IosTabItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _IosTabItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = dark
        ? const Color(0xFF0A84FF)
        : const Color(0xFF007AFF);
    final color = selected
        ? activeColor
        : (dark ? CupertinoColors.systemGrey : CupertinoColors.secondaryLabel);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 50,
              height: 30,
              decoration: BoxDecoration(
                color: selected
                    ? activeColor.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Center(
                child: Icon(
                  selected ? selectedIcon : icon,
                  size: 24,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                height: 1,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Windows 桌面侧边导航栏：宽窗口时替代底部 Tab。
/// macOS 风格：毛玻璃材质、选中项圆角高亮条、宽度可拖拽调整。
class _DesktopNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback onOpenSettings;
  final double width;
  final List<HomeTabSpec> tabs;
  const _DesktopNavBar({
    required this.currentIndex,
    required this.onTap,
    required this.onOpenSettings,
    required this.tabs,
    this.width = 190,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hairline = dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    final barBg = dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: barBg,
        border: Border(right: BorderSide(color: hairline)),
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            color: barBg.withValues(alpha: dark ? 0.82 : 0.72),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Text(
                      '拾忆',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: dark
                            ? CupertinoColors.white
                            : CupertinoColors.black,
                      ),
                    ),
                  ),
                  for (var i = 0; i < tabs.length; i++)
                    _DesktopNavItem(
                      icon: tabs[i].icon,
                      selectedIcon: tabs[i].selectedIcon,
                      label: tabs[i].label,
                      selected: i == currentIndex,
                      onTap: () => onTap(i),
                    ),
                  const Spacer(),
                  _DesktopNavItem(
                    icon: CupertinoIcons.slider_horizontal_3,
                    selectedIcon: CupertinoIcons.slider_horizontal_3,
                    label: '设置',
                    selected: false,
                    onTap: onOpenSettings,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧边栏右侧拖拽把手：拖动调整侧边栏宽度。
class _SidebarResizer extends StatelessWidget {
  final double width;
  final ValueChanged<double> onChanged;
  const _SidebarResizer({required this.width, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onChanged(width + d.delta.dx),
        child: const SizedBox(width: 6),
      ),
    );
  }
}

/// 桌面侧边导航项：图标 + 文字；选中项 macOS 风格圆角高亮条。
class _DesktopNavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DesktopNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = selected
        ? (dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF))
        : (dark ? CupertinoColors.systemGrey : CupertinoColors.secondaryLabel);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected
            ? (dark ? const Color(0x330A84FF) : const Color(0x1F0A84FF))
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          hoverColor: dark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(selected ? selectedIcon : icon, size: 19, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionsTab extends StatefulWidget {
  final ShiyiState shiyi;
  final int resetRevision;
  final int groupRefresh;
  final VoidCallback onOpenSettings;
  const _SessionsTab({
    required this.shiyi,
    required this.resetRevision,
    this.groupRefresh = 0,
    required this.onOpenSettings,
  });

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  /// 搜索防抖：避免每键一次全库查询。
  Timer? _searchDebounce;

  /// 搜索 future 缓存（按关键词）：避免同关键词重建 FutureBuilder 触发重复查询。
  String? _searchFutureKey;
  Future<List<SessionSearchResult>>? _searchFuture;

  /// 已展开的项目分组 id；空串表示「未分类」，默认展开。
  final Set<String> _expandedGroups = {''};

  /// 上次持久化的展开列表；null 表示还没有写过偏好（首次启动）。
  List<String>? _savedExpanded;
  bool _expandedRestored = false;

  /// 当前展开的左滑卡片 key；点空白或操作其他卡片时收回。
  final ValueNotifier<String?> _openSwipeKey = ValueNotifier(null);

  /// 当前展开左滑卡片的屏幕区域，用于精确识别「空白点击」。
  Rect? _openSwipeRect;

  /// 长按拖拽：会话拖到项目卡片上停顿 1 秒展开 / 显示可释放。
  final HomeDragHoverController _hover = HomeDragHoverController();
  Timer? _hoverTimer;
  String? _hoveringProjectId;
  String? _dropReadyProjectId;
  String? _draggingSessionId;
  String? _draggingProjectId;
  int? _projectPreviewFrom;
  int? _projectPreviewTo;
  String? _sessionPreviewProjectId;
  int? _sessionPreviewFrom;
  int? _sessionPreviewTo;
  bool _dropCommitted = false;
  bool _flying = false;
  bool _snapShift = false;
  bool _crossDropCommitting = false;
  Offset? _flyStartTopLeft;
  OverlayEntry? _flyEntry;
  final HomeDragOverlay _dragOverlay = HomeDragOverlay();
  List<String>? _projectOrderOverride;
  String? _sessionOrderOverrideProject;
  List<String>? _sessionOrderOverride;
  final Map<String, GlobalKey> _projectBlockKeys = {};
  final Map<String, GlobalKey> _projectHeaderKeys = {};
  final Map<String, GlobalKey> _insertGapKeys = {};
  final Map<String, GlobalKey> _sessionCardKeys = {};
  final GlobalKey _uncategorizedHeaderKey = GlobalKey();
  final List<double> _projectHeights = [];
  final List<double> _projectCenters = [];
  final List<double> _sessionHeights = [];
  final List<double> _sessionCenters = [];
  final List<double> _crossHeights = [];
  final List<double> _crossCenters = [];
  String? _crossGeometryId;
  int _crossInsertIndex = 0;
  Offset? _lastDragGlobal;
  final GlobalKey<HomeGroupChatsState> _groupChatsKey = GlobalKey();

  ShiyiState get shiyi => widget.shiyi;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreExpanded());
  }

  Future<void> _restoreExpanded() async {
    final saved = await shiyiLoadExpandedProjectIds();
    if (!mounted) return;
    setState(() {
      _savedExpanded = saved;
      _expandedRestored = true;
      _applyExpandedPrefs();
    });
  }

  void _applyExpandedPrefs() {
    if (!_expandedRestored) return;
    _expandedGroups
      ..clear()
      ..addAll(
        shiyiRestoreExpandedProjectIds(
          saved: _savedExpanded,
          knownProjectIds: shiyi.projects.map((p) => p.id),
        ),
      );
  }

  Future<void> _saveExpanded() async {
    _savedExpanded = _expandedGroups.toList();
    await shiyiSaveExpandedProjectIds(_expandedGroups);
  }

  @override
  void didUpdateWidget(covariant _SessionsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetRevision != widget.resetRevision) {
      _dismissSearch();
      _searchCtrl.clear();
      _query = '';
    }
    if (oldWidget.groupRefresh != widget.groupRefresh) {
      _groupChatsKey.currentState?.reload();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _hoverTimer?.cancel();
    _dragOverlay.remove();
    _removeFlyEntry();
    _openSwipeKey.dispose();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 输入防抖后触发搜索（250ms），旧 future 由 [_searchFuture] 缓存天然去重。
  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = v);
    });
  }

  /// 按关键词取搜索 future：同关键词复用同一 future，避免竞态覆盖。
  Future<List<SessionSearchResult>> _searchFutureFor(String q) {
    if (_searchFutureKey == q && _searchFuture != null) return _searchFuture!;
    _searchFutureKey = q;
    final future = shiyi.searchSessions(q);
    _searchFuture = future;
    return future;
  }

  void _dismissSearch() {
    _searchFocus.unfocus();
  }

  void _resetSearch() {
    _dismissSearch();
    if (_query.isEmpty && _searchCtrl.text.isEmpty) return;
    _searchCtrl.clear();
    _searchDebounce?.cancel();
    setState(() => _query = '');
  }

  void _toggleProject(String id) {
    setState(() {
      if (!_expandedGroups.add(id)) _expandedGroups.remove(id);
    });
    unawaited(_saveExpanded());
  }

  void _expandProject(String id) {
    if (_expandedGroups.contains(id)) return;
    setState(() => _expandedGroups.add(id));
    unawaited(_saveExpanded());
  }

  void _cancelHover() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    final hadHover = _hoveringProjectId != null || _dropReadyProjectId != null;
    _hoveringProjectId = null;
    _hover.onLeave();
    _dropReadyProjectId = null;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
    if (hadHover && mounted) setState(() {});
  }

  GlobalKey _keyFor(Map<String, GlobalKey> map, String id) {
    return map.putIfAbsent(id, GlobalKey.new);
  }

  void _onSessionDragStarted(
    String sessionId,
    String projectId,
    int index,
    Offset pointerGlobal,
  ) {
    if (_flying) return;
    _closeSwipe();
    _dropCommitted = false;
    _snapShift = false;
    _flying = false;
    _flyStartTopLeft = null;
    final list = [
      for (final s in shiyi.sessions)
        if (s.projectId == projectId) s.id,
    ];
    homeDragReadSlotGeometry(
      [for (final id in list) _keyFor(_sessionCardKeys, id)],
      _sessionHeights,
      _sessionCenters,
    );
    Session? session;
    for (final s in shiyi.sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    // 先读取已布局的原槽并插入拖影，再让列表进入拖拽状态，
    // 避免 setState 重建后 GlobalKey 暂时拿到零尺寸。
    if (session != null) {
      final slot = homeDragOriginSlot(_keyFor(_sessionCardKeys, sessionId));
      final feedbackHeight = homeDragCardBodyHeight(slot.$2.height);
      _showDragOverlay(
        originKey: _keyFor(_sessionCardKeys, sessionId),
        pointerGlobal: pointerGlobal,
        visualHeight: feedbackHeight,
        card: homeDragFeedbackClone(
          context,
          width: slot.$2.width,
          height: feedbackHeight,
          child: KeyedSubtree(
            key: ValueKey('lift_session_$sessionId'),
            child: _SessionTile(
              shiyi: shiyi,
              session: session,
              onBeforeOpen: () {},
              onReturn: () {},
              visualOnly: true,
            ),
          ),
        ),
      );
    }
    setState(() {
      _draggingSessionId = sessionId;
      _draggingProjectId = null;
      _sessionPreviewProjectId = projectId;
      _sessionPreviewFrom = index;
      _sessionPreviewTo = index;
      _projectPreviewFrom = null;
      _projectPreviewTo = null;
      _projectOrderOverride = null;
      _sessionOrderOverride = null;
      _sessionOrderOverrideProject = null;
    });
  }

  Future<void> _onProjectDragStarted(
    String projectId,
    int index,
    Offset pointerGlobal,
  ) async {
    if (_flying) return;
    _closeSwipe();
    _cancelHover();
    _dropCommitted = false;
    _snapShift = false;
    _flying = false;
    _flyStartTopLeft = null;
    homeDragReadSlotGeometry(
      [for (final p in shiyi.projects) _keyFor(_projectBlockKeys, p.id)],
      _projectHeights,
      _projectCenters,
    );
    Project? project;
    for (final p in shiyi.projects) {
      if (p.id == projectId) {
        project = p;
        break;
      }
    }
    final count = [
      for (final s in shiyi.sessions)
        if (s.projectId == projectId) s,
    ].length;
    final headerKey = _keyFor(_projectHeaderKeys, projectId);
    final headerSlot = homeDragOriginSlot(headerKey);
    final wasExpanded = _expandedGroups.contains(projectId);
    // 先按项目头的真实尺寸插入拖影；展开项目在这一帧收起，
    // 避免把下面整串会话一起当成项目卡片拖走。
    _showDragOverlay(
      originKey: headerKey,
      pointerGlobal: pointerGlobal,
      card: homeDragFeedbackClone(
        context,
        width: headerSlot.$2.width,
        height: headerSlot.$2.height,
        child: KeyedSubtree(
          key: ValueKey('lift_project_$projectId'),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: iosSectionBackground(context),
              borderRadius: BorderRadius.circular(14),
            ),
            child: HomeGroupHeader(
              name: project?.name ?? '',
              count: count,
              expanded: false,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    setState(() {
      if (wasExpanded) _expandedGroups.remove(projectId);
      _draggingSessionId = null;
      _draggingProjectId = projectId;
      _projectPreviewFrom = index;
      _projectPreviewTo = index;
      _sessionPreviewProjectId = null;
      _sessionPreviewFrom = null;
      _sessionPreviewTo = null;
      _projectOrderOverride = null;
      _sessionOrderOverride = null;
      _sessionOrderOverrideProject = null;
    });
    if (wasExpanded) {
      homeDragCollapseSlot(
        heights: _projectHeights,
        centers: _projectCenters,
        index: index,
        collapsedHeight: homeDragCollapsedProjectSlotHeight(
          headerSlot.$2.height,
        ),
      );
      unawaited(_saveExpanded());
    }
  }

  void _prepareCrossDropCommit() {
    _crossDropCommitting = true;
    _snapShift = true;
    _hoverTimer?.cancel();
    _hoverTimer = null;
    _hoveringProjectId = null;
    _hover.onLeave();
    _dropReadyProjectId = null;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
  }

  void _clearDragPreview() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    _hoveringProjectId = null;
    _hover.onLeave();
    _dropReadyProjectId = null;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
    _draggingSessionId = null;
    _draggingProjectId = null;
    _projectPreviewFrom = null;
    _projectPreviewTo = null;
    _sessionPreviewProjectId = null;
    _sessionPreviewFrom = null;
    _sessionPreviewTo = null;
    _dropCommitted = false;
    _flying = false;
    _crossDropCommitting = false;
    _flyStartTopLeft = null;
  }

  void _clearOrderOverride() {
    _projectOrderOverride = null;
    _sessionOrderOverride = null;
    _sessionOrderOverrideProject = null;
    // 提交后保持贴齐，避免下一次触碰把旧位移再弹回去。
  }

  void _removeFlyEntry() {
    _flyEntry?.remove();
    _flyEntry = null;
  }

  void _removeDragVisuals() {
    _dragOverlay.remove();
    _removeFlyEntry();
  }

  void _showDragOverlay({
    required GlobalKey originKey,
    required Widget card,
    Offset? pointerGlobal,
    double? visualHeight,
    Alignment scaleAlignment = Alignment.center,
  }) {
    if (!kHomeDragOwnedOverlay) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final (originTopLeft, size) = homeDragOriginSlot(originKey);
    if (size == Size.zero) return;
    _dragOverlay.show(
      overlay,
      topLeft: originTopLeft,
      size: size,
      visualHeight: visualHeight,
      pointerGlobal: pointerGlobal,
      scaleAlignment: scaleAlignment,
      child: card,
    );
    _flyStartTopLeft = originTopLeft;
  }

  void _followDragOverlay(Offset global, {required double height}) {
    if (!kHomeDragOwnedOverlay || !_dragOverlay.isShowing) return;
    _dragOverlay.followGlobal(global);
    _flyStartTopLeft = Offset(_dragOverlay.left, _dragOverlay.top);
  }

  double get _draggedProjectHeight {
    final from = _projectPreviewFrom;
    if (from == null || from >= _projectHeights.length) return 56;
    return _projectHeights[from];
  }

  double get _draggedSessionHeight {
    final from = _sessionPreviewFrom;
    if (from == null || from >= _sessionHeights.length) return 68;
    return _sessionHeights[from];
  }

  Rect? _globalRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  String? _projectAtGlobal(Offset global) {
    for (final project in _visibleProjects) {
      final rect = _globalRect(_keyFor(_projectBlockKeys, project.id));
      if (rect?.contains(global) == true) return project.id;
    }
    if (_globalRect(_uncategorizedHeaderKey)?.contains(global) == true) {
      return '';
    }
    for (final session in shiyi.sessions) {
      if (session.projectId != '') continue;
      if (_globalRect(
            _keyFor(_sessionCardKeys, session.id),
          )?.contains(global) ==
          true) {
        return '';
      }
    }
    return null;
  }

  void _updateProjectPreviewFromGlobal(Offset global) {
    if (_flying || _dropCommitted) return;
    _lastDragGlobal = global;
    _followDragOverlay(global, height: _draggedProjectHeight);
    _refreshProjectGeometry();
    final from = _projectPreviewFrom;
    if (from == null || _projectCenters.isEmpty) return;
    final dest = homeDragIndexFromCenters(
      y: global.dy,
      centers: _projectCenters,
      from: from,
    );
    if (_projectPreviewTo == dest) return;
    setState(() => _projectPreviewTo = dest);
  }

  void _updateSessionPreviewFromGlobal(Offset global) {
    if (_flying || _dropCommitted) return;
    _lastDragGlobal = global;
    _followDragOverlay(global, height: _draggedSessionHeight);
    final currentProject = _sessionPreviewProjectId;
    final hoverProject = _projectAtGlobal(global);
    final crossProject = homeDragIsCrossProjectHover(
      currentId: currentProject,
      hoverId: hoverProject,
    );
    if (!crossProject && _hoveringProjectId != null) {
      _cancelHover();
    }
    if (crossProject) {
      final target = hoverProject;
      if (target == null) return;
      _onHoverProject(target, expanded: _expandedGroups.contains(target));
      _updateCrossInsertFromGlobal(target, global);
      return;
    }
    _refreshSessionGeometry();
    final from = _sessionPreviewFrom;
    if (from == null || _sessionCenters.isEmpty) return;
    final dest = homeDragIndexFromCenters(
      y: global.dy,
      centers: _sessionCenters,
      from: from,
    );
    if (_sessionPreviewTo == dest) return;
    setState(() => _sessionPreviewTo = dest);
  }

  Future<void> _flyThen({
    required double destDy,
    required GlobalKey originKey,
    required Widget card,
    required VoidCallback applyOverride,
    required Future<void> Function() persist,
    Alignment scaleAlignment = Alignment.center,
  }) async {
    final (originTopLeft, originSize) = homeDragOriginSlot(originKey);
    final start = _flyStartTopLeft ?? originTopLeft;
    final destTop = originTopLeft.dy + destDy;
    final destination = Offset(originTopLeft.dx, destTop);
    setState(() => _flying = true);
    if (kHomeDragOwnedOverlay && _dragOverlay.isShowing) {
      await _dragOverlay.flyTo(destination);
    } else {
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay != null && originSize != Size.zero) {
        _removeFlyEntry();
        _flyEntry = OverlayEntry(
          builder: (_) => IgnorePointer(
            child: HomeDragFlyLayer(
              top: start.dy,
              destTop: destTop,
              left: start.dx,
              destLeft: destination.dx,
              width: originSize.width,
              flying: true,
              scaleAlignment: scaleAlignment,
              child: card,
            ),
          ),
        );
        overlay.insert(_flyEntry!);
        await Future<void>.delayed(kHomeDragFlyDuration);
      }
    }
    if (!mounted) {
      _removeDragVisuals();
      _flying = false;
      return;
    }
    if (kHomeDragSnapOnCommit) {
      _snapShift = true;
      applyOverride();
      _clearDragPreview();
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await persist();
      if (!mounted) return;
      setState(_clearOrderOverride);
      await WidgetsBinding.instance.endOfFrame;
      return;
    }
    applyOverride();
    _clearDragPreview();
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    await persist();
    if (!mounted) return;
    setState(_clearOrderOverride);
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _commitProjectDrag() async {
    if (_dropCommitted) return;
    _dropCommitted = true;
    final from = _projectPreviewFrom;
    final to = _projectPreviewTo;
    _hoverTimer?.cancel();
    if (homeDragShouldFly(from: from, to: to)) {
      final destDy = homeDragSlotDestDy(
        from: from!,
        to: to!,
        heights: _projectHeights,
      );
      final ids = shiyi.projects.map((p) => p.id).toList();
      final changed = from != to;
      final next = changed ? moveIdToIndex(ids, ids[from], to) : ids;
      final id = ids[from];
      Project? project;
      for (final p in shiyi.projects) {
        if (p.id == id) {
          project = p;
          break;
        }
      }
      final count = [
        for (final s in shiyi.sessions)
          if (s.projectId == id) s,
      ].length;
      await _flyThen(
        destDy: destDy,
        originKey: _keyFor(_projectHeaderKeys, id),
        card: homeDragFeedbackClone(
          context,
          width: homeDragOriginSlot(_keyFor(_projectHeaderKeys, id)).$2.width,
          child: KeyedSubtree(
            key: ValueKey('fly_project_$id'),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: iosSectionBackground(context),
                borderRadius: BorderRadius.circular(14),
              ),
              child: HomeGroupHeader(
                name: project?.name ?? '',
                count: count,
                expanded: _expandedGroups.contains(id),
                onTap: () {},
              ),
            ),
          ),
        ),
        applyOverride: () {
          if (changed) _projectOrderOverride = next;
        },
        persist: () => changed ? shiyi.reorderProjects(next) : Future.value(),
      );
      return;
    }
    if (!mounted) return;
    await _dragOverlay.land();
    setState(_clearDragPreview);
  }

  Future<void> _commitSessionDrag([Offset? global]) async {
    if (_dropCommitted) return;
    if (global != null) {
      _updateSessionPreviewFromGlobal(global);
    }
    _dropCommitted = true;
    final from = _sessionPreviewFrom;
    final to = _sessionPreviewTo;
    final projectId = _sessionPreviewProjectId;
    final sessionId = _draggingSessionId;
    final dropReady = _dropReadyProjectId;
    _hoverTimer?.cancel();
    if (kHomeDragCrossProjectNeedsDropReady &&
        sessionId != null &&
        dropReady != null &&
        dropReady != projectId) {
      await _flyCrossProjectThenDrop(
        sessionId: sessionId,
        toProjectId: dropReady,
        toIndex: _crossInsertIndex,
      );
      return;
    }
    if (projectId != null && homeDragShouldFly(from: from, to: to)) {
      final destDy = homeDragSlotDestDy(
        from: from!,
        to: to!,
        heights: _sessionHeights,
      );
      final list = [
        for (final s in shiyi.sessions)
          if (s.projectId == projectId) s.id,
      ];
      final changed = from != to;
      final next = changed ? moveIdToIndex(list, list[from], to) : list;
      final flyingId = list[from];
      Session? session;
      for (final s in shiyi.sessions) {
        if (s.id == flyingId) {
          session = s;
          break;
        }
      }
      final flySlot = homeDragOriginSlot(_keyFor(_sessionCardKeys, flyingId));
      final flyHeight = homeDragCardBodyHeight(flySlot.$2.height);
      await _flyThen(
        destDy: destDy,
        originKey: _keyFor(_sessionCardKeys, flyingId),
        card: homeDragFeedbackClone(
          context,
          width: flySlot.$2.width,
          height: flyHeight,
          child: KeyedSubtree(
            key: ValueKey('fly_session_$flyingId'),
            child: session == null
                ? const SizedBox.shrink()
                : _SessionTile(
                    shiyi: shiyi,
                    session: session,
                    onBeforeOpen: () {},
                    onReturn: () {},
                    visualOnly: true,
                  ),
          ),
        ),
        applyOverride: () {
          if (!changed) return;
          _sessionOrderOverrideProject = projectId;
          _sessionOrderOverride = next;
        },
        persist: () =>
            changed ? _persistSessionOrder(projectId, next) : Future.value(),
      );
      return;
    }
    if (!mounted) return;
    await _dragOverlay.land();
    setState(_clearDragPreview);
  }

  void _scheduleHoverTick(String projectId, {required bool expanded}) {
    _hoverTimer?.cancel();
    void fire() {
      if (!mounted || _draggingSessionId == null) return;
      final tick = _hover.tick(DateTime.now(), expanded: expanded);
      if (!expanded && tick.autoExpand) {
        _expandProject(projectId);
        _hover.onExpanded(projectId, DateTime.now());
        _scheduleHoverTick(projectId, expanded: true);
        return;
      }
      if (expanded && tick.dropReady) {
        if (_dropReadyProjectId != projectId) {
          _ensureCrossGeometry(projectId);
          final last = _lastDragGlobal;
          if (last != null && _crossGeometryId == projectId) {
            _crossInsertIndex = homeDragInsertIndexFromCenters(
              y: last.dy,
              centers: _crossCenters,
            );
          }
          setState(() => _dropReadyProjectId = projectId);
        }
        return;
      }
      _hoverTimer = Timer(const Duration(milliseconds: 80), fire);
    }

    _hoverTimer = Timer(kHomeDragHoverDelay, fire);
  }

  void _onHoverProject(String projectId, {required bool expanded}) {
    if (_draggingSessionId == null) return;
    if (_hoveringProjectId == projectId) return;
    _hoveringProjectId = projectId;
    _hover.onEnter(projectId, DateTime.now());
    _sessionPreviewTo = _sessionPreviewFrom;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
    setState(() {
      if (_dropReadyProjectId != null && _dropReadyProjectId != projectId) {
        _dropReadyProjectId = null;
      }
    });
    _scheduleHoverTick(projectId, expanded: expanded);
  }

  List<String> _sessionIdsInProject(String projectId) {
    return [
      for (final s in _sessionsForProject(projectId, [
        for (final s in shiyi.sessions)
          if (s.projectId == projectId) s,
      ]))
        s.id,
    ];
  }

  void _refreshProjectGeometry() {
    homeDragReadSlotGeometry(
      [for (final p in _visibleProjects) _keyFor(_projectBlockKeys, p.id)],
      _projectHeights,
      _projectCenters,
    );
  }

  void _refreshSessionGeometry() {
    final projectId = _sessionPreviewProjectId;
    if (projectId == null) return;
    final ids = _sessionIdsInProject(projectId);
    homeDragReadSlotGeometry(
      [for (final id in ids) _keyFor(_sessionCardKeys, id)],
      _sessionHeights,
      _sessionCenters,
    );
  }

  void _ensureCrossGeometry(String projectId) {
    final ids = _sessionIdsInProject(projectId);
    if (ids.isEmpty) {
      _crossGeometryId = projectId;
      _crossHeights.clear();
      _crossCenters.clear();
      return;
    }
    if (homeDragReadSlotGeometry(
      [for (final id in ids) _keyFor(_sessionCardKeys, id)],
      _crossHeights,
      _crossCenters,
    )) {
      _crossGeometryId = projectId;
    }
  }

  void _updateCrossInsertFromGlobal(String projectId, Offset global) {
    if (!_expandedGroups.contains(projectId)) return;
    _ensureCrossGeometry(projectId);
    if (_crossGeometryId != projectId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _hoveringProjectId != projectId) return;
        _ensureCrossGeometry(projectId);
        if (_crossGeometryId != projectId) return;
        _updateCrossInsertFromGlobal(projectId, global);
      });
      return;
    }
    final dest = homeDragInsertIndexFromCenters(
      y: global.dy,
      centers: _crossCenters,
    );
    if (_crossInsertIndex == dest) return;
    setState(() => _crossInsertIndex = dest);
  }

  Future<void> _persistSessionOrder(String projectId, List<String> next) async {
    final others = [
      for (final s in shiyi.sessions)
        if (s.projectId != projectId) s.id,
    ];
    await shiyi.reorderSessions([...next, ...others]);
  }

  double _insertGapHeight(String projectId) {
    final dragging = _draggingSessionId;
    final alreadyInTarget =
        dragging != null &&
        shiyi.sessions.any((s) => s.id == dragging && s.projectId == projectId);
    return homeDragInsertGapHeight(
      dropReadyId: _dropReadyProjectId,
      groupId: projectId,
      sessionAlreadyInTarget: alreadyInTarget,
      draggedHeight: _draggedSessionHeight,
    );
  }

  Offset? _crossProjectLanding(String toProjectId, int toIndex) {
    final ids = _sessionIdsInProject(toProjectId);
    Offset? destSlot;
    if (toIndex < ids.length) {
      final slot = homeDragOriginSlot(_keyFor(_sessionCardKeys, ids[toIndex]));
      if (slot.$2 != Size.zero) destSlot = slot.$1;
    }
    final gap = homeDragOriginSlot(_keyFor(_insertGapKeys, toProjectId));
    final headerKey = toProjectId.isEmpty
        ? _uncategorizedHeaderKey
        : _keyFor(_projectHeaderKeys, toProjectId);
    final header = homeDragOriginSlot(headerKey);
    if (header.$2 == Size.zero && gap.$2 == Size.zero && destSlot == null) {
      return null;
    }
    return homeDragCrossInsertLanding(
      headerTopLeft: header.$1,
      headerSize: header.$2,
      gapTopLeft: gap.$2.height > 0 ? gap.$1 : null,
      destSlotTopLeft: destSlot,
    );
  }

  Future<void> _flyCrossProjectThenDrop({
    required String sessionId,
    required String toProjectId,
    required int toIndex,
  }) async {
    setState(() {
      _flying = true;
      _crossDropCommitting = true;
    });
    final landing = _crossProjectLanding(toProjectId, toIndex);
    if (kHomeDragCrossProjectFliesToSlot &&
        kHomeDragOwnedOverlay &&
        _dragOverlay.isShowing &&
        landing != null) {
      await _dragOverlay.flyTo(landing, curve: Curves.easeOutCubic);
    } else if (_dragOverlay.isShowing) {
      await _dragOverlay.land();
    }
    if (!mounted) {
      _removeDragVisuals();
      _flying = false;
      return;
    }
    _prepareCrossDropCommit();
    await _dropSessionOnProject(sessionId, toProjectId, toIndex: toIndex);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(_clearDragPreview);
  }

  Future<void> _dropSessionOnProject(
    String sessionId,
    String projectId, {
    int toIndex = 0,
  }) async {
    Session? session;
    for (final s in shiyi.sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return;
    if (session.projectId == projectId) return;
    await shiyi.moveSessionToProjectAt(
      sessionId: sessionId,
      toProjectId: projectId,
      toIndex: toIndex,
    );
    _expandProject(projectId);
  }

  List<Project> get _visibleProjects {
    final override = _projectOrderOverride;
    if (override == null) return shiyi.projects;
    final byId = {for (final p in shiyi.projects) p.id: p};
    return [
      for (final id in override)
        if (byId[id] != null) byId[id]!,
    ];
  }

  List<Session> _sessionsForProject(String projectId, List<Session> raw) {
    if (_sessionOrderOverrideProject != projectId ||
        _sessionOrderOverride == null) {
      return raw;
    }
    final byId = {for (final s in raw) s.id: s};
    return [
      for (final id in _sessionOrderOverride!)
        if (byId[id] != null) byId[id]!,
    ];
  }

  void _onOpenSwipeRectChanged(Rect? rect) {
    if (!mounted) return;
    setState(() => _openSwipeRect = rect);
  }

  void _closeSwipe() {
    _openSwipeKey.value = null;
    if (mounted) setState(() => _openSwipeRect = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.shiyi.sessionsRevision,
        widget.shiyi.projectsRevision,
        widget.shiyi.busyRevision,
      ]),
      builder: (context, _) => Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              leadingWidth: 72,
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                // Windows：页面内红绿灯改为 mac 风格「+」按钮
                // （窗口三键已在全局标题栏）。
                child: Platform.isWindows
                    ? MacActionButton(
                        icon: CupertinoIcons.plus,
                        tooltip: '新建项目',
                        onTap: _newProject,
                      )
                    : TrafficLightsButton(
                        busy: shiyi.isBusy,
                        tooltip: '新建项目',
                        onTap: _newProject,
                      ),
              ),
              toolbarHeight: 64,
              centerTitle: true,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              clipBehavior: Clip.none,
              title: const Text(
                '拾忆',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _FrostedSettingsButton(
                    onPressed: widget.onOpenSettings,
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                Material(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: CupertinoSearchTextField(
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      onChanged: _onSearchChanged,
                      onSubmitted: (_) => _dismissSearch(),
                      placeholder: '搜索会话或消息内容',
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                Expanded(child: ClipRect(child: _buildBody(context))),
              ],
            ),
          ),
          // 左滑展开时的全页透明点击层：用 Listener 接收原始指针事件，
          // 在卡片区域外（含标题栏、搜索栏、卡片间缝隙）按下即收回，
          // 不参与手势竞技场、不挡卡片与圆形按钮。
          if (_openSwipeRect != null)
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  final rect = _openSwipeRect;
                  if (rect != null && !rect.inflate(2).contains(e.position)) {
                    _closeSwipe();
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _newProject() async {
    final shiyi = widget.shiyi;
    _resetSearch();
    final project = await createProjectWithFolder(context, shiyi);
    if (project == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('项目「${project.name}」已创建')));
  }

  Future<void> _openNewSessionInProject(String projectId) async {
    final shiyi = widget.shiyi;
    _resetSearch();
    setState(() => _expandedGroups.add(projectId));
    unawaited(_saveExpanded());
    try {
      await shiyi.newSession(projectId: projectId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('新建会话失败：$e')));
      return;
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MacPageRoute(builder: (_) => ChatScreen(shiyi: shiyi)),
    );
  }

  /// 会话列表限宽居中（macOS 风格）。
  Widget _centeredList(Widget list) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollUpdateNotification) _onDragListScroll();
          return false;
        },
        child: list,
      ),
    ),
  );

  void _onDragListScroll() {
    final last = _lastDragGlobal;
    if (last == null || _flying || _dropCommitted) return;
    if (_draggingSessionId != null) {
      _updateSessionPreviewFromGlobal(last);
    } else if (_draggingProjectId != null) {
      _updateProjectPreviewFromGlobal(last);
    }
  }

  Widget _buildBody(BuildContext context) {
    final q = _query.trim();
    if (q.isEmpty) {
      final byProject = <String, List<Session>>{};
      for (final s in shiyi.sessions) {
        byProject.putIfAbsent(s.projectId, () => []).add(s);
      }
      final children = <Widget>[
        HomeGroupChats(
          key: _groupChatsKey,
          shiyi: shiyi,
          openSwipeKey: _openSwipeKey,
          onOpenRectChanged: _onOpenSwipeRectChanged,
        ),
      ];
      if (shiyi.sessions.isEmpty && shiyi.projects.isEmpty) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: children.first,
                ),
              ),
            ),
            Expanded(child: _EmptyState(onCreate: _newProject)),
          ],
        );
      }
      final projects = _visibleProjects;
      final projectCount = projects.length;
      for (var projectIndex = 0; projectIndex < projectCount; projectIndex++) {
        final p = projects[projectIndex];
        final list = _sessionsForProject(
          p.id,
          byProject[p.id] ?? const <Session>[],
        );
        final expanded = _expandedGroups.contains(p.id);
        children.add(
          _shiftedSlot(
            key: _keyFor(_projectBlockKeys, p.id),
            dy: _projectPreviewFrom == null || _projectPreviewTo == null
                ? 0
                : homeDragTranslateY(
                    index: projectIndex,
                    from: _projectPreviewFrom!,
                    to: _projectPreviewTo!,
                    heights: _projectHeights,
                  ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dragProjectCard(
                  project: p,
                  projectIndex: projectIndex,
                  sessionCount: list.length,
                  expanded: expanded,
                ),
                StaggeredSessions(
                  expanded: expanded,
                  unclipped: kHomeDragSessionHitTestUnclipped && expanded,
                  fastCollapse: _draggingProjectId == p.id,
                  outOfFlow: _draggingProjectId == p.id,
                  children: _sessionCardsWithGap(list: list, projectId: p.id),
                ),
                HomeDragInsertGap(
                  key: _keyFor(_insertGapKeys, p.id),
                  height: _insertGapHeight(p.id),
                  snap: _dropCommitted,
                ),
              ],
            ),
          ),
        );
      }
      final uncat = _sessionsForProject('', byProject[''] ?? const <Session>[]);
      if (uncat.isNotEmpty) {
        final expanded = _expandedGroups.contains('');
        children.add(_uncategorizedHeader(uncat.length, expanded));
        children.add(
          StaggeredSessions(
            expanded: expanded,
            unclipped: kHomeDragSessionHitTestUnclipped && expanded,
            children: _sessionCardsWithGap(list: uncat, projectId: ''),
          ),
        );
        children.add(
          HomeDragInsertGap(
            key: _keyFor(_insertGapKeys, ''),
            height: _insertGapHeight(''),
            snap: _dropCommitted,
          ),
        );
      }
      return _centeredList(
        ListView(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          children: children,
        ),
      );
    }
    return FutureBuilder<List<SessionSearchResult>>(
      future: _searchFutureFor(q),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final results = snap.data!;
        if (results.isEmpty) {
          return Center(
            child: Text(
              '未找到与「$q」相关的会话',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }
        return _centeredList(
          ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            itemCount: results.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _SessionTile(
              shiyi: shiyi,
              session: results[i].session,
              snippet: results[i].snippet,
              openSwipeKey: _openSwipeKey,
              onOpenRectChanged: _onOpenSwipeRectChanged,
              swipeKey: 'session_${results[i].session.id}',
              onBeforeOpen: _dismissSearch,
              onReturn: _resetSearch,
            ),
          ),
        );
      },
    );
  }

  List<Widget> _sessionCardsWithGap({
    required List<Session> list,
    required String projectId,
  }) {
    final draggingHere =
        _draggingSessionId != null && _sessionPreviewProjectId == projectId;
    final from = draggingHere ? _sessionPreviewFrom : null;
    final to = draggingHere ? _sessionPreviewTo : null;
    final alreadyHere =
        _draggingSessionId != null &&
        list.any((s) => s.id == _draggingSessionId);
    final crossHere = homeDragAppliesForeignShift(
      dropReadyHere: _dropReadyProjectId == projectId,
      originGroup: _sessionPreviewProjectId == projectId,
      draggedAlreadyHere: alreadyHere,
    );
    return [
      for (var i = 0; i < list.length; i++)
        _shiftedSlot(
          key: _keyFor(_sessionCardKeys, list[i].id),
          dy: crossHere
              ? homeDragForeignTranslateY(
                  index: i,
                  insertAt: _crossInsertIndex,
                  draggedHeight: _draggedSessionHeight,
                )
              : from == null || to == null
              ? 0
              : homeDragTranslateY(
                  index: i,
                  from: from,
                  to: to,
                  heights: _sessionHeights,
                ),
          child: _dragSessionCard(
            session: list[i],
            indexInProject: i,
            projectId: projectId,
          ),
        ),
    ];
  }

  Widget _shiftedSlot({Key? key, required double dy, required Widget child}) {
    return HomeDragShift(
      key: key,
      dy: dy,
      snap: _snapShift,
      duration: kHomeDragSqueezeDuration,
      child: child,
    );
  }

  Widget _dragProjectCard({
    required Project project,
    required int projectIndex,
    required int sessionCount,
    required bool expanded,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HomeLongPressDrag(
        key: ValueKey('drag_project_${project.id}'),
        enabled:
            (_draggingProjectId == null && _draggingSessionId == null) ||
            _draggingProjectId == project.id,
        onDragStart: (details) => _onProjectDragStarted(
          project.id,
          projectIndex,
          details.globalPosition,
        ),
        onDragUpdate: (details) =>
            _updateProjectPreviewFromGlobal(details.globalPosition),
        onDragEnd: (_) => _commitProjectDrag(),
        onDragCancel: _commitProjectDrag,
        onDragSettled: _removeDragVisuals,
        child: _projectSwipeActions(
          project: project,
          sessionCount: sessionCount,
          expanded: expanded,
          disableSwipe: _draggingProjectId == project.id,
        ),
      ),
    );
  }

  Widget _projectSwipeActions({
    required Project project,
    required int sessionCount,
    required bool expanded,
    bool disableSwipe = false,
  }) {
    return SwipeActions(
      key: ValueKey('project_${project.id}'),
      openNotifier: _openSwipeKey,
      onOpenRectChanged: _onOpenSwipeRectChanged,
      swipeKey: 'project_${project.id}',
      disableSwipe: disableSwipe,
      actionWidth: 232,
      actions: [
        CircularSwipeAction(
          icon: CupertinoIcons.plus,
          label: '新建会话',
          backgroundColor: _iosBlue,
          foregroundColor: Colors.white,
          onTap: () async {
            await _openNewSessionInProject(project.id);
            _openSwipeKey.value = null;
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.folder_open,
          label: '项目文件夹',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () async {
            await showProjectFolderSheet(context, shiyi, project);
            _openSwipeKey.value = null;
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.pencil,
          label: '重命名',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () async {
            await renameProjectDialog(context, shiyi, project);
            _openSwipeKey.value = null;
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.trash,
          label: '删除',
          backgroundColor: _iosRed,
          foregroundColor: Colors.white,
          onTap: () async {
            await deleteProjectDialog(context, shiyi, project);
            _openSwipeKey.value = null;
          },
        ),
      ],
      child: HomeGroupHeader(
        key: _keyFor(_projectHeaderKeys, project.id),
        name: project.name,
        count: sessionCount,
        expanded: expanded,
        dropReady: _dropReadyProjectId == project.id,
        onTap: () => _toggleProject(project.id),
      ),
    );
  }

  Widget _uncategorizedHeader(int count, bool expanded) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SwipeActions(
        key: _uncategorizedHeaderKey,
        openNotifier: _openSwipeKey,
        onOpenRectChanged: _onOpenSwipeRectChanged,
        swipeKey: 'project_uncat',
        actionWidth: 64,
        actions: [
          CircularSwipeAction(
            icon: CupertinoIcons.plus,
            label: '新建会话',
            backgroundColor: _iosBlue,
            foregroundColor: Colors.white,
            onTap: () async {
              await _openNewSessionInProject('');
              _openSwipeKey.value = null;
            },
          ),
        ],
        child: HomeGroupHeader(
          name: '未分类',
          count: count,
          expanded: expanded,
          dropReady: _dropReadyProjectId == '',
          onTap: () => _toggleProject(''),
        ),
      ),
    );
  }

  Widget _dragSessionCard({
    required Session session,
    required int indexInProject,
    required String projectId,
  }) {
    Widget sessionCard({bool visualOnly = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _SessionTile(
        shiyi: shiyi,
        session: session,
        openSwipeKey: visualOnly ? null : _openSwipeKey,
        onOpenRectChanged: visualOnly ? null : _onOpenSwipeRectChanged,
        swipeKey: visualOnly ? null : 'session_${session.id}',
        onBeforeOpen: visualOnly ? () {} : _dismissSearch,
        onReturn: visualOnly ? () {} : _resetSearch,
        disableSwipe: visualOnly || _draggingSessionId == session.id,
        visualOnly: visualOnly,
      ),
    );
    return HomeLongPressDrag(
      key: ValueKey('drag_session_${session.id}'),
      enabled:
          _draggingProjectId == null &&
          (_draggingSessionId == null || _draggingSessionId == session.id),
      onDragStart: (details) => _onSessionDragStarted(
        session.id,
        projectId,
        indexInProject,
        details.globalPosition,
      ),
      onDragUpdate: (details) =>
          _updateSessionPreviewFromGlobal(details.globalPosition),
      onDragEnd: (details) => _commitSessionDrag(details.globalPosition),
      onDragCancel: _commitSessionDrag,
      onDragSettled: _removeDragVisuals,
      child: HomeDragHeightFactor(
        factor: homeDragCardSlotFactor(
          isDragged: _draggingSessionId == session.id,
          keepCollapsed: homeDragSourceSlotKeepCollapsed(
            committing: _crossDropCommitting,
            originId: _sessionPreviewProjectId,
            cardGroupId: projectId,
          ),
          originId: _sessionPreviewProjectId,
          hoverId: _hoveringProjectId ?? _dropReadyProjectId,
          cardGroupId: projectId,
        ),
        snap:
            homeDragSourceSlotKeepCollapsed(
              committing: _crossDropCommitting,
              originId: _sessionPreviewProjectId,
              cardGroupId: projectId,
            ) ||
            homeDragSourceSlotSnaps(
              originId: _sessionPreviewProjectId,
              cardGroupId: projectId,
            ),
        child: Opacity(
          opacity: _draggingSessionId == session.id ? 0 : 1,
          child: sessionCard(),
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ShiyiState shiyi;
  final Session session;
  final String snippet;
  final VoidCallback onBeforeOpen;
  final VoidCallback onReturn;
  final ValueNotifier<String?>? openSwipeKey;
  final ValueChanged<Rect?>? onOpenRectChanged;
  final String? swipeKey;
  final bool disableSwipe;
  final bool visualOnly;
  const _SessionTile({
    required this.shiyi,
    required this.session,
    required this.onBeforeOpen,
    required this.onReturn,
    this.snippet = '',
    this.openSwipeKey,
    this.onOpenRectChanged,
    this.swipeKey,
    this.disableSwipe = false,
    this.visualOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    final theme = Theme.of(context);
    final projectName = shiyi.projectNameFor(s.id);
    final busy = shiyi.isBusyForSession(s.id);
    final unread = shiyi.unreadSessions.contains(s.id);
    final subtitle = busy
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: _iosBlue,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '思考中…',
                style: TextStyle(
                  fontSize: 12.5,
                  color: _iosBlue,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          )
        : Text(
            snippet.isNotEmpty
                ? snippet
                : '${s.messageCount} 条消息 · ${_fmtTime(s.updatedAt)}'
                      '${s.model.isEmpty ? '' : ' · ${s.model}'}'
                      '${projectName.isEmpty ? '' : ' · $projectName'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 12.5,
            ),
          );
    final tile = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          WelcomeAvatar(size: 36, asset: 'assets/avatar.png'),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 15.5,
                  ),
                ),
                const SizedBox(height: 3),
                subtitle,
              ],
            ),
          ),
          if (unread) ...[
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: _iosBlue,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
          ],
          const Icon(
            CupertinoIcons.chevron_right,
            size: 16,
            color: CupertinoColors.systemGrey,
          ),
        ],
      ),
    );
    if (visualOnly) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: iosSectionBackground(context),
            borderRadius: BorderRadius.circular(14),
          ),
          child: tile,
        ),
      );
    }
    return SwipeActions(
      key: ValueKey(s.id),
      openNotifier: openSwipeKey,
      onOpenRectChanged: onOpenRectChanged,
      swipeKey: swipeKey,
      disableSwipe: disableSwipe,
      actionWidth: 232,
      // 左滑拉出拼合胶囊操作（重命名 / 项目 / 复制 ID / 删除）。
      onTap: () async {
        onBeforeOpen();
        await shiyi.selectSession(s.id);
        if (context.mounted) {
          await Navigator.push(
            context,
            MacPageRoute(
              builder: (_) => ChatScreen(shiyi: shiyi, sessionId: s.id),
            ),
          );
          // Navigator.push 的 Future 会在 pop 时先完成，此时自定义路由仍在
          // 播放 240ms 退场动画。等动画彻底结束后再重建主页，避免依赖树
          // 在退场过程中被拆卸并触发 InheritedElement 生命周期断言。
          await Future<void>.delayed(const Duration(milliseconds: 350));
          if (context.mounted) onReturn();
        }
      },
      actions: [
        // 左滑拉出的操作按钮：圆角交给外层 ClipRRect 裁剪，
        // 左缘直角与内容右缘（展开时为直角）拼接，整体呈胶囊。
        CircularSwipeAction(
          icon: CupertinoIcons.pencil,
          label: shiyiSessionSwipeLabels[0],
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () async {
            await _rename(context, shiyi, s);
            openSwipeKey?.value = null;
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.folder_open,
          label: shiyiSessionSwipeLabels[1],
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () async {
            await _pickProject(context, shiyi, s);
            openSwipeKey?.value = null;
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.doc_on_doc,
          label: shiyiSessionSwipeLabels[2],
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: s.id));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('已复制会话 ID')));
            }
            openSwipeKey?.value = null;
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.trash,
          label: shiyiSessionSwipeLabels[3],
          backgroundColor: _iosRed,
          foregroundColor: Colors.white,
          onTap: () async {
            final ok = await showIosFadeDialog<bool>(
              context: context,
              builder: (ctx) => CupertinoTheme(
                data: iosCupertinoTheme(context),
                child: CupertinoAlertDialog(
                  title: const Text('删除会话'),
                  content: Text('确定删除「${s.title}」及其全部消息吗？'),
                  actions: [
                    CupertinoDialogAction(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    CupertinoDialogAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ),
            );
            if (ok == true) await shiyi.deleteSession(s.id);
            openSwipeKey?.value = null;
          },
        ),
      ],
      child: tile,
    );
  }
}

Future<void> _rename(BuildContext context, ShiyiState shiyi, Session s) async {
  final controller = TextEditingController(text: s.title);
  final title = await showIosFadeDialog<String>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: CupertinoAlertDialog(
        title: const Text('重命名会话'),
        content: CupertinoTextField(
          controller: controller,
          autofocus: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          clearButtonMode: OverlayVisibilityMode.editing,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  if (title != null && title.isNotEmpty) {
    await shiyi.renameSession(s.id, title);
  }
}

Future<void> _pickProject(
  BuildContext context,
  ShiyiState shiyi,
  Session s,
) async {
  final selectedId = await showIosFadeModalPopup<String>(
    context: context,
    builder: (ctx) => CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: CupertinoActionSheet(
        title: Text(
          '移动「${s.title}」到项目',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          for (final p in shiyi.projects)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, p.id),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (s.projectId == p.id) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      CupertinoIcons.check_mark,
                      size: 16,
                      color: _iosBlue,
                    ),
                  ],
                ],
              ),
            ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('未分类'),
                if (s.projectId.isEmpty) ...[
                  const SizedBox(width: 6),
                  const Icon(
                    CupertinoIcons.check_mark,
                    size: 16,
                    color: _iosBlue,
                  ),
                ],
              ],
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    ),
  );
  if (selectedId == null) return;
  await shiyi.moveSessionToProject(
    s.id,
    selectedId.isEmpty ? null : selectedId,
  );
}

String _fmtTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  return '${d.month}月${d.day}日';
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          WelcomeAvatar(size: 240),
          const SizedBox(height: 16),
          Text('新建一个项目开始', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '项目分类管理会话 · 每个项目可设置工作目录',
            style: theme.textTheme.bodyMedium!.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 28),
          CupertinoButton.filled(
            onPressed: onCreate,
            borderRadius: BorderRadius.circular(24),
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.plus, size: 16),
                SizedBox(width: 6),
                Text('新建项目', style: TextStyle(fontSize: 15)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// macOS Sonoma 风格磨砂玻璃设置胶囊：
/// 与左侧红绿灯胶囊同尺寸，左为两条短横线、右侧细线齿轮，单色灰度。
class _FrostedSettingsButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _FrostedSettingsButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fg = dark
        ? Colors.white.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.62);
    return Tooltip(
      message: '设置',
      child: GestureDetector(
        onTap: onPressed,
        child: Align(
          alignment: Alignment.center,
          child: Container(
            width: 60,
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.35 : 0.16),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  color: Colors.white.withValues(alpha: dark ? 0.10 : 0.40),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 两条短横线：与红绿灯胶囊的圆点横排呼应，统一风格。
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 11, height: 1.6, color: fg),
                          const SizedBox(height: 3.5),
                          Container(width: 11, height: 1.6, color: fg),
                        ],
                      ),
                      const SizedBox(width: 5),
                      Icon(Icons.settings_outlined, size: 13, color: fg),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
