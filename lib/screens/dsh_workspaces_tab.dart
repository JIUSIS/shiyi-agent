import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_state.dart';
import '../core/home_list_order.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../services/dsh_api.dart';
import '../services/dsh_chat_cache.dart';
import '../services/dsh_endpoint.dart';
import '../services/dsh_service.dart';
import '../services/file_workspace.dart';
import '../widgets/home_drag.dart';
import '../widgets/home_group_header.dart';
import '../widgets/dsh_directory_picker.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/staggered_sessions.dart';
import '../widgets/swipe_actions.dart';
import '../widgets/traffic_lights_button.dart';
import '../widgets/welcome_avatar.dart';
import 'dsh_center_screen.dart';
import 'dsh_chat_screen.dart';
import 'dsh_new_session.dart';

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

/// DSH 入账要求会话 header.cwd 与工作区路径一致，跨目录不能 insertSessionBefore。
bool dshSessionCwdMatchesWorkspace({
  required String? sessionCwd,
  required String workspacePath,
}) {
  if (sessionCwd == null || sessionCwd.trim().isEmpty) return false;
  return dshNormalizedPath(sessionCwd) == dshNormalizedPath(workspacePath);
}

/// 跨工作区移动时，cwd 对不上就必须改 zstd/jsonl 头并搬目录。
/// 已经一致则返回 null，这时才允许走 attach / insert 兜底。
String? dshSessionMoveCwd({
  required String? sessionCwd,
  required String workspacePath,
}) {
  if (dshSessionCwdMatchesWorkspace(
    sessionCwd: sessionCwd,
    workspacePath: workspacePath,
  )) {
    return null;
  }
  return workspacePath;
}

