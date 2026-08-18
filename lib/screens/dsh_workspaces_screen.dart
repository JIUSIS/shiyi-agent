import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../services/dsh_api.dart';
import '../services/dsh_model_sync.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';
import 'dsh_center_screen.dart';
import 'dsh_chat_screen.dart';

/// 工作区页（Apple HIG Inset Grouped）：
/// 列表（workspace.list）/ 新建采用目录（workspace.create）/
/// 重命名 / 删除 / 归档会话。
/// [asTab]：作为 DS Harness 引擎的主页 tab（tab 0）时无返回键、
/// 左上红绿灯 = 新建工作区（workspace.create），并追加「会话」
/// section（session.list，点击进入聊天，头部可新建 DS Harness 会话）。
class DshWorkspacesScreen extends StatefulWidget {
  final bool asTab;
  final ShiyiState? shiyi;
  const DshWorkspacesScreen({super.key, this.asTab = false, this.shiyi});

  @override
  State<DshWorkspacesScreen> createState() => _DshWorkspacesScreenState();
}

class _DshWorkspacesScreenState extends State<DshWorkspacesScreen> {
  List<DshWorkspace> _items = [];
  List<String> _archived = [];
  List<DshSessionSummary> _sessions = [];
  bool _loading = true;
  String? _error;
  bool _busy = false;

