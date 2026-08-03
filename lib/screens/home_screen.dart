import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../widgets/welcome_avatar.dart';
import 'chat_screen.dart';
import 'files_screen.dart';
import 'memory_screen.dart';
import 'log_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';
import 'terminal_screen.dart';

class HomeScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const HomeScreen({super.key, required this.shiyi});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _sidebarVisible = false;

  Future<void> _handleBack() async {
    // 临时层优先于页面导航：系统返回手势先收起侧边栏。
    if (_sidebarVisible) {
      setState(() => _sidebarVisible = false);
      return;
    }
    // 非主页 tab 先退回会话页，层层返回。
    if (_tab != 0) {
      setState(() => _tab = 0);
      return;
    }
    // 已在主页，二次确认后退出。
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出拾忆'),
        content: const Text('确定要退出应用吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shiyi = widget.shiyi;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        body: ListenableBuilder(
          listenable: shiyi,
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
            final topInset = MediaQuery.paddingOf(context).top;
            return Stack(
              children: [
                // 内容区始终全宽，侧边栏展开时悬浮覆盖其上，不挤压内容。
                SafeArea(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: KeyedSubtree(
                      key: ValueKey(_tab),
                      child: _buildTab(),
                    ),
                  ),
                ),
                // 侧边栏展开时的拦截遮罩：点击任何空白只收起，不传递给下层内容区。
                if (_sidebarVisible)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _sidebarVisible = false),
                    ),
                  ),
                // 悬浮侧边栏：带滑入/滑出动画。
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  left: _sidebarVisible ? 0 : -300,
                  top: 0,
                  bottom: 0,
                  child: _MacSidebar(
                    selected: _tab,
                    onSelect: (i) => setState(() => _tab = i),
                    onToggle: () => setState(() => _sidebarVisible = false),
                    onNewSession: _newSession,
                  ),
                ),
                // 收起时的悬浮红绿灯入口：所有侧边栏页面都显示，方便随时展开。
                Positioned(
                  left: 6,
                  top: topInset,
                  height: kToolbarHeight,
                  child: IgnorePointer(
                    ignoring: _sidebarVisible,
                    child: AnimatedOpacity(
                      opacity: _sidebarVisible ? 0 : 1,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      child: AnimatedScale(
                        scale: _sidebarVisible ? 0.7 : 1,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutBack,
                        child: Center(
                          child: _FloatingTrafficLights(
                            onTap: () => setState(() => _sidebarVisible = true),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _newSession() async {
    final shiyi = widget.shiyi;
    await shiyi.newSession();
    if (!mounted) return;
    Navigator.push(
      context,
      MacPageRoute(builder: (_) => ChatScreen(shiyi: shiyi)),
    );
  }

  Widget _buildTab() {
    final shiyi = widget.shiyi;
    switch (_tab) {
      case 0:
        return _SessionsTab(
          shiyi: shiyi,
          onOpenSettings: () => setState(() => _tab = 4),
        );
      case 1:
        return MemoryScreen(shiyi: shiyi);
      case 2:
        return SkillsScreen(shiyi: shiyi);
      case 3:
        return FilesScreen(shiyi: shiyi);
      case 4:
        return SettingsScreen(shiyi: shiyi);
      case 5:
        return const LogScreen();
      case 6:
        return TerminalScreen(shiyi: shiyi);
    }
    return const SizedBox.shrink();
  }
}

/// macOS 风格左侧边栏：顶部红绿灯 + 图标导航（选中项圆角高亮）。
class _MacSidebar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onToggle;
  final VoidCallback onNewSession;
  const _MacSidebar({
    required this.selected,
    required this.onSelect,
    required this.onToggle,
    required this.onNewSession,
  });

  static const List<({IconData icon, IconData selectedIcon, String label})>
  _items = [
    (icon: Icons.forum_outlined, selectedIcon: Icons.forum, label: '会话'),
    (icon: Icons.memory_outlined, selectedIcon: Icons.memory, label: '记忆'),
    (
      icon: Icons.rocket_launch_outlined,
      selectedIcon: Icons.rocket_launch,
      label: '技能',
    ),
    (icon: Icons.folder_outlined, selectedIcon: Icons.folder, label: '文件'),
    (icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置'),
    (icon: Icons.article_outlined, selectedIcon: Icons.article, label: '日志'),
    (
      icon: Icons.terminal_outlined,
      selectedIcon: Icons.terminal,
      label: '终端',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 84,
      decoration: BoxDecoration(
        color: cs.surfaceContainer.withValues(alpha: .96),
        border: Border(
          right: BorderSide(color: cs.outlineVariant.withValues(alpha: .6)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .28),
            blurRadius: 22,
            offset: const Offset(5, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + 15),
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  _TrafficDot(Color(0xFFFF5F57)),
                  SizedBox(width: 6),
                  _TrafficDot(Color(0xFFFEBC2E)),
                  SizedBox(width: 6),
                  _TrafficDot(Color(0xFF28C840)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SidebarItem(
            item: (
              icon: Icons.add_comment_outlined,
              selectedIcon: Icons.add_comment,
              label: '新会话',
            ),
            selected: false,
            onTap: onNewSession,
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < _items.length; i++) ...[
            _SidebarItem(
              item: _items[i],
              selected: selected == i,
              onTap: () => onSelect(i),
            ),
            const SizedBox(height: 4),
          ],
          const Spacer(),
          Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 14,
            ),
            child: Icon(
              Icons.smart_toy_outlined,
              size: 20,
              color: cs.onSurfaceVariant.withValues(alpha: .45),
            ),
          ),
        ],
      ),
    );
  }
}

/// 侧边栏收起后的悬浮入口：横排红绿灯小胶囊，点击展开侧边栏。
class _FloatingTrafficLights extends StatelessWidget {
  final VoidCallback onTap;
  const _FloatingTrafficLights({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainer.withValues(alpha: .95),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isLight ? .16 : .35),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                _TrafficDot(Color(0xFFFF5F57)),
                SizedBox(width: 5),
                _TrafficDot(Color(0xFFFEBC2E)),
                SizedBox(width: 5),
                _TrafficDot(Color(0xFF28C840)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrafficDot extends StatelessWidget {
  final Color color;
  const _TrafficDot(this.color);
  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      // 细描边让圆点在浅色背景下也清晰可辨。
      border: Border.all(color: Colors.black.withValues(alpha: .18), width: 1),
    ),
  );
}

class _SidebarItem extends StatelessWidget {
  final ({IconData icon, IconData selectedIcon, String label}) item;
  final bool selected;
  final VoidCallback onTap;
  const _SidebarItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 66,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: .13)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Icon(
              selected ? item.selectedIcon : item.icon,
              size: 22,
              color: selected ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(height: 3),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 10,
                color: selected ? cs.primary : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionsTab extends StatefulWidget {
  final ShiyiState shiyi;
  final VoidCallback onOpenSettings;
  const _SessionsTab({required this.shiyi, required this.onOpenSettings});

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  ShiyiState get shiyi => widget.shiyi;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 左侧对称占位，让标题真正居中。
        leading: const SizedBox(width: 48),
        title: const Text('拾忆', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _FrostedSettingsButton(onPressed: widget.onOpenSettings),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索会话或消息内容',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清除',
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  void _openNewSession() async {
    await shiyi.newSession();
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
      if (shiyi.sessions.isEmpty) {
        return _EmptyState(onCreate: _openNewSession);
      }
      return _centeredList(
        ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: shiyi.sessions.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, indent: 16, endIndent: 16),
          itemBuilder: (context, i) =>
              _SessionTile(shiyi: shiyi, session: shiyi.sessions[i]),
        ),
      );
    }
    return FutureBuilder<List<SessionSearchResult>>(
      future: shiyi.searchSessions(q),
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
            separatorBuilder: (_, _) =>
                const Divider(height: 1, indent: 16, endIndent: 16),
            itemBuilder: (context, i) => _SessionTile(
              shiyi: shiyi,
              session: results[i].session,
              snippet: results[i].snippet,
            ),
          ),
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ShiyiState shiyi;
  final Session session;
  final String snippet;
  const _SessionTile({
    required this.shiyi,
    required this.session,
    this.snippet = '',
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    final theme = Theme.of(context);
    final busy = shiyi.isBusy && shiyi.busySessionId == s.id;
    final unread = shiyi.unreadSessions.contains(s.id);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: SizedBox(
        width: 34,
        height: 34,
        child: WelcomeAvatar(size: 32, asset: 'assets/avatar.png'),
      ),
      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: busy
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '思考中…',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            )
          : snippet.isNotEmpty
          ? Text(snippet, maxLines: 1, overflow: TextOverflow.ellipsis)
          : Text(
              '${s.messageCount} 条消息 · ${_fmtTime(s.updatedAt)}${s.model.isEmpty ? '' : ' · ${s.model}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () async {
        await shiyi.selectSession(s.id);
        if (context.mounted) {
          Navigator.push(
            context,
            MacPageRoute(
              builder: (_) => ChatScreen(shiyi: shiyi, sessionId: s.id),
            ),
          );
        }
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'rename') {
                await _rename(context, shiyi, s);
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除会话'),
                    content: Text('确定删除「${s.title}」及其全部消息吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          '删除',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                );
                if (ok == true) await shiyi.deleteSession(s.id);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _rename(
  BuildContext context,
  ShiyiState shiyi,
  Session s,
) async {
  final controller = TextEditingController(text: s.title);
  final title = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (title != null && title.isNotEmpty) {
    await shiyi.renameSession(s.id, title);
  }
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
          Text('与拾忆开始对话', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '跨会话记忆 · 技能沉淀 · 工具调用',
            style: theme.textTheme.bodyMedium!.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('创建一个会话'),
            style: FilledButton.styleFrom(
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
              textStyle: theme.textTheme.labelLarge,
              elevation: 0,
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
    );
  }
}
