import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../services/dsh_api.dart';
import '../services/dsh_chat_cache.dart';
import '../services/dsh_model_sync.dart';
import '../services/dsh_service.dart';
import '../services/file_workspace.dart';
import '../widgets/context_menu.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';
import '../widgets/welcome_avatar.dart';
import 'dsh_center_screen.dart';
import 'dsh_chat_screen.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosRed = Color(0xFFFF3B30);
const _iosGreen = Color(0xFF34C759);
const _iosGray = Color(0xFF8E8E93);

/// 默认 agent 目录工作区显示为「默认」；用户改过名则保留。
String dshNormalizedPath(String path) {
  var p = path.replaceAll(r'\\', '/');
  if (p.length > 1 && p.endsWith('/')) p = p.substring(0, p.length - 1);
  return p;
}

bool dshIsDefaultWorkspacePath(String path, String defaultPath) {
  return dshNormalizedPath(path) == dshNormalizedPath(defaultPath);
}

String dshWorkspaceDisplayName(String title, String path, String defaultPath) {
  final p = dshNormalizedPath(path);
  var folder = p;
  final slash = p.lastIndexOf('/');
  if (slash >= 0) folder = p.substring(slash + 1);
  final t = title.trim();
  if (dshIsDefaultWorkspacePath(path, defaultPath) &&
      (t.isEmpty || t.toLowerCase() == 'agent' || t == folder)) {
    return '默认';
  }
  if (t.isEmpty) return folder.isEmpty ? '工作区' : folder;
  return t;
}

const dshWorkspaceExpandedPrefsKey = 'dsh_workspace_expanded_v1';
const dshWorkspaceListCacheKey = 'dsh_workspace_list_cache_v1';

/// 主页工作区/会话列表的本地缓存：冷启动或服务未就绪时先显示上次数据，
/// 避免加载页长时间挡住主页；服务就绪后由 [_load] 静默刷新覆盖。
Future<String?> dshReadWorkspaceListCache() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(dshWorkspaceListCacheKey);
}

Future<void> dshWriteWorkspaceListCache({
  required List<DshWorkspace> workspaces,
  required List<DshSessionSummary> sessions,
  required List<String> archivedSessionIds,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    dshWorkspaceListCacheKey,
    jsonEncode({
      'workspaces': workspaces.map((w) => w.toJson()).toList(),
      'sessions': sessions.map((s) => s.toJson()).toList(),
      'archivedSessionIds': archivedSessionIds,
    }),
  );
}

/// 读回工作区展开状态；键不存在返回 null（首次启动走默认展开）。
Future<List<String>?> dshLoadExpandedWorkspaceIds() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(dshWorkspaceExpandedPrefsKey);
}

Future<void> dshSaveExpandedWorkspaceIds(Iterable<String> ids) async {
  final prefs = await SharedPreferences.getInstance();
  final list = ids.toSet().toList()..sort();
  await prefs.setStringList(dshWorkspaceExpandedPrefsKey, list);
}

/// 先看工作区 sessionIds；没有归属时按会话 cwd 匹配工作区路径。
List<String> dshWorkspaceIdsForSession({
  required String sessionId,
  required String? cwd,
  required List<DshWorkspace> workspaces,
  required String? defaultWorkspaceId,
}) {
  final owned = <String>[
    for (final w in workspaces)
      if (w.sessionIds.contains(sessionId)) w.workspaceId,
  ];
  if (owned.isNotEmpty) return owned;
  if (cwd != null && cwd.trim().isNotEmpty) {
    final n = dshNormalizedPath(cwd);
    final byCwd = <String>[
      for (final w in workspaces)
        if (dshNormalizedPath(w.path) == n) w.workspaceId,
    ];
    if (byCwd.isNotEmpty) return byCwd;
  }
  if (defaultWorkspaceId != null) return [defaultWorkspaceId];
  return const [];
}

/// session.list 仍会返回已归档会话；不按 archivedSessionIds 过滤的话，
/// 「未归属并入默认工作区」会把刚归档的会话塞回去。
List<DshSessionSummary> dshActiveSessions(
  List<DshSessionSummary> sessions,
  Iterable<String> archivedIds,
) {
  final archived = archivedIds.toSet();
  if (archived.isEmpty) return List<DshSessionSummary>.from(sessions);
  return sessions.where((s) => !archived.contains(s.sessionId)).toList();
}

