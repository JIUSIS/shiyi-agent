import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../services/dsh_api.dart';
import '../services/dsh_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import 'dsh_center_screen.dart';
import 'dsh_chat_screen.dart';

const _skillColors = <Color>[
  Color(0xFF0A84FF),
  Color(0xFF30D158),
  Color(0xFFFF9F0A),
  Color(0xFFBF5AF2),
  Color(0xFFFF453A),
];

/// DSH 会话作用域内的可调用技能目录。
class DshSkillsScreen extends StatefulWidget {
  final bool asTab;
  final ShiyiState? shiyi;
  final String? sessionId;
  const DshSkillsScreen({
    super.key,
    this.asTab = false,
    this.shiyi,
    this.sessionId,
  });

  @override
  State<DshSkillsScreen> createState() => _DshSkillsScreenState();
}

class _DshSkillsScreenState extends State<DshSkillsScreen> {
  final TextEditingController _search = TextEditingController();
  List<DshSessionSummary> _sessions = [];
  List<DshSkillInfo> _skills = [];
  Set<String> _sessionSkillNames = const {};
  DshSessionSummary? _selectedSession;
  StreamSubscription<Map<String, dynamic>>? _hostSub;
  bool _loading = true;
  String _query = '';
  String? _error;
  int _loadGeneration = 0;

