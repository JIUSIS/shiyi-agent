import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../services/dsh_api.dart';
import '../services/dsh_model_sync.dart';
import '../services/dsh_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';
import 'dsh_center_screen.dart';
import 'dsh_chat_screen.dart';

/// DeepSeek Harness 引擎会话列表：Agent 引擎切到 DeepSeek Harness 时
/// 替代本地会话 tab。视觉与拾忆会话列表一致（Inset Grouped + 左上新建
/// 加号胶囊 + 右上设置入口），数据来自 DeepSeek Harness API。
/// 右上角设置入口随引擎切换：DS Harness 引擎下打开 DS Harness 中心。
/// [onOpenTab]：拾忆主页 tab 切换回调，透传给 DS Harness 中心
///（工作区/技能/文件对接拾忆会话/功能/文件）。
class DshSessionsTab extends StatefulWidget {
  final ShiyiState shiyi;
  const DshSessionsTab({super.key, required this.shiyi});

  @override
  State<DshSessionsTab> createState() => _DshSessionsTabState();
}

class _DshSessionsTabState extends State<DshSessionsTab> {
  List<DshSessionSummary> _sessions = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;
  bool _updatePrompted = false;

  DshApiClient get _api => DshApiClient.instance;

  @override
  void initState() {
    super.initState();
    _load();
    // 运行中会话的状态会变化，30s 轻量刷新一次（阶段 1 轮询过渡）。
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _load(silent: true);
    });
    // 进入 DSH 模式：自动检查一次更新（开关开启时），发现新版提示。
    unawaited(_autoCheckUpdate());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// 提示式更新：检测到新版弹窗让用户选择「更新 / 暂不」。
  Future<void> _autoCheckUpdate() async {
    if (!widget.shiyi.settings.dshAutoCheckUpdate) return;
    if (_updatePrompted) return;
    try {
      final latest = await DshService.instance.checkLatestVersion();
      final local = await DshService.instance.localVersion();
      if (latest == null || local == null) return;
      if (DshService.compareSemver(latest, local) <= 0) return;
      _updatePrompted = true;
      if (!mounted) return;
      final update = await showIosFadeDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('发现新版本'),
          content: Text(
            'DeepSeek Harness 有新版本：\n$latest（当前 $local）\n\n'
            '更新会重启 DeepSeek Harness 服务（当前会话会中断）。',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('暂不'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('立即更新'),
            ),
          ],
        ),
      );
      if (update != true || !mounted) return;
      await DshService.instance.installOrUpdate(latest, isUpdate: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('DeepSeek Harness 已更新到 $latest，可到设置页启动服务')),
      );
    } catch (_) {
      // 更新检测/安装失败不打扰主流程。
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (silent && _sessions.isNotEmpty) {
      try {
        final list = await _api.listSessions();
        if (!mounted) return;
        setState(() {
          _sessions = list;
          _error = null;
        });
      } catch (_) {
        // 静默刷新失败不打扰（下次刷新或手动重试再报）。
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _api.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _newSession() async {
    try {
      final id = await _api.createSession();
      if (!mounted || id.isEmpty) return;
      try {
        await DshModelSync.applyToSession(_api, id, widget.shiyi.settings);
      } catch (_) {}
      await _openChat(id, '新会话');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('新建 DeepSeek Harness 会话失败：$e')));
    }
  }

  Future<void> _openChat(
    String sessionId,
    String? title, {
    DshSessionSummary? summary,
  }) async {
    await openDshChat(
      context,
      sessionId: sessionId,
      initialTitle: title ?? '会话',
      initialSummary: summary,
      shiyi: widget.shiyi,
    );
    // 返回后刷新列表（标题/时间可能变化）。
    if (mounted) await _load(silent: true);
  }

  Future<void> _rename(DshSessionSummary s) async {
    final ctrl = TextEditingController(text: s.title ?? '');
    final newTitle = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('重命名会话'),
        content: CupertinoTextField(controller: ctrl, autofocus: true),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty) return;
    try {
      await _api.renameSession(s.sessionId, newTitle);
      if (mounted) _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
  }

  String _timeLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.month}月${d.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: iosGroupedBackground(context),
      appBar: AppBar(
        leadingWidth: 72,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          // 与拾忆会话页同款红绿灯胶囊（三个红黄绿点），点击新建会话。
          child: TrafficLightsButton(
            busy: false,
            tooltip: '新建 DeepSeek Harness 会话',
            onTap: _newSession,
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
          'DS Harness',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
        // 右上角：设置入口随引擎切换 —— DS Harness 引擎下打开 DS Harness 中心
        //（模型/预设/工作区/技能/设置/引擎切换全在此）。
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FrostedSettingsButton(onPressed: _openCenter),
          ),
        ],
      ),
      body: _buildBody(dark),
    );
  }

  void _openCenter() {
    Navigator.push(
      context,
      MacPageRoute(builder: (_) => DshCenterScreen(shiyi: widget.shiyi)),
    ).then((_) {
      if (mounted) _load(silent: true);
    });
  }

  Widget _buildBody(bool dark) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.exclamationmark_triangle,
                size: 42,
                color: CupertinoColors.systemRed,
              ),
              const SizedBox(height: 12),
              Text(
                '无法连接 DeepSeek Harness 服务',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '请确认 DeepSeek Harness 正在本机运行（http://127.0.0.1:3080）。\n'
                '可在设置 →「Agent 引擎」切回拾忆引擎。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
              const SizedBox(height: 12),
              CupertinoButton.filled(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.chevron_left_slash_chevron_right,
              size: 48,
              color: CupertinoColors.systemGrey,
            ),
            const SizedBox(height: 12),
            const Text('还没有 DeepSeek Harness 会话'),
            const SizedBox(height: 14),
            CupertinoButton.filled(
              onPressed: _newSession,
              child: const Text('新建会话'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 20),
        children: [
          CupertinoListSection.insetGrouped(
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [
              for (final s in _sessions)
                CupertinoListTile(
                  key: ValueKey(s.sessionId),
                  leading: const Icon(
                    CupertinoIcons.chat_bubble_2_fill,
                    color: CupertinoColors.activeBlue,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          s.title == null || s.title!.isEmpty
                              ? '未命名会话'
                              : s.title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (s.running) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: CupertinoColors.systemGreen,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    '${_timeLabel(s.updatedAt)}'
                    '${s.turnCount > 0 ? ' · ${s.turnCount} 轮' : ''}'
                    '${s.blank ? ' · 空' : ''}',
                  ),
                  trailing: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => _rename(s),
                    child: const Icon(CupertinoIcons.ellipsis),
                  ),
                  onTap: () =>
                      unawaited(_openChat(s.sessionId, s.title, summary: s)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