/// DS Harness 引擎的主页 tab 0「工作区」：
/// 外观完全复用拾忆会话页（红绿灯/大标题/搜索框/项目分组/卡片左滑），
/// 接口数据为 DeepSeek Harness：
/// - 项目分组 = DSH 工作区（workspace.list），组下挂其会话；
/// - 会话 = DSH 会话（session.list），点击进入 DSH agent 聊天；
/// - 红绿灯「添加项目」→ 添加 DSH 工作区（workspace.create，选手机文件夹）；
/// - 左滑：工作区（重命名/删除）、会话（重命名/归档）；
/// - 标题「DS Harness」点击刷新；右上角设置 = DS Harness 中心。
class DshWorkspacesTab extends StatefulWidget {
  final ShiyiState shiyi;
  const DshWorkspacesTab({super.key, required this.shiyi});

  @override
  State<DshWorkspacesTab> createState() => _DshWorkspacesTabState();
}

class _DshWorkspacesTabState extends State<DshWorkspacesTab> {
  List<DshWorkspace> _workspaces = [];
  List<DshSessionSummary> _sessions = [];
  List<String> _archivedSessionIds = [];
  bool _loading = true;
  String? _error;
  bool _busy = false;
  bool _hasCache = false;

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  String _query = '';
  List<DshSessionSummary>? _searchHits;
  bool _searching = false;
  int _pollTick = 0;

  /// 已展开的分组：工作区 id；默认展开默认工作区。
  final Set<String> _expandedGroups = <String>{};

  /// 上次持久化的展开列表；null 表示还没有写过偏好（首次启动）。
  List<String>? _savedExpanded;
  bool _expandedRestored = false;

  /// 当前展开的左滑卡片 key；点空白或操作其他卡片时收回。
  final ValueNotifier<String?> _openSwipeKey = ValueNotifier(null);
  Rect? _openSwipeRect;

  DshApiClient get _api => DshApiClient.instance;

  /// 默认工作区：链接软件默认 agent 目录（FileWorkspace.defaultWorkspacePath）。
  /// 优先按路径匹配，兜底第一个工作区。
  String? get _defaultWorkspaceId {
    if (_workspaces.isEmpty) return null;
    for (final w in _workspaces) {
      if (w.path == FileWorkspace.defaultWorkspacePath) {
        return w.workspaceId;
      }
    }
    return _workspaces.first.workspaceId;
  }

  String _displayName(DshWorkspace w) => dshWorkspaceDisplayName(
    w.title,
    w.path,
    FileWorkspace.defaultWorkspacePath,
  );

  bool _isDefaultWorkspace(DshWorkspace w) =>
      dshIsDefaultWorkspacePath(w.path, FileWorkspace.defaultWorkspacePath);