  DshApiClient get _api => DshService.instance.api;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearch);
    unawaited(_load());
    unawaited(_connectHostEvents());
  }

  @override
  void dispose() {
    _loadGeneration++;
    _hostSub?.cancel();
    _search
      ..removeListener(_onSearch)
      ..dispose();
    super.dispose();
  }

  void _onSearch() {
    final value = _search.text.trim().toLowerCase();
    if (value == _query || !mounted) return;
    setState(() => _query = value);
  }

  Future<void> _connectHostEvents() async {
    try {
      _hostSub = _api.watchHost().listen((frame) {
        if (!mounted || frame['type'] != 'host/remote-event') return;
        if (frame['event']?.toString() != 'agent-preset/selected') return;
        final args = (frame['args'] as List?) ?? const [];
        final sid = args.isEmpty ? '' : args.first.toString();
        if (sid.isEmpty || sid == _selectedSession?.sessionId) {
          unawaited(_load(showSpinner: false));
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  Future<void> _load({bool showSpinner = true}) async {
    final generation = ++_loadGeneration;
    if (mounted && showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      if (!await DshService.instance.ensureRunning()) {
        final message = DshService.instance.statusMessage.value.trim();
        throw DshApiException(message.isEmpty ? 'DSH 服务未启动' : message);
      }
      final sessions = await _api.listSessions();
      if (!mounted || generation != _loadGeneration) return;
      final preferredId =
          _selectedSession?.sessionId ?? widget.sessionId?.trim();
      DshSessionSummary? selected;
      if (preferredId != null && preferredId.isNotEmpty) {
        selected = sessions
            .where((session) => session.sessionId == preferredId)
            .firstOrNull;
      }
      selected ??= sessions.firstOrNull;
      final skills = selected == null
          ? <DshSkillInfo>[]
          : await _loadSkillsWithRetry(selected);
      final sessionSkillNames = selected == null
          ? <String>{}
          : await _sessionSkillNamesFor(
              selected,
              sessions: sessions,
              selectedSkills: skills,
            );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _sessions = sessions;
        _selectedSession = selected;
        _skills = skills;
        _sessionSkillNames = sessionSkillNames;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = _friendlySkillError(e);
      });
    }
  }

  String _friendlySkillError(Object error) {
    if (error is DshApiException) {
      if (error.code == 'session-not-found' || error.code == 'bad-request') {
        return '技能需要会话挂载后读取：请先打开一个 DSH 会话再刷新。';
      }
      if (error.code == 'session-conflict') {
        return '技能读取失败：会话工作目录与 DSH 记录不一致。';
      }
    }
    return '$error';
  }

  Future<List<DshSkillInfo>> _loadSkillsWithRetry(
    DshSessionSummary session,
  ) async {
    Future<List<DshSkillInfo>> load() async {
      await _ensureAttached(session);
      return _api.listSkills(sessionId: session.sessionId);
    }

    try {
      return await load();
    } catch (_) {
      // DSH 启动后 session.list 通常先于技能索引就绪，给索引一次
      // 很短的稳定窗口；第二次仍失败才交给页面错误态展示。
      await Future<void>.delayed(const Duration(milliseconds: 220));
      return load();
    }
  }

  /// skill.list 要求会话已挂载；DSH 冷会话先用 session.create 复用身份挂载。
  Future<void> _ensureAttached(DshSessionSummary session) async {
    final cwd = session.cwd?.trim() ?? '';
    await _api.createSession(
      cwd: cwd.isEmpty ? null : cwd,
      sessionId: session.sessionId,
    );
  }

  List<DshSkillInfo> get _filteredSkills {
    if (_query.isEmpty) return _skills;
    return _skills.where((skill) {
      return skill.name.toLowerCase().contains(_query) ||
          skill.description.toLowerCase().contains(_query) ||
          (skill.whenToUse?.toLowerCase().contains(_query) ?? false);
    }).toList();
  }

  List<DshSkillInfo> get _filteredGlobalSkills => _filteredSkills
      .where((skill) => !_sessionSkillNames.contains(skill.name))
      .toList();

  List<DshSkillInfo> get _filteredSessionSkills => _filteredSkills
      .where((skill) => _sessionSkillNames.contains(skill.name))
      .toList();

  Future<Set<String>> _sessionSkillNamesFor(
    DshSessionSummary session, {
    required List<DshSessionSummary> sessions,
    required List<DshSkillInfo> selectedSkills,
  }) async {
    final cwd = session.cwd?.trim() ?? '';
    if (cwd.isEmpty) return <String>{};
    final roots = <String>[
      p.join(cwd, '.dsh', 'skills'),
      p.join(cwd, '.agents', 'skills'),
    ];
    final names = <String>{};
    for (final root in roots) {
      try {
        final entries = await _api.listDirectory(root);
        for (final entry in entries) {
          final name = entry.name.endsWith('.md')
              ? entry.name.substring(0, entry.name.length - 3)
              : entry.name;
          if (name.isNotEmpty) names.add(name);
        }
      } catch (_) {
        // 目录不存在就是当前范围没有技能；skill.list 仍提供全局目录。
      }
    }
    final comparison = sessions
        .where(
          (other) =>
              other.sessionId != session.sessionId &&
              other.cwd?.trim() != session.cwd?.trim(),
        )
        .firstOrNull;
    if (comparison != null) {
      try {
        final common = (await _api.listSkills(
          sessionId: comparison.sessionId,
        )).map((skill) => skill.name).toSet();
        names.addAll(
          selectedSkills
              .map((skill) => skill.name)
              .where((name) => !common.contains(name)),
        );
      } catch (_) {
        // 对照会话不可用时继续使用目录归类，不影响主目录展示。
      }
    }
    return names;
  }

  void _pop() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _chooseSession() async {
    if (_sessions.isEmpty) return;
    final selected = await showIosFadeModalPopup<DshSessionSummary>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: CupertinoActionSheet(
          title: const Text('选择技能所属会话'),
          actions: [
            for (final session in _sessions)
              CupertinoActionSheetAction(
                isDefaultAction:
                    session.sessionId == _selectedSession?.sessionId,
                onPressed: () => Navigator.pop(ctx, session),
                child: Text(
                  session.title?.trim().isNotEmpty == true
                      ? session.title!
                      : '未命名会话',
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
    if (selected == null || !mounted) return;
    setState(() => _selectedSession = selected);
    await _load();
  }

  Future<void> _copyInvocation(DshSkillInfo skill) async {
    await Clipboard.setData(ClipboardData(text: '/${skill.name} '));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制 /${skill.name}')));
  }

  Future<void> _openInSession(DshSkillInfo skill) async {
    final session = _selectedSession;
    if (session == null) return;
    await openDshChat(
      context,
      sessionId: session.sessionId,
      initialTitle: session.title ?? '新会话',
      initialSummary: session,
      initialInput: '/${skill.name} ',
      shiyi: widget.shiyi,
    );
  }

  void _showSkill(DshSkillInfo skill) {
    showIosFadeSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '/${skill.name}',
                style: Theme.of(
                  ctx,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                skill.modelInvocable ? '模型可调用' : '仅限用户手动调用',
                style: TextStyle(
                  color: skill.modelInvocable
                      ? CupertinoColors.systemGreen
                      : CupertinoColors.systemOrange,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (skill.description.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(skill.description),
              ],
              if (skill.whenToUse?.isNotEmpty == true) ...[
                const SizedBox(height: 14),
                Text('适用场景', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(skill.whenToUse!),
              ],
              const SizedBox(height: 20),
              CupertinoButton.filled(
                onPressed: () {
                  Navigator.pop(ctx);
                  unawaited(_openInSession(skill));
                },
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(CupertinoIcons.chat_bubble_text, size: 18),
                    SizedBox(width: 8),
                    Text('在会话中使用'),
                  ],
                ),
              ),
              CupertinoButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  unawaited(_copyInvocation(skill));
                },
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(CupertinoIcons.doc_on_doc, size: 18),
                    SizedBox(width: 8),
                    Text('复制调用指令'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: iosGroupedBackground(context),
      appBar: AppBar(
        leadingWidth: 72,
        leading: widget.asTab
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: MacActionButton(
                    icon: CupertinoIcons.chevron_left,
                    tooltip: '返回',
                    onTap: _pop,
                  ),
                ),
              ),
        toolbarHeight: 64,
        centerTitle: true,
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        clipBehavior: Clip.none,
        title: const Text(
          '技能',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: widget.asTab
                ? FrostedSettingsButton(
                    onPressed: () => Navigator.push(
                      context,
                      MacPageRoute(
                        builder: (_) => DshCenterScreen(shiyi: widget.shiyi),
                      ),
                    ),
                  )
                : MacActionButton(
                    icon: CupertinoIcons.refresh,
                    tooltip: '刷新',
                    onTap: _loading ? null : _load,
                  ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _sessions.isEmpty && _skills.isEmpty) {
      return const Center(child: CupertinoActivityIndicator(radius: 13));
    }
    if (_error != null && _sessions.isEmpty) {
      return _StateMessage(
        icon: CupertinoIcons.exclamationmark_triangle,
        title: '技能加载失败',
        detail: _error!,
        action: '重试',
        onAction: _load,
      );
    }
    if (_selectedSession == null) {
      return _StateMessage(
        icon: CupertinoIcons.chat_bubble_2,
        title: '还没有 DSH 会话',
        detail: '创建会话后即可读取对应工作目录与预设中的技能。',
        action: '刷新',
        onAction: _load,
      );
    }

    final filtered = _filteredSkills;
    final sessionSkills = _filteredSessionSkills;
    final globalSkills = _filteredGlobalSkills;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          _pageIntro(),
          const SizedBox(height: 10),
          _sessionCard(),
          const SizedBox(height: 12),
          CupertinoSearchTextField(
            controller: _search,
            placeholder: '搜索名称、描述或适用场景',
          ),
          const SizedBox(height: 14),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 52),
              child: Column(
                children: [
                  Icon(
                    _query.isEmpty
                        ? CupertinoIcons.book
                        : CupertinoIcons.search,
                    size: 34,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _query.isEmpty ? '当前会话没有可用技能' : '没有匹配的技能',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          else ...[
            if (sessionSkills.isNotEmpty)
              _skillSection(
                title: '会话技能',
                subtitle: '当前工作目录提供',
                skills: sessionSkills,
                offset: 0,
              ),
            if (globalSkills.isNotEmpty)
              _skillSection(
                title: '全局技能',
                subtitle: '用户、内置与当前预设',
                skills: globalSkills,
                offset: sessionSkills.length,
              ),
          ],
        ],
      ),
    );
  }

  Widget _pageIntro() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '可调用技能',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${_skills.length} 个技能 · 在会话输入框输入 / 可多选加载',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _sessionCard() {
    final theme = Theme.of(context);
    final session = _selectedSession!;
    final title = session.title?.trim().isNotEmpty == true
        ? session.title!
        : '未命名会话';
    final cwd = session.cwd?.trim() ?? '';
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: .58),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _chooseSession,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          child: Row(
            children: [
              _coloredIcon(
                CupertinoIcons.chat_bubble_2_fill,
                const Color(0xFF5856D6),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (cwd.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        cwd,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _skillSection({
    required String title,
    required String subtitle,
    required List<DshSkillInfo> skills,
    required int offset,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  '${skills.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < skills.length; i++) ...[
                  _skillTile(skills[i], i + offset),
                  if (i < skills.length - 1)
                    Divider(
                      height: 1,
                      indent: 58,
                      color: theme.dividerColor.withValues(alpha: .35),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _skillTile(DshSkillInfo skill, int index) {
    final badgeColor = skill.modelInvocable
        ? CupertinoColors.systemGreen.resolveFrom(context)
        : CupertinoColors.systemOrange.resolveFrom(context);
    return CupertinoListTile(
      key: ValueKey(skill.name),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      leading: _coloredIcon(
        CupertinoIcons.book_fill,
        _skillColors[index % _skillColors.length],
      ),
      title: Text(
        '/${skill.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: skill.description.isEmpty
          ? Text(
              skill.modelInvocable ? '可由模型调用' : '需手动调用',
              style: TextStyle(
                fontSize: 12,
                color: skill.modelInvocable
                    ? CupertinoColors.systemGreen.resolveFrom(context)
                    : CupertinoColors.systemOrange.resolveFrom(context),
              ),
            )
          : Text(
              skill.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          skill.modelInvocable ? '模型' : '手动',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: badgeColor,
          ),
        ),
      ),
      onTap: () => _showSkill(skill),
    );
  }

  Widget _coloredIcon(IconData icon, Color color) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: CupertinoColors.white),
    );
  }
}

class _StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final String action;
  final Future<void> Function() onAction;
  const _StateMessage({
    required this.icon,
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 38,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: () => unawaited(onAction()),
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}