  DshApiClient get _api => DshApiClient.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _api.listWorkspaces();
      if (!mounted) return;
      setState(() {
        _items = r.items;
        _archived = r.archivedSessionIds;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
    if (widget.asTab) await _loadSessions(silent: true);
  }

  Future<void> _loadSessions({bool silent = false}) async {
    try {
      final list = await _api.listSessions();
      if (!mounted) return;
      setState(() => _sessions = list);
    } catch (_) {
      // 会话列表失败不阻塞工作区主体。
    }
  }

  Future<void> _create() async {
    final ctrl = TextEditingController();
    String? picked;
    final path = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('新建工作区'),
        content: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CupertinoTextField(
                controller: ctrl,
                placeholder: '目录路径（如 /storage/emulated/0/Documents）',
                autofocus: true,
                scrollPadding: const EdgeInsets.only(bottom: 120),
              ),
              const SizedBox(height: 12),
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () async {
                  final dir = await FilePicker.platform.getDirectoryPath();
                  if (dir == null || dir.isEmpty) return;
                  ctrl.text = dir;
                  picked = dir;
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: iosSectionBackground(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        CupertinoIcons.folder,
                        size: 18,
                        color: CupertinoColors.activeBlue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          picked ?? '选择手机文件夹',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: picked == null
                                ? CupertinoColors.secondaryLabel
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    setState(() => _busy = true);
    try {
      final w = await _api.createWorkspace(path);
      if (!mounted) return;
      _toast('已创建「${w.title}」');
      _load();
    } catch (e) {
      _toast('创建失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newSession() async {
    try {
      final id = await _api.createSession();
      if (!mounted || id.isEmpty) return;
      final shiyi = widget.shiyi;
      if (shiyi != null) {
        try {
          await DshModelSync.applyToSession(_api, id, shiyi.settings);
        } catch (_) {}
      }
      if (!mounted) return;
      await openDshChat(
        context,
        sessionId: id,
        initialTitle: '新会话',
        shiyi: widget.shiyi,
      );
      if (mounted) await _loadSessions(silent: true);
    } catch (e) {
      if (!mounted) return;
      _toast('新建 DeepSeek Harness 会话失败：$e');
    }
  }

  Future<void> _rename(DshWorkspace w) async {
    final ctrl = TextEditingController(text: w.title);
    final title = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('重命名工作区'),
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
    if (title == null || title.isEmpty) return;
    try {
      await _api.renameWorkspace(w.workspaceId, title);
      if (!mounted) return;
      _toast('已重命名');
      _load();
    } catch (e) {
      _toast('重命名失败：$e');
    }
  }

  Future<void> _delete(DshWorkspace w) async {
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除工作区'),
        content: Text('确定删除「${w.title}」吗？\n（不会删除目录文件）'),
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
    );
    if (ok != true) return;
    try {
      await _api.deleteWorkspace(w.workspaceId);
      if (!mounted) return;
      _toast('已删除');
      _load();
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _pop() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: iosGroupedBackground(context),
      appBar: AppBar(
        leadingWidth: 72,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: widget.asTab
              // 主页 tab：红绿灯 = 新建工作区（workspace.create）。
              ? TrafficLightsButton(
                  busy: _busy,
                  tooltip: '新建工作区',
                  onTap: _busy ? null : _create,
                )
              : Align(
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
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 主页 tab：点标题刷新。
          onTap: widget.asTab ? _load : null,
          child: Text(
            '工作数据',
            style: TextStyle(
              fontSize: widget.asTab ? 28 : 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                if (!widget.asTab) ...[
                  MacActionButton(
                    icon: CupertinoIcons.refresh,
                    tooltip: '刷新',
                    onTap: _load,
                  ),
                  const SizedBox(width: 4),
                  MacActionButton(
                    icon: CupertinoIcons.plus,
                    tooltip: '新建工作区',
                    onTap: _busy ? null : _create,
                  ),
                ] else ...[
                  // 主页 tab：右上角留给设置（DS Harness 中心）。
                  FrostedSettingsButton(
                    onPressed: () => Navigator.push(
                      context,
                      MacPageRoute(
                        builder: (_) => DshCenterScreen(shiyi: widget.shiyi),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            CupertinoButton.filled(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty && _archived.isEmpty && _sessions.isEmpty) {
      return Center(
        child: widget.asTab
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.folder,
                    size: 48,
                    color: CupertinoColors.systemGrey,
                  ),
                  const SizedBox(height: 12),
                  const Text('还没有工作数据'),
                  const SizedBox(height: 14),
                  CupertinoButton.filled(
                    onPressed: _busy ? null : _create,
                    child: const Text('添加工作数据'),
                  ),
                ],
              )
            : const Text('暂无工作数据，点右上角 + 创建'),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        if (_items.isNotEmpty)
          CupertinoListSection.insetGrouped(
            header: const Text('工作数据'),
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [
              for (final w in _items)
                CupertinoListTile(
                  key: ValueKey(w.workspaceId),
                  leading: const Icon(
                    CupertinoIcons.folder,
                    color: CupertinoColors.activeBlue,
                  ),
                  title: Text(
                    w.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${w.sessionIds.length} 个会话',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  trailing: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => _workspaceActions(w),
                    child: const Icon(CupertinoIcons.ellipsis),
                  ),
                ),
            ],
          ),
        if (_archived.isNotEmpty)
          CupertinoListSection.insetGrouped(
            header: const Text('已归档会话'),
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [
              for (final id in _archived)
                CupertinoListTile(
                  key: ValueKey('arch-$id'),
                  leading: const Icon(
                    CupertinoIcons.archivebox,
                    color: CupertinoColors.systemGrey,
                  ),
                  title: Text(id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: const Text('已归档', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        // 主页 tab：追加「会话」section（DS Harness 会话，点击进入聊天）。
        if (widget.asTab)
          CupertinoListSection.insetGrouped(
            header: Row(
              children: [
                const Expanded(child: Text('会话')),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _newSession,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.plus, size: 14),
                      SizedBox(width: 2),
                      Text('新建', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
              ],
            ),
            margin: iosSectionMargin,
            decoration: iosSectionDecoration(context),
            children: [
              if (_sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text(
                      '暂无会话，点右上角「新建」开始对话',
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.secondaryLabel,
                      ),
                    ),
                  ),
                )
              else
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
                      '${s.turnCount > 0 ? '${s.turnCount} 轮' : ''}'
                      '${s.blank ? ' · 空' : ''}',
                    ),
                    onTap: () async {
                      await openDshChat(
                        context,
                        sessionId: s.sessionId,
                        initialTitle: s.title == null || s.title!.isEmpty
                            ? '会话'
                            : s.title!,
                        initialSummary: s,
                        shiyi: widget.shiyi,
                      );
                      if (mounted) await _loadSessions(silent: true);
                    },
                  ),
            ],
          ),
      ],
    );
  }

  void _workspaceActions(DshWorkspace w) {
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(w.title),
        message: Text(w.path),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _rename(w);
            },
            child: const Text('重命名'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              _delete(w);
            },
            child: const Text('删除工作区'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }
}