  @override
  void initState() {
    super.initState();
    _restoreExpanded();
    // 缓存先落位再刷新：有缓存时 _load 不显示加载页，列表直接可见。
    unawaited(_loadCache().then((_) => _load()));
    DshService.instance.status.addListener(_onDshStatus);
    // 思考中 3s 刷一次，让红绿灯跟着转；平时 30s。
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      _pollTick++;
      final running = _sessions.any((s) => s.running);
      if (running || _pollTick % 10 == 0) _loadSessions(silent: true);
    });
  }

  Future<void> _restoreExpanded() async {
    final saved = await dshLoadExpandedWorkspaceIds();
    if (!mounted) return;
    setState(() {
      _savedExpanded = saved;
      _expandedRestored = true;
    });
  }

  /// 先把上次列表显示出来，_load() 再静默刷新（没有缓存才显示加载页）。
  Future<void> _loadCache() async {
    final raw = await dshReadWorkspaceListCache();
    if (!mounted || raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final workspaces = ((data['workspaces'] as List?) ?? const [])
          .map((e) => DshWorkspace.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      final sessions = ((data['sessions'] as List?) ?? const [])
          .map(
            (e) =>
                DshSessionSummary.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList();
      final archived = ((data['archivedSessionIds'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      if (!mounted) return;
      setState(() {
        _workspaces = workspaces;
        _sessions = sessions;
        _archivedSessionIds = archived;
        _loading = false;
        _hasCache = true;
        _error = null;
        _applyExpandedPrefs();
      });
    } catch (_) {
      // 缓存损坏直接忽略，走正常加载。
    }
  }

  Timer? _refreshTimer;
  Timer? _retryTimer;

  void _onDshStatus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DshService.instance.status.removeListener(_onDshStatus);
    _refreshTimer?.cancel();
    _retryTimer?.cancel();
    _searchDebounce?.cancel();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    _openSwipeKey.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final hasCache =
        _hasCache || _workspaces.isNotEmpty || _sessions.isNotEmpty;
    setState(() {
      _loading = !hasCache;
      _error = null;
    });
    // 先诊断服务：未安装提示未安装，未启动提示未启动，就绪再拉列表。
    final reason = await DshService.instance.unavailableReason();
    if (reason != null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 有缓存时保留列表，服务未就绪只后台轮询，不拿错误页盖住主页。
        _error = hasCache ? null : reason;
      });
      _scheduleServiceRetry();
      return;
    }
    _stopServiceRetry();
    try {
      var r = await DshService.instance.withRecover(
        _api.listWorkspaces,
        recover: false,
      );
      var list = await DshService.instance.withRecover(
        _api.listSessions,
        recover: false,
      );
      if (r.items.isEmpty && mounted) {
        // 没有工作区时自动创建：链接软件默认 agent 目录。
        try {
          await DshService.instance.withRecover(
            () => _api.createWorkspace(FileWorkspace.defaultWorkspacePath),
            recover: false,
          );
          r = await _api.listWorkspaces();
          list = await _api.listSessions();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _workspaces = r.items;
        _archivedSessionIds = r.archivedSessionIds;
        _sessions = list;
        _loading = false;
        _hasCache = true;
        _applyExpandedPrefs();
      });
      unawaited(
        dshWriteWorkspaceListCache(
          workspaces: _workspaces,
          sessions: _sessions,
          archivedSessionIds: _archivedSessionIds,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final hint = await DshService.instance.unavailableReason();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = hasCache ? null : (hint ?? '$e');
      });
      if (hint != null || hasCache) _scheduleServiceRetry();
    }
  }

  /// 服务未就绪时每 3 秒自动重查，起来后重新加载列表。
  void _scheduleServiceRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      final reason = await DshService.instance.unavailableReason();
      if (!mounted) return;
      if (reason == null) {
        _retryTimer?.cancel();
        _retryTimer = null;
        await _load();
      } else {
        // 有缓存时保留列表，只让顶部「后台启动中」提示服务状态；
        // 没有缓存才显示错误页。
        setState(() {
          if (!_hasCache && _workspaces.isEmpty && _sessions.isEmpty) {
            _error = reason;
          }
        });
      }
    });
  }

  void _stopServiceRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _applyExpandedPrefs() {
    if (!_expandedRestored) return;
    final saved = _savedExpanded;
    if (saved == null) {
      final def = _defaultWorkspaceId;
      if (def != null) _expandedGroups.add(def);
      return;
    }
    final known = _workspaces.map((w) => w.workspaceId).toSet();
    _expandedGroups
      ..clear()
      ..addAll(saved.where(known.contains));
  }

  Future<void> _saveExpanded() => dshSaveExpandedWorkspaceIds(_expandedGroups);

  Future<void> _loadSessions({bool silent = false}) async {
    try {
      final list = await _api.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _hasCache = true;
      });
      unawaited(
        dshWriteWorkspaceListCache(
          workspaces: _workspaces,
          sessions: _sessions,
          archivedSessionIds: _archivedSessionIds,
        ),
      );
    } catch (_) {
      if (!silent &&
          mounted &&
          !_hasCache &&
          _workspaces.isEmpty &&
          _sessions.isEmpty) {
        setState(() => _error = '会话列表刷新失败');
      }
    }
  }

  // ── 搜索（本地过滤标题/路径） ───────────────────────────────────────

  void _dismissSearch() {
    _searchFocus.unfocus();
  }

  void _resetSearch() {
    _dismissSearch();
    if (_query.isEmpty && _searchCtrl.text.isEmpty) return;
    _searchCtrl.clear();
    _searchDebounce?.cancel();
    setState(() {
      _query = '';
      _searchHits = null;
      _searching = false;
    });
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final q = v.trim();
      setState(() {
        _query = q;
        _searching = q.isNotEmpty;
        if (q.isEmpty) _searchHits = null;
      });
      if (q.isNotEmpty) unawaited(_runSearch(q));
    });
  }

  Future<void> _runSearch(String q) async {
    try {
      final hits = await _api.searchSessions(q);
      if (!mounted || _query != q) return;
      setState(() {
        _searchHits = hits;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || _query != q) return;
      setState(() {
        _searchHits = null;
        _searching = false;
      });
    }
  }

  bool _matchesQuery(DshSessionSummary s) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return (s.title ?? '').toLowerCase().contains(q);
  }

  bool _workspaceMatchesQuery(DshWorkspace w) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return _displayName(w).toLowerCase().contains(q) ||
        w.title.toLowerCase().contains(q) ||
        w.path.toLowerCase().contains(q);
  }

  // ── 工作区操作（红绿灯 = 添加工作区 = workspace.create） ───────────

  static String _folderName(String dir) {
    var t = dir.replaceAll(r'\\', '/');
    if (t.endsWith('/')) t = t.substring(0, t.length - 1);
    final i = t.lastIndexOf('/');
    return i >= 0 ? t.substring(i + 1) : t;
  }

  Future<void> _createWorkspace() async {
    final defPath = FileWorkspace.defaultWorkspacePath;
    final nameCtrl = TextEditingController(text: '默认');
    var folder = defPath;
    final path = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final isDef = dshIsDefaultWorkspacePath(folder, defPath);
          return CupertinoAlertDialog(
            title: const Text('添加工作区'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CupertinoTextField(
                  controller: nameCtrl,
                  autofocus: true,
                  placeholder: '工作区名称（目录名）',
                ),
                const SizedBox(height: 12),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () async {
                    final dir = await FilePicker.platform.getDirectoryPath(
                      initialDirectory: folder,
                    );
                    if (dir == null || dir.isEmpty) return;
                    final prevName = dshIsDefaultWorkspacePath(folder, defPath)
                        ? '默认'
                        : _folderName(folder);
                    folder = dir;
                    final nextName = dshIsDefaultWorkspacePath(dir, defPath)
                        ? '默认'
                        : _folderName(dir);
                    final cur = nameCtrl.text.trim();
                    if (cur.isEmpty || cur == prevName) {
                      nameCtrl.text = nextName;
                    }
                    if (ctx.mounted) setLocal(() {});
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
                          color: _iosBlue,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isDef ? '默认' : _folderName(folder),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                              Text(
                                folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: CupertinoColors.secondaryLabel,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(ctx, folder),
                child: const Text('创建'),
              ),
            ],
          );
        },
      ),
    );
    if (path == null || path.isEmpty || !mounted) return;
    if (dshIsDefaultWorkspacePath(path, defPath)) {
      for (final w in _workspaces) {
        if (_isDefaultWorkspace(w)) {
          setState(() => _expandedGroups.add(w.workspaceId));
          unawaited(_saveExpanded());
          _toast('默认工作区已存在');
          return;
        }
      }
    }
    setState(() => _busy = true);
    try {
      final w = await _api.createWorkspace(path);
      if (!mounted) return;
      setState(() => _expandedGroups.add(w.workspaceId));
      unawaited(_saveExpanded());
      _toast('已添加工作区「${_displayName(w)}」');
      _load();
    } catch (e) {
      _toast('添加工作区失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameWorkspace(DshWorkspace w) async {
    final ctrl = TextEditingController(text: _displayName(w));
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
      if (mounted) _load();
    } catch (e) {
      _toast('重命名失败：$e');
    }
  }

  Future<void> _deleteWorkspace(DshWorkspace w) async {
    if (_isDefaultWorkspace(w)) {
      _toast('默认工作区不能删除');
      return;
    }
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除工作区'),
        content: Text('确定删除「${_displayName(w)}」吗？\n（不会删除目录文件）'),
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
      if (mounted) _load();
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  // ── 会话操作（左滑 / 新建） ────────────────────────────────────────

  Future<void> _renameSession(DshSessionSummary s) async {
    final ctrl = TextEditingController(text: s.title ?? '');
    final title = await showIosFadeDialog<String>(
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
    if (title == null || title.isEmpty) return;
    try {
      await _api.renameSession(s.sessionId, title);
      if (mounted) _loadSessions(silent: true);
    } catch (e) {
      _toast('重命名失败：$e');
    }
  }

  Future<void> _archiveSession(DshSessionSummary s) async {
    try {
      final archived = await _api.archiveSession(s.sessionId);
      if (!mounted) return;
      setState(() {
        _archivedSessionIds = {
          ..._archivedSessionIds,
          ...archived,
          s.sessionId,
        }.toList();
        _sessions = dshActiveSessions(_sessions, _archivedSessionIds);
      });
      _load();
    } catch (e) {
      _toast('归档失败：$e');
    }
  }

  Future<void> _copySessionId(DshSessionSummary s) async {
    await Clipboard.setData(ClipboardData(text: s.sessionId));
    _toast('已复制会话 ID');
  }

  Future<void> _showWorkspaceFolder(DshWorkspace w) async {
    final action = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: CupertinoActionSheet(
          title: Text(
            '「${_displayName(w)}」工作目录',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          message: Text(w.path, maxLines: 3, overflow: TextOverflow.ellipsis),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'open'),
              child: const Text('打开文件夹'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ),
      ),
    );
    if (action != 'open' || !mounted) return;
    try {
      await _api.openPath(w.path);
    } catch (e) {
      _toast('无法打开：$e');
    }
  }

  Future<void> _moveSession(DshSessionSummary s) async {
    if (_workspaces.isEmpty) {
      _toast('还没有工作区');
      return;
    }
    final chosen = await showIosFadeModalPopup<DshWorkspace>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: CupertinoActionSheet(
          title: Text(
            '移动「${s.title == null || s.title!.isEmpty ? '未命名会话' : s.title!}」到工作区',
          ),
          actions: [
            for (final w in _workspaces)
              CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(ctx, w),
                child: Text(_displayName(w)),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    try {
      await _api.insertSessionBefore(chosen.workspaceId, s.sessionId);
      if (mounted) {
        setState(() => _expandedGroups.add(chosen.workspaceId));
        unawaited(_saveExpanded());
        _load();
      }
    } catch (e) {
      _toast('移动失败：$e');
    }
  }

  /// 在工作区里新建会话（左滑工作区 → 新建会话，拾忆项目同款交互）。
  /// 创建后自动挂到该工作区并进入聊天；空会话不再自动归档，由用户左滑手动归档。
  Future<void> _newSessionInWorkspace(DshWorkspace w) async {
    _resetSearch();
    setState(() => _expandedGroups.add(w.workspaceId));
    unawaited(_saveExpanded());
    try {
      final id = await _api.createSession(cwd: w.path);
      if (!mounted || id.isEmpty) return;
      try {
        await DshModelSync.applyToSession(_api, id, widget.shiyi.settings);
      } catch (_) {}
      try {
        await DshChatCache.writeContextLimit(
          id,
          sanitizeLoadedContextLimit(widget.shiyi.settings.contextLimit),
        );
      } catch (_) {}
      try {
        await _api.insertSessionBefore(w.workspaceId, id);
      } catch (e) {
        debugPrint('insertSessionBefore failed: $e');
      }
      await _openChat(id, '新会话');
    } catch (e) {
      if (!mounted) return;
      _toast('新建 DeepSeek Harness 会话失败：$e');
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
    if (mounted) await _loadSessions(silent: true);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _timeLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.month}月${d.day}日';
  }

  void _onOpenSwipeRectChanged(Rect? rect) {
    if (!mounted) return;
    setState(() => _openSwipeRect = rect);
  }

  // ── 构建 ────────────────────────────────────────────────────────────

  bool get _lightsBusy {
    final st = DshService.instance.status.value;
    return _busy ||
        _sessions.any((s) => s.running) ||
        st == DshStatus.installing ||
        st == DshStatus.updating ||
        st == DshStatus.starting ||
        st == DshStatus.stopping ||
        st == DshStatus.uninstalling;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Scaffold(
          backgroundColor: iosGroupedBackground(context),
          appBar: AppBar(
            leadingWidth: 72,
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Platform.isWindows
                  ? MacActionButton(
                      icon: CupertinoIcons.plus,
                      tooltip: '添加工作区',
                      onTap: _busy ? null : _createWorkspace,
                    )
                  : TrafficLightsButton(
                      busy: _lightsBusy,
                      tooltip: '添加工作区',
                      onTap: _busy ? null : _createWorkspace,
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
              onTap: _load,
              child: const Text(
                'DS Harness',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FrostedSettingsButton(
                  onPressed: () => Navigator.push(
                    context,
                    MacPageRoute(
                      builder: (_) => DshCenterScreen(shiyi: widget.shiyi),
                    ),
                  ),
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
              if (_hasCache &&
                  DshService.instance.status.value == DshStatus.starting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      const CupertinoActivityIndicator(radius: 7),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'DSH 后台启动中，完成后自动刷新',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
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
    );
  }

  Widget _centeredList(Widget list) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: list,
    ),
  );

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
    if (_workspaces.isEmpty && _sessions.isEmpty) {
      return _EmptyState(onCreate: _createWorkspace);
    }
    if (_query.isNotEmpty) {
      if (_searching) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_searchHits != null) {
        final hits = dshActiveSessions(_searchHits!, _archivedSessionIds);
        if (hits.isEmpty) {
          return Center(
            child: Text(
              '未找到与「$_query」相关的会话',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }
        return _centeredList(
          ListView(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            children: [
              for (final s in hits)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _sessionTile(s),
                ),
            ],
          ),
        );
      }
    }
    final byWorkspace = <String, List<DshSessionSummary>>{};
    for (final w in _workspaces) {
      byWorkspace[w.workspaceId] = [];
    }
    final defId = _defaultWorkspaceId;
    for (final s in dshActiveSessions(_sessions, _archivedSessionIds)) {
      final ids = dshWorkspaceIdsForSession(
        sessionId: s.sessionId,
        cwd: s.cwd,
        workspaces: _workspaces,
        defaultWorkspaceId: defId,
      );
      for (final id in ids) {
        byWorkspace[id]?.add(s);
      }
    }
    final visibleWs = _workspaces.where(_workspaceMatchesQuery).toList();
    final searchMode = _query.isNotEmpty;

    return _centeredList(
      ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        children: [
          for (final w in visibleWs)
            _workspaceGroup(
              w,
              byWorkspace[w.workspaceId] ?? const [],
              searchMode,
            ),
        ],
      ),
    );
  }

  Widget _workspaceGroup(
    DshWorkspace w,
    List<DshSessionSummary> sessions,
    bool searchMode,
  ) {
    final expanded = searchMode || _expandedGroups.contains(w.workspaceId);
    final visibleSessions = sessions.where(_matchesQuery).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _SwipeActions(
            key: ValueKey('ws_${w.workspaceId}'),
            openNotifier: _openSwipeKey,
            onOpenRectChanged: _onOpenSwipeRectChanged,
            swipeKey: 'ws_${w.workspaceId}',
            actionWidth: _isDefaultWorkspace(w) ? 176 : 232,
            actions: [
              _CircularSwipeAction(
                icon: CupertinoIcons.plus,
                label: '新建会话',
                backgroundColor: _iosBlue,
                foregroundColor: Colors.white,
                onTap: () {
                  _openSwipeKey.value = null;
                  _newSessionInWorkspace(w);
                },
              ),
              _CircularSwipeAction(
                icon: CupertinoIcons.folder_open,
                label: '工作区文件夹',
                backgroundColor: _iosGray,
                foregroundColor: Colors.white,
                onTap: () {
                  _openSwipeKey.value = null;
                  _showWorkspaceFolder(w);
                },
              ),
              _CircularSwipeAction(
                icon: CupertinoIcons.pencil,
                label: '重命名',
                backgroundColor: _iosGray,
                foregroundColor: Colors.white,
                onTap: () {
                  _openSwipeKey.value = null;
                  _renameWorkspace(w);
                },
              ),
              if (!_isDefaultWorkspace(w))
                _CircularSwipeAction(
                  icon: CupertinoIcons.trash,
                  label: '删除',
                  backgroundColor: _iosRed,
                  foregroundColor: Colors.white,
                  onTap: () {
                    _openSwipeKey.value = null;
                    _deleteWorkspace(w);
                  },
                ),
            ],
            child: _WorkspaceHeader(
              name: _displayName(w),
              count: sessions.length,
              expanded: expanded,
              onTap: () => _toggleGroup(w.workspaceId),
            ),
          ),
        ),
        _StaggeredWorkspaceSessions(
          expanded: expanded,
          children: [
            if (visibleSessions.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '暂无会话',
                    style: TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.secondaryLabel,
                    ),
                  ),
                ),
              )
            else
              for (final s in visibleSessions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _sessionTile(s),
                ),
          ],
        ),
      ],
    );
  }

  Widget _sessionTile(DshSessionSummary s) {
    final title = s.title == null || s.title!.isEmpty ? '未命名会话' : s.title!;
    final subtitle =
        '${_timeLabel(s.updatedAt)}'
        '${s.turnCount > 0 ? ' · ${s.turnCount} 轮' : ''}'
        '${s.blank ? ' · 空' : ''}';
    return _SwipeActions(
      key: ValueKey(s.sessionId),
      openNotifier: _openSwipeKey,
      onOpenRectChanged: _onOpenSwipeRectChanged,
      swipeKey: s.sessionId,
      actionWidth: 232,
      actions: [
        _CircularSwipeAction(
          icon: CupertinoIcons.pencil,
          label: '重命名',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () {
            _openSwipeKey.value = null;
            _renameSession(s);
          },
        ),
        _CircularSwipeAction(
          icon: CupertinoIcons.folder_open,
          label: '工作区',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () {
            _openSwipeKey.value = null;
            _moveSession(s);
          },
        ),
        _CircularSwipeAction(
          icon: CupertinoIcons.archivebox,
          label: '归档',
          backgroundColor: _iosRed,
          foregroundColor: Colors.white,
          onTap: () {
            _openSwipeKey.value = null;
            _archiveSession(s);
          },
        ),
        _CircularSwipeAction(
          icon: CupertinoIcons.doc_on_doc,
          label: '复制 ID',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () {
            _openSwipeKey.value = null;
            _copySessionId(s);
          },
        ),
      ],
      onTap: () {
        _dismissSearch();
        unawaited(_openChat(s.sessionId, s.title, summary: s));
      },
      child: _DshSessionCard(
        title: title,
        subtitle: subtitle,
        running: s.running,
      ),
    );
  }

  void _toggleGroup(String id) {
    setState(() {
      if (!_expandedGroups.add(id)) _expandedGroups.remove(id);
    });
    unawaited(_saveExpanded());
  }

  void _closeSwipe() {
    _openSwipeKey.value = null;
    if (mounted) setState(() => _openSwipeRect = null);
  }
}