/// 工作区展开状态：首次按偏好（或默认工作区）；之后只允许当前集合自己变化。
Set<String> dshRestoreExpandedWorkspaceIds({
  required List<String>? saved,
  required Iterable<String> knownIds,
  required String? defaultWorkspaceId,
}) {
  final known = knownIds.toSet();
  if (saved == null) {
    if (defaultWorkspaceId != null && known.contains(defaultWorkspaceId)) {
      return {defaultWorkspaceId};
    }
    return <String>{};
  }
  return {
    for (final id in saved)
      if (known.contains(id)) id,
  };
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

/// 先看工作区 sessionIds 且 cwd 对得上的入账关系；对不上则按会话 cwd 匹配工作区路径。
List<String> dshWorkspaceIdsForSession({
  required String sessionId,
  required String? cwd,
  required List<DshWorkspace> workspaces,
  required String? defaultWorkspaceId,
}) {
  final owned = <String>[
    for (final w in workspaces)
      if (w.sessionIds.contains(sessionId) &&
          dshSessionCwdMatchesWorkspace(sessionCwd: cwd, workspacePath: w.path))
        w.workspaceId,
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

/// 工作区卡片按 [sessionIds] 排；cwd 兜底进来的会话接到末尾。
List<DshSessionSummary> dshOrderedWorkspaceSessions({
  required List<DshSessionSummary> assigned,
  required List<String> sessionIds,
}) {
  return orderByIds(assigned, ids: sessionIds, idOf: (s) => s.sessionId);
}

/// 跨工作区松手后立刻改本地名单。只改 sessionIds 不够：cwd 还在源目录时
/// [dshWorkspaceIdsForSession] 会按路径把会话塞回原工作区，BCD 会被撑开。
List<String> dshMovedWorkspaceSessionIds({
  required List<String> current,
  required String workspaceId,
  required String sessionId,
  required String toWorkspaceId,
  int toIndex = 0,
}) {
  final ids = [
    for (final id in current)
      if (id != sessionId) id,
  ];
  if (workspaceId != toWorkspaceId) return ids;
  final insertAt = toIndex < 0
      ? 0
      : (toIndex > ids.length ? ids.length : toIndex);
  return [...ids.sublist(0, insertAt), sessionId, ...ids.sublist(insertAt)];
}

({List<DshWorkspace> workspaces, List<DshSessionSummary> sessions})
dshOptimisticMoveSession({
  required List<DshWorkspace> workspaces,
  required List<DshSessionSummary> sessions,
  required String sessionId,
  required String toWorkspaceId,
  int toIndex = 0,
}) {
  DshWorkspace? target;
  for (final w in workspaces) {
    if (w.workspaceId == toWorkspaceId) {
      target = w;
      break;
    }
  }
  final nextWorkspaces = [
    for (final w in workspaces)
      w.copyWith(
        sessionIds: dshMovedWorkspaceSessionIds(
          current: w.sessionIds,
          workspaceId: w.workspaceId,
          sessionId: sessionId,
          toWorkspaceId: toWorkspaceId,
          toIndex: toIndex,
        ),
      ),
  ];
  if (target == null) {
    return (workspaces: nextWorkspaces, sessions: sessions);
  }
  return (
    workspaces: nextWorkspaces,
    sessions: [
      for (final s in sessions)
        if (s.sessionId == sessionId) s.withCwd(target.path) else s,
    ],
  );
}

/// DS Harness 引擎的主页 tab 0「工作区」：
/// 外观完全复用拾忆会话页（红绿灯/大标题/搜索框/项目分组/卡片左滑），
/// 接口数据为 DeepSeek Harness：
/// - 项目分组 = DSH 工作区（workspace.list），组下挂其会话；
/// - 会话 = DSH 会话（session.list），点击进入 DSH agent 聊天；
/// - 红绿灯「添加项目」→ 添加 DSH 工作区（workspace.create）；
///   本机使用手机目录，局域网/公网使用 DSH 主机目录和盘符；
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
  bool _remoteLoaded = false;

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  String _query = '';
  List<DshSessionSummary>? _searchHits;
  bool _searching = false;

  /// 已展开的分组：工作区 id；默认展开默认工作区。
  final Set<String> _expandedGroups = <String>{};

  /// 上次持久化的展开列表；null 表示还没有写过偏好（首次启动）。
  List<String>? _savedExpanded;
  bool _expandedRestored = false;
  bool _expandedApplied = false;

  /// 当前展开的左滑卡片 key；点空白或操作其他卡片时收回。
  final ValueNotifier<String?> _openSwipeKey = ValueNotifier(null);
  Rect? _openSwipeRect;

  final HomeDragHoverController _hover = HomeDragHoverController();
  Timer? _hoverTimer;
  String? _hoveringWorkspaceId;
  String? _dropReadyWorkspaceId;
  String? _draggingSessionId;
  String? _draggingWorkspaceId;
  String? _sessionPreviewWorkspaceId;
  int? _sessionPreviewFrom;
  int? _sessionPreviewTo;
  int? _workspacePreviewFrom;
  int? _workspacePreviewTo;
  List<String>? _workspaceOrderOverride;
  bool _dropCommitted = false;
  bool _flying = false;
  bool _snapShift = false;
  bool _crossDropCommitting = false;
  String? _commitMoveSessionId;
  String? _commitMoveWorkspaceId;
  int _commitMoveIndex = 0;
  Offset? _flyStartTopLeft;
  OverlayEntry? _flyEntry;
  final HomeDragOverlay _dragOverlay = HomeDragOverlay();
  String? _sessionOrderOverrideWorkspace;
  List<String>? _sessionOrderOverride;
  final Map<String, GlobalKey> _sessionCardKeys = {};
  final Map<String, GlobalKey> _workspaceBlockKeys = {};
  final Map<String, GlobalKey> _workspaceHeaderKeys = {};
  final Map<String, GlobalKey> _insertGapKeys = {};
  final List<double> _sessionHeights = [];
  final List<double> _sessionCenters = [];
  final List<double> _crossHeights = [];
  final List<double> _crossCenters = [];
  String? _crossGeometryId;
  int _crossInsertIndex = 0;
  Offset? _lastDragGlobal;
  final List<double> _workspaceHeights = [];
  final List<double> _workspaceCenters = [];

  DshApiClient get _api => DshService.instance.api;

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
    if (_usesLivePageData) {
      // 局域网 / 公网只显示目标 DSH 的实时列表，不读取手机旧快照。
      unawaited(_load());
    } else {
      // 本机模式保留缓存先落位，再静默刷新。
      unawaited(_loadCache().then((_) => _load()));
    }
    DshService.instance.status.addListener(_onDshStatus);
    // 远端列表可能由其他设备修改，空闲时也要同步工作区与会话。
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      unawaited(_load(quiet: true));
    });
  }

  bool get _usesLivePageData =>
      DshEndpoint.requiresLivePageData(widget.shiyi.settings);

  Future<void> _restoreExpanded() async {
    final saved = await dshLoadExpandedWorkspaceIds();
    if (!mounted) return;
    setState(() {
      _savedExpanded = saved;
      _expandedRestored = true;
      _applyExpandedPrefs();
    });
  }

  /// 先把上次列表显示出来，_load() 再静默刷新（没有缓存才显示加载页）。
  Future<void> _loadCache() async {
    if (_usesLivePageData) return;
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
  Future<void>? _refreshInFlight;
  bool _refreshQueued = false;
  bool _refreshQueuedLoud = false;

  void _onDshStatus() {
    if (!mounted) return;
    setState(() {});
    if (DshService.instance.status.value == DshStatus.running) {
      unawaited(_load(quiet: true));
    }
  }

  @override
  void dispose() {
    DshService.instance.status.removeListener(_onDshStatus);
    _refreshTimer?.cancel();
    _retryTimer?.cancel();
    _searchDebounce?.cancel();
    _hoverTimer?.cancel();
    _dragOverlay.remove();
    _removeFlyEntry();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    _openSwipeKey.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) {
    if (!mounted) return Future<void>.value();
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      _refreshQueued = true;
      if (!quiet) _refreshQueuedLoud = true;
      return inFlight;
    }

    final refresh = _runLoad(quiet: quiet);
    _refreshInFlight = refresh;
    unawaited(
      refresh.whenComplete(() {
        if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
        if (!mounted || !_refreshQueued) {
          _refreshQueued = false;
          _refreshQueuedLoud = false;
          return;
        }
        final queuedQuiet = !_refreshQueuedLoud;
        _refreshQueued = false;
        _refreshQueuedLoud = false;
        unawaited(_load(quiet: queuedQuiet));
      }),
    );
    return refresh;
  }

  Future<void> _runLoad({required bool quiet}) async {
    final hasCache =
        !_usesLivePageData &&
        (_hasCache || _workspaces.isNotEmpty || _sessions.isNotEmpty);
    final hasCurrentData = hasCache || _remoteLoaded;
    // 跨组提交中不要先 setState：本地名单还是旧归属时源槽会被撑开。
    if (!quiet || !hasCurrentData) {
      setState(() {
        _loading = !hasCurrentData;
        _error = null;
      });
    }
    // 先诊断服务：未安装提示未安装，未启动提示未启动，就绪再拉列表。
    final reason = await DshService.instance.unavailableReason();
    if (reason != null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 有缓存时保留列表，但必须明确标出这是离线快照，不能伪装成已连接。
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
      if (r.items.isEmpty &&
          mounted &&
          DshService.instance.managesLocalProcess) {
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
        _hasCache = !_usesLivePageData;
        _remoteLoaded = _usesLivePageData;
        _error = null;
        _applyExpandedPrefs();
        _reapplyPendingMove();
      });
      if (!_usesLivePageData) {
        unawaited(
          dshWriteWorkspaceListCache(
            workspaces: _workspaces,
            sessions: _sessions,
            archivedSessionIds: _archivedSessionIds,
          ),
        );
      }
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
        // 有缓存时保留列表并标出离线状态；没有缓存才显示错误页。
        setState(() {
          final hasCache =
              !_usesLivePageData &&
              (_hasCache || _workspaces.isNotEmpty || _sessions.isNotEmpty);
          if (hasCache) {
            _error = null;
          } else {
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
    final known = [for (final w in _workspaces) w.workspaceId];
    if (known.isEmpty) return;
    if (!_expandedApplied) {
      _expandedApplied = true;
      _expandedGroups
        ..clear()
        ..addAll(
          dshRestoreExpandedWorkspaceIds(
            saved: _savedExpanded,
            knownIds: known,
            defaultWorkspaceId: _defaultWorkspaceId,
          ),
        );
      return;
    }
    final knownSet = known.toSet();
    _expandedGroups.removeWhere((id) => !knownSet.contains(id));
  }

  Future<void> _saveExpanded() {
    _savedExpanded = _expandedGroups.toList();
    return dshSaveExpandedWorkspaceIds(_expandedGroups);
  }

  Future<void> _loadSessions({bool silent = false}) => _load(quiet: silent);

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
    final hostDirectory = DshEndpoint.modeOf(widget.shiyi.settings) != 'local';
    final nameCtrl = TextEditingController(text: '默认');
    var folder = hostDirectory ? '' : defPath;
    if (hostDirectory) {
      try {
        folder = await dshHostDefaultDirectory(_api);
      } catch (e) {
        if (!mounted) {
          nameCtrl.dispose();
          return;
        }
        _toast('无法读取远程电脑目录：$e');
        nameCtrl.dispose();
        return;
      }
    }
    if (!mounted) {
      nameCtrl.dispose();
      return;
    }
    if (hostDirectory && folder.trim().isEmpty) {
      nameCtrl.dispose();
      _toast('远程电脑没有返回有效工作目录');
      return;
    }
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
                    final dir = hostDirectory
                        ? await pickDshHostDirectory(
                            context,
                            api: _api,
                            initialPath: folder,
                          )
                        : await FilePicker.platform.getDirectoryPath(
                            initialDirectory: folder,
                          );
                    if (dir == null || dir.isEmpty) return;
                    final prevName =
                        !hostDirectory &&
                            dshIsDefaultWorkspacePath(folder, defPath)
                        ? '默认'
                        : _folderName(folder);
                    folder = dir;
                    final nextName =
                        !hostDirectory &&
                            dshIsDefaultWorkspacePath(dir, defPath)
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
                                !hostDirectory && isDef
                                    ? '默认'
                                    : _folderName(folder),
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
    nameCtrl.dispose();
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
    if (!mounted || w.path.trim().isEmpty) return;
    final selected = await pickDshHostDirectory(
      context,
      api: _api,
      initialPath: w.path,
    );
    final path = selected?.trim() ?? '';
    if (path.isEmpty || path == w.path.trim() || !mounted) return;

    setState(() => _busy = true);
    DshWorkspace? target;
    var created = false;
    final moved = <String>[];
    try {
      // 先创建新工作区，全部会话迁移成功后才删除旧工作区，避免远端失败时
      // 旧工作区和会话被破坏。
      for (final existing in _workspaces) {
        if (dshNormalizedPath(existing.path) == dshNormalizedPath(path)) {
          target = existing;
          break;
        }
      }
      created = target == null;
      target ??= await _api.createWorkspace(path);
      if (created &&
          w.title.trim().isNotEmpty &&
          target.title.trim() != w.title.trim()) {
        try {
          await _api.renameWorkspace(target.workspaceId, w.title.trim());
        } catch (_) {}
      }
      String? beforeSessionId;
      for (final sessionId in w.sessionIds.reversed) {
        if (DshEndpoint.isLocal(widget.shiyi.settings)) {
          final result = await _tryPluginMove(
            sessionId: sessionId,
            workspaceId: target.workspaceId,
            workspacePath: path,
          );
          if (result == null) {
            throw DshApiException(
              '工作区搬家插件未加载，请重启本机 DSH 后再试',
              code: 'plugin-missing',
            );
          }
        } else {
          await _api.updateSessionCwd(sessionId, path);
        }
        await _attachThenInsert(
          target.workspaceId,
          sessionId,
          beforeSessionId: beforeSessionId,
        );
        beforeSessionId = sessionId;
        moved.add(sessionId);
      }
      if (created) {
        final oldIndex = _workspaces.indexWhere(
          (item) => item.workspaceId == w.workspaceId,
        );
        final nextId = oldIndex >= 0 && oldIndex + 1 < _workspaces.length
            ? _workspaces[oldIndex + 1].workspaceId
            : null;
        try {
          await _api.insertWorkspaceBefore(
            target.workspaceId,
            beforeWorkspaceId: nextId,
          );
        } catch (_) {}
      }
      await _api.deleteWorkspace(w.workspaceId);
      if (!mounted) return;
      _toast('工作区文件夹已切换：$path');
      await _load();
    } catch (e) {
      // 尽量把已迁移的会话恢复到旧目录和旧工作区，避免只迁了一半。
      for (final sessionId in moved.reversed) {
        try {
          if (DshEndpoint.isLocal(widget.shiyi.settings)) {
            await _tryPluginMove(
              sessionId: sessionId,
              workspaceId: w.workspaceId,
              workspacePath: w.path,
            );
          } else {
            await _api.updateSessionCwd(sessionId, w.path);
          }
          await _attachThenInsert(w.workspaceId, sessionId);
        } catch (_) {}
      }
      if (created && target != null) {
        try {
          await _api.deleteWorkspace(target.workspaceId);
        } catch (_) {}
      }
      if (mounted) {
        _toast('切换工作区文件夹失败，原工作区已保留：$e');
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
      await _relocateSessionToWorkspace(s.sessionId, chosen.workspaceId);
      if (mounted) {
        setState(() => _expandedGroups.add(chosen.workspaceId));
        unawaited(_saveExpanded());
        await _load();
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
      final preset = await pickDshAgentPreset(context);
      if (preset == null) return;
      final id = await _api.createSession(
        workspaceId: w.workspaceId,
        agentPreset: preset.isEmpty ? null : preset,
      );
      if (!mounted || id.isEmpty) return;
      try {
        await DshChatCache.writeContextLimit(
          id,
          sanitizeLoadedContextLimit(widget.shiyi.settings.contextLimit),
        );
      } catch (_) {}
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
              Material(
                color: theme.scaffoldBackgroundColor,
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
              Expanded(child: ClipRect(child: _buildBody())),
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
    } else if (_draggingWorkspaceId != null) {
      _updateWorkspacePreviewFromGlobal(last);
    }
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
    final byWorkspace = _sessionsByWorkspace();
    final visibleWs = _workspaces.where(_workspaceMatchesQuery).toList();
    final searchMode = _query.isNotEmpty;

    final workspaces = searchMode ? visibleWs : _visibleWorkspaces(visibleWs);
    return _centeredList(
      // 下拉刷新：与长按拖拽 / 左滑无竞技场冲突（过冲通知驱动）；
      // 插在 NotificationListener 内侧保持滚动通知冒泡。
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          children: [
            for (var i = 0; i < workspaces.length; i++)
              _shiftedSlot(
                key: _keyFor(_workspaceBlockKeys, workspaces[i].workspaceId),
                dy:
                    searchMode ||
                        _workspacePreviewFrom == null ||
                        _workspacePreviewTo == null
                    ? 0
                    : homeDragTranslateY(
                        index: i,
                        from: _workspacePreviewFrom!,
                        to: _workspacePreviewTo!,
                        heights: _workspaceHeights,
                      ),
                child: _workspaceGroup(
                  workspaces[i],
                  _visibleSessionsFor(workspaces[i].workspaceId, byWorkspace),
                  searchMode,
                  workspaceIndex: i,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _workspaceGroup(
    DshWorkspace w,
    List<DshSessionSummary> sessions,
    bool searchMode, {
    required int workspaceIndex,
  }) {
    final expanded = searchMode || _expandedGroups.contains(w.workspaceId);
    final visibleSessions = sessions.where(_matchesQuery).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dragWorkspaceCard(
          workspace: w,
          workspaceIndex: workspaceIndex,
          sessionCount: sessions.length,
          expanded: expanded,
          searchMode: searchMode,
        ),
        StaggeredSessions(
          expanded: expanded,
          unclipped: kHomeDragSessionHitTestUnclipped && expanded,
          fastCollapse: _draggingWorkspaceId == w.workspaceId,
          outOfFlow: _draggingWorkspaceId == w.workspaceId,
          children: searchMode
              ? [
                  for (final s in visibleSessions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _sessionTile(s),
                    ),
                ]
              : _sessionCardsWithGap(
                  list: visibleSessions,
                  workspaceId: w.workspaceId,
                ),
        ),
        HomeDragInsertGap(
          key: _keyFor(_insertGapKeys, w.workspaceId),
          height: _insertGapHeight(w.workspaceId),
          snap: _dropCommitted,
        ),
      ],
    );
  }

  Widget _dragWorkspaceCard({
    required DshWorkspace workspace,
    required int workspaceIndex,
    required int sessionCount,
    required bool expanded,
    required bool searchMode,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HomeLongPressDrag(
        key: ValueKey('drag_ws_${workspace.workspaceId}'),
        enabled:
            !searchMode &&
            ((_draggingWorkspaceId == null && _draggingSessionId == null) ||
                _draggingWorkspaceId == workspace.workspaceId),
        onDragStart: (details) => _onWorkspaceDragStarted(
          workspace.workspaceId,
          workspaceIndex,
          details.globalPosition,
        ),
        onDragUpdate: (details) =>
            _updateWorkspacePreviewFromGlobal(details.globalPosition),
        onDragEnd: (_) => _commitWorkspaceDrag(),
        onDragCancel: _commitWorkspaceDrag,
        onDragSettled: _removeDragVisuals,
        child: SwipeActions(
          key: ValueKey('ws_${workspace.workspaceId}'),
          openNotifier: _openSwipeKey,
          onOpenRectChanged: _onOpenSwipeRectChanged,
          swipeKey: 'ws_${workspace.workspaceId}',
          disableSwipe: _draggingWorkspaceId == workspace.workspaceId,
          actionWidth: _isDefaultWorkspace(workspace) ? 176 : 232,
          actions: [
            CircularSwipeAction(
              icon: CupertinoIcons.plus,
              label: '新建会话',
              backgroundColor: _iosBlue,
              foregroundColor: Colors.white,
              onTap: () {
                _openSwipeKey.value = null;
                _newSessionInWorkspace(workspace);
              },
            ),
            CircularSwipeAction(
              icon: CupertinoIcons.folder_open,
              label: '工作区文件夹',
              backgroundColor: _iosGray,
              foregroundColor: Colors.white,
              onTap: () {
                _openSwipeKey.value = null;
                _showWorkspaceFolder(workspace);
              },
            ),
            CircularSwipeAction(
              icon: CupertinoIcons.pencil,
              label: '重命名',
              backgroundColor: _iosGray,
              foregroundColor: Colors.white,
              onTap: () {
                _openSwipeKey.value = null;
                _renameWorkspace(workspace);
              },
            ),
            if (!_isDefaultWorkspace(workspace))
              CircularSwipeAction(
                icon: CupertinoIcons.trash,
                label: '删除',
                backgroundColor: _iosRed,
                foregroundColor: Colors.white,
                onTap: () {
                  _openSwipeKey.value = null;
                  _deleteWorkspace(workspace);
                },
              ),
          ],
          child: HomeGroupHeader(
            key: _keyFor(_workspaceHeaderKeys, workspace.workspaceId),
            name: _displayName(workspace),
            count: sessionCount,
            expanded: expanded,
            dropReady: _dropReadyWorkspaceId == workspace.workspaceId,
            onTap: () => _toggleGroup(workspace.workspaceId),
          ),
        ),
      ),
    );
  }

  Widget _sessionTile(DshSessionSummary s, {bool disableSwipe = false}) {
    final title = s.title == null || s.title!.isEmpty ? '未命名会话' : s.title!;
    final subtitle =
        '${_timeLabel(s.updatedAt)}'
        '${s.turnCount > 0 ? ' · ${s.turnCount} 轮' : ''}'
        '${s.blank ? ' · 空' : ''}';
    return SwipeActions(
      key: ValueKey(s.sessionId),
      openNotifier: _openSwipeKey,
      onOpenRectChanged: _onOpenSwipeRectChanged,
      swipeKey: s.sessionId,
      disableSwipe: disableSwipe,
      actionWidth: 232,
      actions: [
        CircularSwipeAction(
          icon: CupertinoIcons.pencil,
          label: '重命名',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () {
            _openSwipeKey.value = null;
            _renameSession(s);
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.folder_open,
          label: '工作区',
          backgroundColor: _iosGray,
          foregroundColor: Colors.white,
          onTap: () {
            _openSwipeKey.value = null;
            _moveSession(s);
          },
        ),
        CircularSwipeAction(
          icon: CupertinoIcons.archivebox,
          label: '归档',
          backgroundColor: _iosRed,
          foregroundColor: Colors.white,
          onTap: () {
            _openSwipeKey.value = null;
            _archiveSession(s);
          },
        ),
        CircularSwipeAction(
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

  Widget _sessionCard(
    DshSessionSummary s, {
    bool visualOnly = false,
    bool disableSwipe = false,
    bool includeBottomGap = true,
  }) {
    if (!visualOnly) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _sessionTile(s, disableSwipe: disableSwipe),
      );
    }
    final title = s.title == null || s.title!.isEmpty ? '未命名会话' : s.title!;
    final subtitle =
        '${_timeLabel(s.updatedAt)}'
        '${s.turnCount > 0 ? ' · ${s.turnCount} 轮' : ''}'
        '${s.blank ? ' · 空' : ''}';
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: iosSectionBackground(context),
          borderRadius: BorderRadius.circular(14),
        ),
        child: _DshSessionCard(
          title: title,
          subtitle: subtitle,
          running: s.running,
        ),
      ),
    );
    return includeBottomGap
        ? Padding(padding: const EdgeInsets.only(bottom: 8), child: content)
        : content;
  }

  GlobalKey _keyFor(Map<String, GlobalKey> map, String id) {
    return map.putIfAbsent(id, GlobalKey.new);
  }

  void _expandWorkspace(String id) {
    if (_expandedGroups.contains(id)) return;
    setState(() => _expandedGroups.add(id));
    unawaited(_saveExpanded());
  }

  void _cancelHover() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    final hadHover =
        _hoveringWorkspaceId != null || _dropReadyWorkspaceId != null;
    _hoveringWorkspaceId = null;
    _hover.onLeave();
    _dropReadyWorkspaceId = null;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
    if (hadHover && mounted) setState(() {});
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

  void _prepareCrossDropCommit() {
    _crossDropCommitting = true;
    _snapShift = true;
    _hoverTimer?.cancel();
    _hoverTimer = null;
    _hoveringWorkspaceId = null;
    _hover.onLeave();
    _dropReadyWorkspaceId = null;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
  }

  void _clearDragPreview() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
    _hoveringWorkspaceId = null;
    _hover.onLeave();
    _dropReadyWorkspaceId = null;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
    _draggingSessionId = null;
    _draggingWorkspaceId = null;
    _workspacePreviewFrom = null;
    _workspacePreviewTo = null;
    _sessionPreviewWorkspaceId = null;
    _sessionPreviewFrom = null;
    _sessionPreviewTo = null;
    _dropCommitted = false;
    _flying = false;
    _crossDropCommitting = false;
    _commitMoveSessionId = null;
    _commitMoveWorkspaceId = null;
    _commitMoveIndex = 0;
    _flyStartTopLeft = null;
  }

  void _applyOptimisticMove(
    String sessionId,
    String toWorkspaceId, {
    int toIndex = 0,
  }) {
    final next = dshOptimisticMoveSession(
      workspaces: _workspaces,
      sessions: _sessions,
      sessionId: sessionId,
      toWorkspaceId: toWorkspaceId,
      toIndex: toIndex,
    );
    _workspaces = next.workspaces;
    _sessions = next.sessions;
  }

  void _reapplyPendingMove() {
    final sessionId = _commitMoveSessionId;
    final toWorkspaceId = _commitMoveWorkspaceId;
    if (sessionId == null || toWorkspaceId == null) return;
    _applyOptimisticMove(sessionId, toWorkspaceId, toIndex: _commitMoveIndex);
  }

  void _clearOrderOverride() {
    _workspaceOrderOverride = null;
    _sessionOrderOverride = null;
    _sessionOrderOverrideWorkspace = null;
  }

  List<DshWorkspace> _visibleWorkspaces(List<DshWorkspace> source) {
    final override = _workspaceOrderOverride;
    if (override == null) return source;
    return orderByIds(source, ids: override, idOf: (w) => w.workspaceId);
  }

  double get _draggedWorkspaceHeight {
    final from = _workspacePreviewFrom;
    if (from == null || from >= _workspaceHeights.length) return 56;
    return _workspaceHeights[from];
  }

  double get _draggedSessionHeight {
    final from = _sessionPreviewFrom;
    if (from == null || from >= _sessionHeights.length) return 68;
    return _sessionHeights[from];
  }

  Future<void> _onWorkspaceDragStarted(
    String workspaceId,
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
    final workspaces = _visibleWorkspaces(_workspaces);
    homeDragReadSlotGeometry(
      [for (final w in workspaces) _keyFor(_workspaceBlockKeys, w.workspaceId)],
      _workspaceHeights,
      _workspaceCenters,
    );
    DshWorkspace? workspace;
    for (final w in workspaces) {
      if (w.workspaceId == workspaceId) {
        workspace = w;
        break;
      }
    }
    final count = _visibleSessionsFor(workspaceId).length;
    final headerKey = _keyFor(_workspaceHeaderKeys, workspaceId);
    final headerSlot = homeDragOriginSlot(headerKey);
    final wasExpanded = _expandedGroups.contains(workspaceId);
    _showDragOverlay(
      originKey: headerKey,
      pointerGlobal: pointerGlobal,
      card: homeDragFeedbackClone(
        context,
        width: headerSlot.$2.width,
        height: headerSlot.$2.height,
        child: KeyedSubtree(
          key: ValueKey('lift_workspace_$workspaceId'),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: iosSectionBackground(context),
              borderRadius: BorderRadius.circular(14),
            ),
            child: HomeGroupHeader(
              name: workspace == null ? '' : _displayName(workspace),
              count: count,
              expanded: false,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    setState(() {
      if (wasExpanded) _expandedGroups.remove(workspaceId);
      _draggingSessionId = null;
      _draggingWorkspaceId = workspaceId;
      _workspacePreviewFrom = index;
      _workspacePreviewTo = index;
      _sessionPreviewWorkspaceId = null;
      _sessionPreviewFrom = null;
      _sessionPreviewTo = null;
      _workspaceOrderOverride = null;
      _sessionOrderOverride = null;
      _sessionOrderOverrideWorkspace = null;
    });
    if (wasExpanded) {
      homeDragCollapseSlot(
        heights: _workspaceHeights,
        centers: _workspaceCenters,
        index: index,
        collapsedHeight: homeDragCollapsedProjectSlotHeight(
          headerSlot.$2.height,
        ),
      );
      unawaited(_saveExpanded());
    }
  }

  void _updateWorkspacePreviewFromGlobal(Offset global) {
    if (_flying || _dropCommitted) return;
    _lastDragGlobal = global;
    _followDragOverlay(global, height: _draggedWorkspaceHeight);
    _refreshWorkspaceGeometry();
    final from = _workspacePreviewFrom;
    if (from == null || _workspaceCenters.isEmpty) return;
    final dest = homeDragIndexFromCenters(
      y: global.dy,
      centers: _workspaceCenters,
      from: from,
    );
    if (_workspacePreviewTo == dest) return;
    setState(() => _workspacePreviewTo = dest);
  }

  Future<void> _commitWorkspaceDrag() async {
    if (_dropCommitted) return;
    _dropCommitted = true;
    final from = _workspacePreviewFrom;
    final to = _workspacePreviewTo;
    _hoverTimer?.cancel();
    if (homeDragShouldFly(from: from, to: to)) {
      final destDy = homeDragSlotDestDy(
        from: from!,
        to: to!,
        heights: _workspaceHeights,
      );
      final workspaces = _visibleWorkspaces(_workspaces);
      final ids = [for (final w in workspaces) w.workspaceId];
      final changed = from != to;
      final next = changed ? moveIdToIndex(ids, ids[from], to) : ids;
      final id = ids[from];
      DshWorkspace? workspace;
      for (final w in workspaces) {
        if (w.workspaceId == id) {
          workspace = w;
          break;
        }
      }
      final count = _visibleSessionsFor(id).length;
      await _flyThen(
        destDy: destDy,
        originKey: _keyFor(_workspaceHeaderKeys, id),
        card: homeDragFeedbackClone(
          context,
          width: homeDragOriginSlot(_keyFor(_workspaceHeaderKeys, id)).$2.width,
          child: KeyedSubtree(
            key: ValueKey('fly_workspace_$id'),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: iosSectionBackground(context),
                borderRadius: BorderRadius.circular(14),
              ),
              child: HomeGroupHeader(
                name: workspace == null ? '' : _displayName(workspace),
                count: count,
                expanded: _expandedGroups.contains(id),
                onTap: () {},
              ),
            ),
          ),
        ),
        applyOverride: () {
          if (changed) _workspaceOrderOverride = next;
        },
        persist: () => changed
            ? _persistWorkspaceListOrder(ids[from], next)
            : Future.value(),
      );
      return;
    }
    if (!mounted) return;
    await _dragOverlay.land();
    setState(_clearDragPreview);
  }

  Future<void> _persistWorkspaceListOrder(
    String movedId,
    List<String> next,
  ) async {
    try {
      await _api.insertWorkspaceBefore(
        movedId,
        beforeWorkspaceId: homeDragBeforeId(next, movedId),
      );
      if (mounted) await _load();
    } catch (e) {
      _toast('排序失败：$e');
      if (mounted) await _load();
    }
  }

  void _onSessionDragStarted(
    String sessionId,
    String workspaceId,
    int index,
    Offset pointerGlobal,
  ) {
    if (_flying) return;
    _closeSwipe();
    _cancelHover();
    _dropCommitted = false;
    _snapShift = false;
    _flying = false;
    _flyStartTopLeft = null;
    final list = _visibleSessionsFor(workspaceId);
    homeDragReadSlotGeometry(
      [for (final s in list) _keyFor(_sessionCardKeys, s.sessionId)],
      _sessionHeights,
      _sessionCenters,
    );
    DshSessionSummary? session;
    for (final s in list) {
      if (s.sessionId == sessionId) {
        session = s;
        break;
      }
    }
    // 先从已布局槽位插入拖影，再隐藏源卡片，避免重建临界帧丢失尺寸。
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
            child: _sessionCard(
              session,
              visualOnly: true,
              includeBottomGap: false,
            ),
          ),
        ),
      );
    }
    setState(() {
      _draggingSessionId = sessionId;
      _draggingWorkspaceId = null;
      _workspacePreviewFrom = null;
      _workspacePreviewTo = null;
      _workspaceOrderOverride = null;
      _sessionPreviewWorkspaceId = workspaceId;
      _sessionPreviewFrom = index;
      _sessionPreviewTo = index;
      _sessionOrderOverride = null;
      _sessionOrderOverrideWorkspace = null;
    });
  }

  void _updateSessionPreviewFromGlobal(Offset global) {
    if (_flying || _dropCommitted) return;
    _lastDragGlobal = global;
    _followDragOverlay(global, height: _draggedSessionHeight);
    final currentWorkspace = _sessionPreviewWorkspaceId;
    final hoverWorkspace = _workspaceAtGlobal(global);
    final crossWorkspace = homeDragIsCrossProjectHover(
      currentId: currentWorkspace,
      hoverId: hoverWorkspace,
    );
    if (!crossWorkspace && _hoveringWorkspaceId != null) {
      _cancelHover();
    }
    if (crossWorkspace) {
      final target = hoverWorkspace;
      if (target == null) return;
      _onHoverWorkspace(target, expanded: _expandedGroups.contains(target));
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

  Rect? _globalRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  String? _workspaceAtGlobal(Offset global) {
    for (final workspace in _workspaces) {
      if (_globalRect(
            _keyFor(_workspaceBlockKeys, workspace.workspaceId),
          )?.contains(global) ==
          true) {
        return workspace.workspaceId;
      }
    }
    return null;
  }

  void _scheduleHoverTick(String workspaceId, {required bool expanded}) {
    _hoverTimer?.cancel();
    void fire() {
      if (!mounted || _draggingSessionId == null) return;
      final tick = _hover.tick(DateTime.now(), expanded: expanded);
      if (!expanded && tick.autoExpand) {
        _expandWorkspace(workspaceId);
        _hover.onExpanded(workspaceId, DateTime.now());
        _scheduleHoverTick(workspaceId, expanded: true);
        return;
      }
      if (expanded && tick.dropReady) {
        if (_dropReadyWorkspaceId != workspaceId) {
          _ensureCrossGeometry(workspaceId);
          final last = _lastDragGlobal;
          if (last != null && _crossGeometryId == workspaceId) {
            _crossInsertIndex = homeDragInsertIndexFromCenters(
              y: last.dy,
              centers: _crossCenters,
            );
          }
          setState(() => _dropReadyWorkspaceId = workspaceId);
        }
        return;
      }
      _hoverTimer = Timer(const Duration(milliseconds: 80), fire);
    }

    _hoverTimer = Timer(kHomeDragHoverDelay, fire);
  }

  void _onHoverWorkspace(String workspaceId, {required bool expanded}) {
    if (_draggingSessionId == null) return;
    if (_hoveringWorkspaceId == workspaceId) return;
    _hoveringWorkspaceId = workspaceId;
    _hover.onEnter(workspaceId, DateTime.now());
    _sessionPreviewTo = _sessionPreviewFrom;
    _crossGeometryId = null;
    _crossInsertIndex = 0;
    _crossHeights.clear();
    _crossCenters.clear();
    setState(() {
      if (_dropReadyWorkspaceId != null &&
          _dropReadyWorkspaceId != workspaceId) {
        _dropReadyWorkspaceId = null;
      }
    });
    _scheduleHoverTick(workspaceId, expanded: expanded);
  }

  void _refreshWorkspaceGeometry() {
    final workspaces = _visibleWorkspaces(_workspaces);
    homeDragReadSlotGeometry(
      [for (final w in workspaces) _keyFor(_workspaceBlockKeys, w.workspaceId)],
      _workspaceHeights,
      _workspaceCenters,
    );
  }

  void _refreshSessionGeometry() {
    final workspaceId = _sessionPreviewWorkspaceId;
    if (workspaceId == null) return;
    final ids = [for (final s in _visibleSessionsFor(workspaceId)) s.sessionId];
    homeDragReadSlotGeometry(
      [for (final id in ids) _keyFor(_sessionCardKeys, id)],
      _sessionHeights,
      _sessionCenters,
    );
  }

  void _ensureCrossGeometry(String workspaceId) {
    final ids = [for (final s in _visibleSessionsFor(workspaceId)) s.sessionId];
    if (ids.isEmpty) {
      _crossGeometryId = workspaceId;
      _crossHeights.clear();
      _crossCenters.clear();
      return;
    }
    if (homeDragReadSlotGeometry(
      [for (final id in ids) _keyFor(_sessionCardKeys, id)],
      _crossHeights,
      _crossCenters,
    )) {
      _crossGeometryId = workspaceId;
    }
  }

  void _updateCrossInsertFromGlobal(String workspaceId, Offset global) {
    if (!_expandedGroups.contains(workspaceId)) return;
    _ensureCrossGeometry(workspaceId);
    if (_crossGeometryId != workspaceId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _hoveringWorkspaceId != workspaceId) return;
        _ensureCrossGeometry(workspaceId);
        if (_crossGeometryId != workspaceId) return;
        _updateCrossInsertFromGlobal(workspaceId, global);
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

  List<DshSessionSummary> _visibleSessionsFor(
    String workspaceId, [
    Map<String, List<DshSessionSummary>>? byWorkspace,
  ]) {
    final raw =
        (byWorkspace ?? _sessionsByWorkspace())[workspaceId] ?? const [];
    if (_sessionOrderOverrideWorkspace != workspaceId ||
        _sessionOrderOverride == null) {
      return raw;
    }
    return orderByIds(
      raw,
      ids: _sessionOrderOverride!,
      idOf: (s) => s.sessionId,
    );
  }

  Map<String, List<DshSessionSummary>> _sessionsByWorkspace() {
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
    for (final w in _workspaces) {
      byWorkspace[w.workspaceId] = dshOrderedWorkspaceSessions(
        assigned: byWorkspace[w.workspaceId] ?? const [],
        sessionIds: w.sessionIds,
      );
    }
    return byWorkspace;
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

  Future<void> _commitSessionDrag([Offset? global]) async {
    if (_dropCommitted) return;
    if (global != null) {
      _updateSessionPreviewFromGlobal(global);
    }
    _dropCommitted = true;
    final from = _sessionPreviewFrom;
    final to = _sessionPreviewTo;
    final workspaceId = _sessionPreviewWorkspaceId;
    final sessionId = _draggingSessionId;
    final dropReady = _dropReadyWorkspaceId;
    _hoverTimer?.cancel();
    if (kHomeDragCrossProjectNeedsDropReady &&
        sessionId != null &&
        dropReady != null &&
        dropReady != workspaceId) {
      await _flyCrossWorkspaceThenDrop(
        sessionId: sessionId,
        toWorkspaceId: dropReady,
        toIndex: _crossInsertIndex,
      );
      return;
    }
    if (workspaceId != null && homeDragShouldFly(from: from, to: to)) {
      final destDy = homeDragSlotDestDy(
        from: from!,
        to: to!,
        heights: _sessionHeights,
      );
      final list = _visibleSessionsFor(workspaceId);
      final ids = [for (final s in list) s.sessionId];
      final changed = from != to;
      final next = changed ? moveIdToIndex(ids, ids[from], to) : ids;
      final flyingId = ids[from];
      DshSessionSummary? session;
      for (final s in list) {
        if (s.sessionId == flyingId) {
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
                : _sessionCard(
                    session,
                    visualOnly: true,
                    includeBottomGap: false,
                  ),
          ),
        ),
        applyOverride: () {
          if (!changed) return;
          _sessionOrderOverrideWorkspace = workspaceId;
          _sessionOrderOverride = next;
        },
        persist: () => changed
            ? _persistWorkspaceOrder(workspaceId, next)
            : Future.value(),
      );
      return;
    }
    if (!mounted) return;
    await _dragOverlay.land();
    setState(_clearDragPreview);
  }

  /// 先把未入账会话 `session.create(workspaceId)` 挂上，再只对已入账 id
  /// 生成 `insertSessionBefore`。cwd 兜底进来的会话不能直接当锚点。
  Future<void> _persistWorkspaceOrder(
    String workspaceId,
    List<String> next,
  ) async {
    DshWorkspace? workspace;
    for (final w in _workspaces) {
      if (w.workspaceId == workspaceId) {
        workspace = w;
        break;
      }
    }
    if (workspace == null) {
      if (mounted) await _load();
      return;
    }
    final accounted = List<String>.from(workspace.sessionIds);
    for (final id in next) {
      if (accounted.contains(id)) continue;
      try {
        await _api.createSession(sessionId: id, workspaceId: workspaceId);
        accounted.insert(0, id);
      } catch (_) {
        // cwd 对不上或会话无法入账：跳过，避免整单排序失败。
      }
    }
    final desired = dshAccountedReorderDesired(
      visible: next,
      accounted: accounted,
    );
    final ops = dshReorderPlanForInsertion(
      current: accounted,
      desired: desired,
    );
    if (ops.isEmpty) {
      if (mounted) await _load();
      return;
    }
    try {
      for (final op in ops) {
        await _api.insertSessionBefore(
          workspaceId,
          op.sessionId,
          beforeSessionId: op.beforeSessionId,
        );
      }
      if (mounted) await _load();
    } catch (e) {
      _toast('排序失败：$e');
      if (mounted) await _load();
    }
  }

  Future<void> _attachThenInsert(
    String workspaceId,
    String sessionId, {
    String? beforeSessionId,
  }) async {
    try {
      await _api.insertSessionBefore(
        workspaceId,
        sessionId,
        beforeSessionId: beforeSessionId,
      );
    } on DshApiException catch (e) {
      if (e.code != 'workspace-move-invalid') rethrow;
      await _api.createSession(sessionId: sessionId, workspaceId: workspaceId);
      await _api.insertSessionBefore(
        workspaceId,
        sessionId,
        beforeSessionId: beforeSessionId,
      );
    }
  }

  double _insertGapHeight(String workspaceId) {
    final dragging = _draggingSessionId;
    final alreadyInTarget =
        dragging != null &&
        _visibleSessionsFor(workspaceId).any((s) => s.sessionId == dragging);
    return homeDragInsertGapHeight(
      dropReadyId: _dropReadyWorkspaceId,
      groupId: workspaceId,
      sessionAlreadyInTarget: alreadyInTarget,
      draggedHeight: _draggedSessionHeight,
    );
  }

  Offset? _crossWorkspaceLanding(String toWorkspaceId, int toIndex) {
    final ids = [
      for (final s in _visibleSessionsFor(toWorkspaceId)) s.sessionId,
    ];
    Offset? destSlot;
    if (toIndex < ids.length) {
      final slot = homeDragOriginSlot(_keyFor(_sessionCardKeys, ids[toIndex]));
      if (slot.$2 != Size.zero) destSlot = slot.$1;
    }
    final gap = homeDragOriginSlot(_keyFor(_insertGapKeys, toWorkspaceId));
    final header = homeDragOriginSlot(
      _keyFor(_workspaceHeaderKeys, toWorkspaceId),
    );
    final headerSize = header.$2 == Size.zero ? const Size(0, 56) : header.$2;
    if (header.$2 == Size.zero && gap.$2 == Size.zero && destSlot == null) {
      return null;
    }
    return homeDragCrossInsertLanding(
      headerTopLeft: header.$1,
      headerSize: headerSize,
      gapTopLeft: gap.$2.height > 0 ? gap.$1 : null,
      destSlotTopLeft: destSlot,
    );
  }

  Future<void> _flyCrossWorkspaceThenDrop({
    required String sessionId,
    required String toWorkspaceId,
    required int toIndex,
  }) async {
    setState(() {
      _flying = true;
      _crossDropCommitting = true;
    });
    final landing = _crossWorkspaceLanding(toWorkspaceId, toIndex);
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
    var expandTarget = false;
    setState(() {
      _prepareCrossDropCommit();
      _commitMoveSessionId = sessionId;
      _commitMoveWorkspaceId = toWorkspaceId;
      _commitMoveIndex = toIndex;
      if (!_expandedGroups.contains(toWorkspaceId)) {
        _expandedGroups.add(toWorkspaceId);
        expandTarget = true;
      }
      _applyOptimisticMove(sessionId, toWorkspaceId, toIndex: toIndex);
    });
    if (expandTarget) unawaited(_saveExpanded());
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _dropSessionOnWorkspace(sessionId, toWorkspaceId, toIndex: toIndex);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(_clearDragPreview);
  }

  Future<void> _dropSessionOnWorkspace(
    String sessionId,
    String workspaceId, {
    int toIndex = 0,
  }) async {
    try {
      await _relocateSessionToWorkspace(
        sessionId,
        workspaceId,
        toIndex: toIndex,
      );
      if (!mounted) return;
      await _load(quiet: true);
    } catch (e) {
      _toast('移动失败：$e');
      _commitMoveSessionId = null;
      _commitMoveWorkspaceId = null;
      if (mounted) await _load(quiet: true);
    }
  }

  Future<Map<String, dynamic>?> _tryPluginMove({
    required String sessionId,
    required String workspaceId,
    required String workspacePath,
  }) async {
    try {
      return await _api.moveSessionToWorkspace(
        sessionId: sessionId,
        workspaceId: workspaceId,
        workspacePath: workspacePath,
      );
    } on DshApiException catch (e) {
      if (e.code != 'plugin-missing') rethrow;
    }
    if (DshService.instance.managesLocalProcess) {
      await DshService.instance.start();
    }
    try {
      return await _api.moveSessionToWorkspace(
        sessionId: sessionId,
        workspaceId: workspaceId,
        workspacePath: workspacePath,
      );
    } on DshApiException catch (e) {
      if (e.code != 'plugin-missing') rethrow;
    }
    return null;
  }

  Future<void> _relocateSessionToWorkspace(
    String sessionId,
    String workspaceId, {
    int toIndex = 0,
  }) async {
    DshWorkspace? target;
    DshSessionSummary? session;
    for (final w in _workspaces) {
      if (w.workspaceId == workspaceId) {
        target = w;
        break;
      }
    }
    for (final s in _sessions) {
      if (s.sessionId == sessionId) {
        session = s;
        break;
      }
    }
    if (target == null) {
      throw StateError('工作区不存在');
    }
    final before = [
      for (final id in target.sessionIds)
        if (id != sessionId) id,
    ];
    final insertAt = toIndex < 0
        ? 0
        : (toIndex > before.length ? before.length : toIndex);
    final beforeId = insertAt >= before.length ? null : before[insertAt];
    final moved = await _tryPluginMove(
      sessionId: sessionId,
      workspaceId: workspaceId,
      workspacePath: target.path,
    );
    if (moved != null) {
      if (moved['attachError'] != null) {
        await _attachThenInsert(
          workspaceId,
          sessionId,
          beforeSessionId: beforeId,
        );
        return;
      }
      try {
        await _api.insertSessionBefore(
          workspaceId,
          sessionId,
          beforeSessionId: beforeId,
        );
      } on DshApiException catch (_) {
        // 目录已经搬过去了，顺序失败不回滚。
      }
      return;
    }
    final cwd = dshSessionMoveCwd(
      sessionCwd: session?.cwd,
      workspacePath: target.path,
    );
    if (cwd != null) {
      throw DshApiException(
        '跨工作区移动需要重启 DSH 后生效，请到引擎页重启服务再试',
        code: 'plugin-missing',
      );
    }
    await _attachThenInsert(workspaceId, sessionId, beforeSessionId: beforeId);
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

  List<Widget> _sessionCardsWithGap({
    required List<DshSessionSummary> list,
    required String workspaceId,
  }) {
    final draggingHere =
        _draggingSessionId != null && _sessionPreviewWorkspaceId == workspaceId;
    final from = draggingHere ? _sessionPreviewFrom : null;
    final to = draggingHere ? _sessionPreviewTo : null;
    final alreadyHere =
        _draggingSessionId != null &&
        list.any((s) => s.sessionId == _draggingSessionId);
    final crossHere = homeDragAppliesForeignShift(
      dropReadyHere: _dropReadyWorkspaceId == workspaceId,
      originGroup: _sessionPreviewWorkspaceId == workspaceId,
      draggedAlreadyHere: alreadyHere,
    );
    return [
      for (var i = 0; i < list.length; i++)
        _shiftedSlot(
          key: _keyFor(_sessionCardKeys, list[i].sessionId),
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
            indexInWorkspace: i,
            workspaceId: workspaceId,
          ),
        ),
    ];
  }

  Widget _dragSessionCard({
    required DshSessionSummary session,
    required int indexInWorkspace,
    required String workspaceId,
  }) {
    Widget card({bool visualOnly = false}) => _sessionCard(
      session,
      visualOnly: visualOnly,
      disableSwipe: !visualOnly && _draggingSessionId == session.sessionId,
    );
    return HomeLongPressDrag(
      key: ValueKey('drag_session_${session.sessionId}'),
      enabled:
          _draggingSessionId == null || _draggingSessionId == session.sessionId,
      onDragStart: (details) => _onSessionDragStarted(
        session.sessionId,
        workspaceId,
        indexInWorkspace,
        details.globalPosition,
      ),
      onDragUpdate: (details) =>
          _updateSessionPreviewFromGlobal(details.globalPosition),
      onDragEnd: (details) => _commitSessionDrag(details.globalPosition),
      onDragCancel: _commitSessionDrag,
      onDragSettled: _removeDragVisuals,
      child: HomeDragHeightFactor(
        factor: homeDragCardSlotFactor(
          isDragged: _draggingSessionId == session.sessionId,
          keepCollapsed: homeDragSourceSlotKeepCollapsed(
            committing: _crossDropCommitting,
            originId: _sessionPreviewWorkspaceId,
            cardGroupId: workspaceId,
          ),
          originId: _sessionPreviewWorkspaceId,
          hoverId: _hoveringWorkspaceId ?? _dropReadyWorkspaceId,
          cardGroupId: workspaceId,
        ),
        snap:
            homeDragSourceSlotKeepCollapsed(
              committing: _crossDropCommitting,
              originId: _sessionPreviewWorkspaceId,
              cardGroupId: workspaceId,
            ) ||
            homeDragSourceSlotSnaps(
              originId: _sessionPreviewWorkspaceId,
              cardGroupId: workspaceId,
            ),
        child: Opacity(
          opacity: _draggingSessionId == session.sessionId ? 0 : 1,
          child: card(),
        ),
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
