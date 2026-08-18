import 'dart:async';
import 'dart:io';

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../services/dsh_service.dart';
import '../services/update_service.dart';
import '../widgets/context_menu.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
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

const _iosBlue = Color(0xFF0A84FF);
const _iosRed = Color(0xFFFF3B30);
const _iosGray = Color(0xFF8E8E93);

class HomeScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const HomeScreen({super.key, required this.shiyi});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _tab = 0;

  /// 桌面侧边栏宽度（拖拽把手调整，150~300）。
  double _sidebarWidth = 190;
  final int _sessionsResetRevision = 0;
  // tab 懒缓存：切换过的页面保留不重建（页面切换卡顿根因=每次全量重建+DB重查）。
  final Map<int, Widget> _tabCache = {};
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
      if (widget.shiyi.settings.dshStopOnExit) {
        unawaited(DshService.instance.stop());
      }
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_checkDshOnLaunch());
    }
  }

  /// 打开 app 时自动体检：未安装提示；未开启自动拉起；已开启刷新状态。
  Future<void> _checkDshOnLaunch() async {
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
    if (engine == _lastAgentEngine) return;
    _lastAgentEngine = engine;
    _tabCache.clear();
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
      if (!mounted || i > 2) return;
      _tabCache[i] = _buildTabFor(i);
      setState(() {});
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
    setState(() {
      _tab = tab;
    });
    _fadeController.forward(from: 0);
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
      if (widget.shiyi.settings.dshStopOnExit) {
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
    // 引擎决定主页 tab 套件：拾忆（会话/功能/文件）或 DS Harness
    //（工作数据/功能/文件）。
    final tabs = shiyi.settings.agentEngine == 'dsh' ? _dshTabs : _iosTabs;
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
              for (var i = 0; i <= 2; i++)
                if (i == _tab)
                  _tabCache[i] ??= _buildTabFor(i)
                else
                  _tabCache[i] ?? const SizedBox.shrink(),
            ],
          ),
        );
        if (!desktopNav) return SafeArea(child: stack);
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
              : content,
          bottomNavigationBar: desktopNav
              ? null
              : _IosTabBar(currentIndex: _tab, onTap: _selectTab, tabs: tabs),
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
    // Agent 引擎：DS Harness 时主页三个 tab 整体切换（外观复用拾忆，
    // 数据源为 DeepSeek Harness）：会话（工作区分组）/ 功能（DSH 功能
    // 入口集合）/ 文件。
    if (shiyi.settings.agentEngine == 'dsh') {
      switch (i) {
        case 0:
          return DshWorkspacesTab(shiyi: shiyi);
        case 1:
          return DshFeaturesTab(shiyi: shiyi);
        case 2:
          // DSH 文件页使用主机目录 API；拾忆引擎仍使用本地文件页。
          return buildFilesTabForEngine(shiyi);
      }
      return const SizedBox.shrink();
    }
    switch (i) {
      case 0:
        return _SessionsTab(
          shiyi: shiyi,
          resetRevision: _sessionsResetRevision,
          onOpenSettings: _openSettings,
        );
      case 1:
        return FeaturesScreen(shiyi: shiyi);
      case 2:
        return FilesScreen(shiyi: shiyi);
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

const _iosTabs = <(IconData, IconData, String)>[
  (CupertinoIcons.chat_bubble_2, CupertinoIcons.chat_bubble_2_fill, '会话'),
  (CupertinoIcons.square_grid_2x2, CupertinoIcons.square_grid_2x2_fill, '功能'),
  (CupertinoIcons.folder, CupertinoIcons.folder_fill, '文件'),
];

/// DS Harness 引擎下的主页 tab：工作数据 / 功能 / 文件（拾忆同款布局，
/// 功能页的「技能」卡片走 DeepSeek Harness 接口）。
const _dshTabs = <(IconData, IconData, String)>[
  (CupertinoIcons.archivebox, CupertinoIcons.archivebox_fill, '工作数据'),
  (CupertinoIcons.square_grid_2x2, CupertinoIcons.square_grid_2x2_fill, '功能'),
  (CupertinoIcons.folder, CupertinoIcons.folder_fill, '文件'),
];

/// 返回当前 Agent 引擎对应的文件页。
/// DSH 使用主机目录 API；拾忆使用本地文件工作区。
/// 单独保留为纯路由选择点，避免两个引擎的文件数据源再次串线。
Widget buildFilesTabForEngine(ShiyiState shiyi) {
  return shiyi.settings.agentEngine == 'dsh'
      ? DshFilesTab(shiyi: shiyi)
      : FilesScreen(shiyi: shiyi);
}

/// iOS 风格底部 Tab：毛玻璃背景、蓝点选中态、图标+文字。
class _IosTabBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<(IconData, IconData, String)> tabs;
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
              height: 58,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _IosTabItem(
                        icon: tabs[i].$1,
                        selectedIcon: tabs[i].$2,
                        label: tabs[i].$3,
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
    final color = selected
        ? (dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF))
        : (dark ? CupertinoColors.systemGrey : CupertinoColors.secondaryLabel);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? selectedIcon : icon, size: 24, color: color),
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
  final List<(IconData, IconData, String)> tabs;
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
                      icon: tabs[i].$1,
                      selectedIcon: tabs[i].$2,
                      label: tabs[i].$3,
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
  final VoidCallback onOpenSettings;
  const _SessionsTab({
    required this.shiyi,
    required this.resetRevision,
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

  /// 当前展开的左滑卡片 key；点空白或操作其他卡片时收回。
  final ValueNotifier<String?> _openSwipeKey = ValueNotifier(null);

  /// 当前展开左滑卡片的屏幕区域，用于精确识别「空白点击」。
  Rect? _openSwipeRect;

  ShiyiState get shiyi => widget.shiyi;

  @override
  void didUpdateWidget(covariant _SessionsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetRevision != widget.resetRevision) {
      _dismissSearch();
      _searchCtrl.clear();
      _query = '';
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
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
                Padding(
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
                Expanded(child: _buildBody(context)),
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
      child: list,
    ),
  );

  Widget _buildBody(BuildContext context) {
    final q = _query.trim();
    if (q.isEmpty) {
      if (shiyi.sessions.isEmpty && shiyi.projects.isEmpty) {
        return _EmptyState(onCreate: _newProject);
      }
      final byProject = <String, List<Session>>{};
      for (final s in shiyi.sessions) {
        byProject.putIfAbsent(s.projectId, () => []).add(s);
      }
      final children = <Widget>[];
      for (final p in shiyi.projects) {
        final list = byProject[p.id] ?? const <Session>[];
        final expanded = _expandedGroups.contains(p.id);
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SwipeActions(
              key: ValueKey('project_${p.id}'),
              openNotifier: _openSwipeKey,
              onOpenRectChanged: _onOpenSwipeRectChanged,
              swipeKey: 'project_${p.id}',
              actionWidth: 232,
              actions: [
                _CircularSwipeAction(
                  icon: CupertinoIcons.plus,
                  label: '新建会话',
                  backgroundColor: _iosBlue,
                  foregroundColor: Colors.white,
                  onTap: () async {
                    await _openNewSessionInProject(p.id);
                    _openSwipeKey.value = null;
                  },
                ),
                _CircularSwipeAction(
                  icon: CupertinoIcons.folder_open,
                  label: '项目文件夹',
                  backgroundColor: _iosGray,
                  foregroundColor: Colors.white,
                  onTap: () async {
                    await showProjectFolderSheet(context, shiyi, p);
                    _openSwipeKey.value = null;
                  },
                ),
                _CircularSwipeAction(
                  icon: CupertinoIcons.pencil,
                  label: '重命名',
                  backgroundColor: _iosGray,
                  foregroundColor: Colors.white,
                  onTap: () async {
                    await renameProjectDialog(context, shiyi, p);
                    _openSwipeKey.value = null;
                  },
                ),
                _CircularSwipeAction(
                  icon: CupertinoIcons.trash,
                  label: '删除',
                  backgroundColor: _iosRed,
                  foregroundColor: Colors.white,
                  onTap: () async {
                    await deleteProjectDialog(context, shiyi, p);
                    _openSwipeKey.value = null;
                  },
                ),
              ],
              child: _ProjectHeader(
                name: p.name,
                count: list.length,
                expanded: expanded,
                onTap: () => _toggleProject(p.id),
              ),
            ),
          ),
        );
        children.add(
          _StaggeredProjectSessions(
            expanded: expanded,
            children: [
              for (final s in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _SessionTile(
                    shiyi: shiyi,
                    session: s,
                    openSwipeKey: _openSwipeKey,
                    onOpenRectChanged: _onOpenSwipeRectChanged,
                    swipeKey: 'session_${s.id}',
                    onBeforeOpen: _dismissSearch,
                    onReturn: _resetSearch,
                  ),
                ),
            ],
          ),
        );
      }
      final uncat = byProject[''] ?? const <Session>[];
      if (uncat.isNotEmpty) {
        final expanded = _expandedGroups.contains('');
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SwipeActions(
              key: const ValueKey('project_uncat'),
              openNotifier: _openSwipeKey,
              onOpenRectChanged: _onOpenSwipeRectChanged,
              swipeKey: 'project_uncat',
              actionWidth: 64,
              actions: [
                _CircularSwipeAction(
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
              child: _ProjectHeader(
                name: '未分类',
                count: uncat.length,
                expanded: expanded,
                onTap: () => _toggleProject(''),
              ),
            ),
          ),
        );
        children.add(
          _StaggeredProjectSessions(
            expanded: expanded,
            children: [
              for (final s in uncat)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _SessionTile(
                    shiyi: shiyi,
                    session: s,
                    openSwipeKey: _openSwipeKey,
                    onOpenRectChanged: _onOpenSwipeRectChanged,
                    swipeKey: 'session_${s.id}',
                    onBeforeOpen: _dismissSearch,
                    onReturn: _resetSearch,
                  ),
                ),
            ],
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
}

/// 项目会话列表的展开/收起动画容器：会话卡片逐条出现/收回，
/// 避免整体高度擦除式过渡。
class _StaggeredProjectSessions extends StatefulWidget {
  final bool expanded;
  final List<Widget> children;
  const _StaggeredProjectSessions({
    required this.expanded,
    required this.children,
  });

  @override
  State<_StaggeredProjectSessions> createState() =>
      _StaggeredProjectSessionsState();
}

class _StaggeredProjectSessionsState extends State<_StaggeredProjectSessions>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..value = widget.expanded ? 1 : 0;

  @override
  void didUpdateWidget(covariant _StaggeredProjectSessions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.children.length;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < n; i++) _buildItem(i, n)],
        );
      },
    );
  }

  Widget _buildItem(int index, int total) {
    final start = index / total;
    final end = (index + 1) / total;
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
      reverseCurve: Interval(start, end, curve: Curves.easeInCubic),
    );
    return SizeTransition(
      sizeFactor: curved,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curved),
          child: widget.children[index],
        ),
      ),
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  final String name;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  const _ProjectHeader({
    required this.name,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Icon(
                  expanded ? CupertinoIcons.folder_open : CupertinoIcons.folder,
                  size: 18,
                  color: _iosBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$count 个会话',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOutCubic,
                  child: const Icon(
                    CupertinoIcons.chevron_down,
                    size: 18,
                    color: CupertinoColors.systemGrey,
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

class _SessionTile extends StatelessWidget {
  final ShiyiState shiyi;
  final Session session;
  final String snippet;
  final VoidCallback onBeforeOpen;
  final VoidCallback onReturn;
  final ValueNotifier<String?>? openSwipeKey;
  final ValueChanged<Rect?>? onOpenRectChanged;
  final String? swipeKey;
  const _SessionTile({
    required this.shiyi,
    required this.session,
    required this.onBeforeOpen,
    required this.onReturn,
    this.snippet = '',
    this.openSwipeKey,
    this.onOpenRectChanged,
    this.swipeKey,
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
    return _SwipeActions(
      key: ValueKey(s.id),
      openNotifier: openSwipeKey,
      onOpenRectChanged: onOpenRectChanged,
      swipeKey: swipeKey,
      actionWidth: 176,
      // 左滑拉出拼合胶囊操作（重命名 / 删除）。
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
        _CircularSwipeAction(
          icon: CupertinoIcons.pencil,
          label: '重命名',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () async {
            await _rename(context, shiyi, s);
            openSwipeKey?.value = null;
          },
        ),
        _CircularSwipeAction(
          icon: CupertinoIcons.folder_open,
          label: '项目',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () async {
            await _pickProject(context, shiyi, s);
            openSwipeKey?.value = null;
          },
        ),
        _CircularSwipeAction(
          icon: CupertinoIcons.trash,
          label: '删除',
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

/// 自实现左滑操作容器：内容跟随手指左移，露出右侧固定宽度的操作胶囊；
/// 已滑开时点击内容先收回，再点才触发 onTap。
class _SwipeActions extends StatefulWidget {
  final Widget child;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final double actionWidth;
  final ValueNotifier<String?>? openNotifier;
  final ValueChanged<Rect?>? onOpenRectChanged;
  final String? swipeKey;

  const _SwipeActions({
    super.key,
    required this.child,
    required this.actions,
    this.onTap,
    this.actionWidth = 132,
    this.openNotifier,
    this.onOpenRectChanged,
    this.swipeKey,
  });

  @override
  State<_SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<_SwipeActions>
    with SingleTickerProviderStateMixin {
  double get actionWidth => widget.actionWidth;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addStatusListener(_onAnimationStatus);

  double _offset = 0;
  bool _animating = false;

  @override
  void initState() {
    super.initState();
    widget.openNotifier?.addListener(_onOpenChanged);
  }

  @override
  void dispose() {
    widget.openNotifier?.removeListener(_onOpenChanged);
    widget.onOpenRectChanged?.call(null);
    _controller.dispose();
    super.dispose();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed &&
        status != AnimationStatus.dismissed) {
      return;
    }
    _offset = -actionWidth * _controller.value;
    _animating = false;
    if (status == AnimationStatus.dismissed) {
      widget.onOpenRectChanged?.call(null);
    }
    if (mounted) setState(() {});
  }

  /// 计算松手后的目标偏移。
  /// 规则：左滑过 35% 或快速左滑 → 展开；已完全展开时快速右滑收回，原地松手保持展开。
  double _target(double velocity) {
    final fullyOpen = _offset <= -actionWidth + 2;
    if (fullyOpen) {
      if (velocity > 200) return 0;
      return -actionWidth;
    }
    if (velocity > 250) return 0;
    if (_offset < -actionWidth * 0.35 || velocity < -200) {
      return -actionWidth;
    }
    return 0;
  }

  void _drag(double dx) {
    final n = widget.openNotifier;
    final k = widget.swipeKey;
    if (n != null && k != null && n.value != null && n.value != k) {
      n.value = null;
    }
    if (_animating) {
      _controller.stop();
      _animating = false;
    }
    setState(() {
      _offset = (_offset + dx).clamp(-actionWidth, 0.0);
    });
  }

  /// 从当前位移平滑吸附到目标位置。
  void _settle(double target) {
    _controller.value = (_offset / -actionWidth).clamp(0.0, 1.0);
    _animating = true;
    _controller.animateTo(target / -actionWidth, curve: Curves.easeOutCubic);
  }

  void _end(double velocity) {
    final t = _target(velocity);
    if (t == _offset) {
      if (_animating) {
        _controller.stop();
        _animating = false;
      }
      // 拖满上限时位移已到目标值，也要把展开/收回状态同步出去，
      // 否则点空白时找不到当前展开卡片。
      _syncOpenState(t);
      return;
    }
    _settle(t);
    _syncOpenState(t);
  }

  void _handleTap() {
    if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
      _syncOpenState(0);
      return;
    }
    widget.onTap?.call();
  }

  /// Windows 桌面：鼠标悬停展开操作区（代替左滑），离开收回。
  void _setHovered(bool hovered) {
    if (!Platform.isWindows) return;
    if (_animating) {
      _controller.stop();
      _animating = false;
    }
    if (hovered) {
      if (_offset >= 0) {
        _controller.forward();
        _syncOpenState(-actionWidth);
      }
    } else if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
      _syncOpenState(0);
    }
    if (mounted) setState(() {});
  }

  /// Windows 桌面：右键弹出与左滑操作相同的菜单（悬停展开之外的第二入口）。
  void _openContextMenu(BuildContext context, Offset globalPosition) {
    final entries = <DesktopMenuItem>[];
    for (final a in widget.actions) {
      if (a is _CircularSwipeAction) {
        entries.add(
          DesktopMenuItem(
            label: a.label,
            icon: a.icon,
            iconColor: a.backgroundColor,
            onTap: a.onTap,
          ),
        );
      }
    }
    if (entries.isEmpty) return;
    // 若已展开先收回，避免菜单出现时列表项还露着操作区。
    if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
      _syncOpenState(0);
    }
    showDesktopMenu(context, globalPosition: globalPosition, items: entries);
  }

  void _syncOpenState(double target) {
    final n = widget.openNotifier;
    final k = widget.swipeKey;
    if (n == null || k == null) return;
    if (target < 0) {
      n.value = k;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final box = context.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          widget.onOpenRectChanged?.call(
            box.localToGlobal(Offset.zero) & box.size,
          );
        }
      });
    } else if (n.value == k) {
      n.value = null;
      widget.onOpenRectChanged?.call(null);
    }
  }

  void _onOpenChanged() {
    final n = widget.openNotifier;
    final k = widget.swipeKey;
    if (n == null || k == null || n.value == k) return;
    if (_animating) {
      _controller.stop();
      _animating = false;
      _offset = -actionWidth * _controller.value;
    }
    if (_offset < 0) {
      widget.onOpenRectChanged?.call(null);
      _settle(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayOffset = _animating
        ? -actionWidth * _controller.value
        : _offset;
    final desktop = Platform.isWindows;
    // Windows 桌面：鼠标悬停展开操作区（代替左滑手势），右键弹菜单；
    // 手机端保持左滑 + 点击逻辑不变。
    return MouseRegion(
      onEnter: desktop ? (_) => _setHovered(true) : null,
      onExit: desktop ? (_) => _setHovered(false) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            // 底层：右侧固定宽度操作区（仅滑动展开时显示，静止时完全不可见）。
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: displayOffset < 0 ? 1 : 0,
                duration: const Duration(milliseconds: 100),
                child: GestureDetector(
                  // 露出的操作区背景也视为空白：点圆形按钮触发操作，
                  // 点按钮之间的空隙则收回左滑。
                  behavior: HitTestBehavior.opaque,
                  onTap: _handleTap,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: actionWidth,
                      height: double.infinity,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [for (final a in widget.actions) a],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 上层：内容。手势放在 transform 内部，命中区域随左移，
            // 右侧露出的操作区才能被点中；内容带不透明背景遮挡底层。
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final off = _animating
                    ? -actionWidth * _controller.value
                    : _offset;
                return Container(
                  transform: Matrix4.translationValues(off, 0, 0),
                  decoration: BoxDecoration(
                    color: iosSectionBackground(context),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: desktop
                        ? null
                        : (d) => _drag(d.delta.dx),
                    onHorizontalDragEnd: desktop
                        ? null
                        : (d) => _end(d.primaryVelocity ?? 0),
                    onHorizontalDragCancel: desktop ? null : () => _end(0),
                    onSecondaryTapDown: desktop
                        ? (d) => _openContextMenu(context, d.globalPosition)
                        : null,
                    onTap: _handleTap,
                    child: widget.child,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 左滑操作中的圆形图标按钮：圆形底 + 图标，下方配小字标签。
class _CircularSwipeAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onTap;

  const _CircularSwipeAction({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: SizedBox(
        width: 56,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Material(
                color: backgroundColor,
                shape: const CircleBorder(),
                elevation: 1.5,
                shadowColor: Colors.black.withValues(alpha: .25),
                child: InkWell(
                  onTap: onTap,
                  customBorder: const CircleBorder(),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(icon, color: foregroundColor, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
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