// ── 空态（与拾忆会话页同款） ─────────────────────────────────────────

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
          const WelcomeAvatar(size: 240),
          const SizedBox(height: 16),
          Text('新建一个工作区开始', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '工作区分类管理会话 · 每个工作区对应一个文件夹',
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
                Text('添加工作区', style: TextStyle(fontSize: 15)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  final String name;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  const _WorkspaceHeader({
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

class _DshSessionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool running;
  const _DshSessionCard({
    required this.title,
    required this.subtitle,
    required this.running,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = running
        ? const Row(
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
              SizedBox(width: 6),
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
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 12.5,
            ),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const WelcomeAvatar(size: 36, asset: 'assets/avatar.png'),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 15.5,
                  ),
                ),
                const SizedBox(height: 3),
                sub,
              ],
            ),
          ),
          if (running) ...[
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: _iosGreen,
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
  }
}

class _StaggeredWorkspaceSessions extends StatefulWidget {
  final bool expanded;
  final List<Widget> children;
  const _StaggeredWorkspaceSessions({
    required this.expanded,
    required this.children,
  });

  @override
  State<_StaggeredWorkspaceSessions> createState() =>
      _StaggeredWorkspaceSessionsState();
}

class _StaggeredWorkspaceSessionsState
    extends State<_StaggeredWorkspaceSessions>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..value = widget.expanded ? 1 : 0;

  @override
  void didUpdateWidget(covariant _StaggeredWorkspaceSessions oldWidget) {
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
    final start = total == 0 ? 0.0 : index / total;
    final end = total == 0 ? 1.0 : (index + 1) / total;
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

// ── 左滑操作（与拾忆会话页同款：悬停/滑动/右键菜单） ──────────────────

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
    return MouseRegion(
      onEnter: desktop ? (_) => _setHovered(true) : null,
      onExit: desktop ? (_) => _setHovered(false) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: displayOffset < 0 ? 1 : 0,
                duration: const Duration(milliseconds: 100),
                child: GestureDetector(
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
