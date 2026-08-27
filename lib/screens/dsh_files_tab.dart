import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../services/dsh_api.dart';
import '../services/dsh_endpoint.dart';
import '../services/dsh_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';
import 'dsh_center_screen.dart';

/// DS Harness 引擎的主页 tab 2「文件」：
/// 外观完全复用拾忆文件页（红绿灯/大标题/路径栏/条目列表/操作菜单），
/// 数据为 DeepSeek Harness 主机目录（host.listDirectory / pickDirectory /
/// createDirectory / openPath）。
/// 标题点击刷新当前目录；右上角设置 = DS Harness 中心。
class DshFilesTab extends StatefulWidget {
  final ShiyiState shiyi;
  const DshFilesTab({super.key, required this.shiyi});

  @override
  State<DshFilesTab> createState() => _DshFilesTabState();
}

class _DshFilesTabState extends State<DshFilesTab> {
  String _path = '';
  List<DshDirEntry> _items = [];
  List<DshDirEntry> _crumbs = [];
  final List<String> _stack = [];
  bool _loading = true;
  String? _error;
  String _cwdPath = '';
  List<DshDirEntry> _roots = const [];
  bool _canOpenPath = false;
  int _requestEpoch = 0;
  late String _connectionKey;
  Timer? _retryTimer;

  DshApiClient get _api => DshService.instance.api;

  @override
  void initState() {
    super.initState();
    _connectionKey = _currentConnectionKey();
    widget.shiyi.addListener(_handleSettingsChanged);
    unawaited(_loadHome());
  }

  @override
  void didUpdateWidget(covariant DshFilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shiyi == widget.shiyi) return;
    oldWidget.shiyi.removeListener(_handleSettingsChanged);
    widget.shiyi.addListener(_handleSettingsChanged);
    _handleSettingsChanged();
  }

  String _currentConnectionKey() {
    final s = widget.shiyi.settings;
    return [
      DshEndpoint.modeOf(s),
      DshEndpoint.urlOf(s),
      s.dshRemoteHost,
      s.dshRemoteToken,
    ].join('\u0000');
  }

  void _handleSettingsChanged() {
    final next = _currentConnectionKey();
    if (next == _connectionKey) return;
    _connectionKey = next;
    _requestEpoch++;
    _stopServiceRetry();
    if (!mounted) return;
    setState(() {
      _path = '';
      _items = [];
      _crumbs = [];
      _stack.clear();
      _cwdPath = '';
      _roots = const [];
      _canOpenPath = false;
      _loading = true;
      _error = null;
    });
    unawaited(_loadHome());
  }

  Future<void> _loadHome() async {
    final epoch = ++_requestEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    // 先诊断服务：未安装提示未安装，未启动提示未启动，就绪再拉目录。
    final reason = await DshService.instance.unavailableReason();
    if (!mounted || epoch != _requestEpoch) return;
    if (reason != null) {
      setState(() {
        _loading = false;
        _error = reason;
      });
      _scheduleServiceRetry();
      return;
    }
    _stopServiceRetry();
    try {
      DshHostInfo? host;
      try {
        host = await DshService.instance.withRecover(
          _api.hostDescribe,
          recover: false,
        );
      } catch (_) {}

      final cwd = host?.cwd.trim() ?? '';
      final home = host?.home.trim() ?? '';
      final listing = await DshService.instance.withRecover(
        () => cwd.isNotEmpty
            ? _api.directoryListing(cwd)
            : _api.directoryListing(),
        recover: false,
      );
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _cwdPath = cwd;
        _canOpenPath = host?.canOpenPath ?? false;
        _applyListing(listing, fallbackPath: cwd.isNotEmpty ? cwd : home);
      });
      unawaited(
        _loadRoots(
          epoch,
          platform: host?.platform ?? '',
          pathHint: listing.path.isNotEmpty ? listing.path : cwd,
        ),
      );
    } catch (e) {
      if (!mounted || epoch != _requestEpoch) return;
      final hint = await DshService.instance.unavailableReason();
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _loading = false;
        _error = hint ?? '$e';
      });
      if (hint != null) _scheduleServiceRetry();
    }
  }

  Future<void> _loadRoots(
    int epoch, {
    required String platform,
    required String pathHint,
  }) async {
    final roots = await _api.scanRootDirectories(
      platform: platform,
      pathHint: pathHint,
    );
    if (!mounted || epoch != _requestEpoch) return;
    setState(() => _roots = roots);
  }

  Future<void> _loadDir(String path) async {
    final epoch = ++_requestEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await _api.directoryListing(path);
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _applyListing(listing, fallbackPath: path);
      });
    } catch (e) {
      if (!mounted || epoch != _requestEpoch) return;
      final hint = await DshService.instance.unavailableReason();
      if (!mounted || epoch != _requestEpoch) return;
      setState(() {
        _loading = false;
        _error = hint ?? '$e';
      });
      if (hint != null) _scheduleServiceRetry();
    }
  }

  void _applyListing(
    DshDirectoryListing listing, {
    required String fallbackPath,
  }) {
    _path = listing.path.isNotEmpty ? listing.path : fallbackPath;
    _crumbs = listing.crumbs;
    _items = listing.entries;
    _loading = false;
    _error = null;
  }

  @override
  void dispose() {
    widget.shiyi.removeListener(_handleSettingsChanged);
    _requestEpoch++;
    _retryTimer?.cancel();
    super.dispose();
  }

  /// 服务未就绪时每 3 秒自动重查，起来后重新加载目录。
  void _scheduleServiceRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      final reason = await DshService.instance.unavailableReason();
      if (!mounted) return;
      if (reason == null) {
        _retryTimer?.cancel();
        _retryTimer = null;
        await _loadHome();
      } else {
        setState(() => _error = reason);
      }
    });
  }

  void _stopServiceRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _open(DshDirEntry e) {
    if (!e.isDirectory) return;
    _stack.add(_path);
    _loadDir(e.path);
  }

  void _goUp() {
    if (_stack.isNotEmpty) {
      final prev = _stack.removeLast();
      _loadDir(prev);
      return;
    }
    final current = _crumbs.lastIndexWhere((e) => e.path == _path);
    if (current > 0) _loadDir(_crumbs[current - 1].path);
  }

  Future<void> _pick() async {
    final locations = <String, String>{};
    void add(String label, String path) {
      final normalized = path.trim();
      if (normalized.isNotEmpty && !locations.containsValue(normalized)) {
        locations[label] = normalized;
      }
    }

    for (final root in _roots) {
      add(root.name.isEmpty ? root.path : root.name, root.path);
    }
    add('工作目录', _cwdPath);
    if (locations.isEmpty) return;
    final selected = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择位置'),
        actions: [
          for (final location in locations.entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, location.value),
              child: Text(location.key),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected == null || selected == _path) return;
    _stack.clear();
    await _loadDir(selected);
  }

  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showIosFadeDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('新建文件夹'),
        content: CupertinoTextField(
          controller: ctrl,
          autofocus: true,
          placeholder: '文件夹名称',
          padding: const EdgeInsets.all(10),
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
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await _api.createDirectory(_path, name);
      await _loadDir(_path);
    } catch (e) {
      _toast('创建失败：$e');
    }
  }

  void _showActions(DshDirEntry e) {
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        message: Text(
          e.path,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _copyPath(e.path);
            },
            child: const Text('复制路径'),
          ),
          if (_canOpenPath)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _openPath(e);
              },
              child: const Text('用系统打开'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }

  void _copyPath(String path) {
    Clipboard.setData(ClipboardData(text: path));
    _toast('路径已复制：$path');
  }

  Future<void> _openPath(DshDirEntry e) async {
    try {
      await _api.openPath(e.path);
    } catch (err) {
      _toast('打开失败：$err');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _refresh() => _path.isEmpty ? _loadHome() : _loadDir(_path);

  bool get _canGoUp {
    if (_stack.isNotEmpty) return true;
    final current = _crumbs.lastIndexWhere((e) => e.path == _path);
    return current > 0;
  }

  static String _basename(String p) {
    final t = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    final i = t.lastIndexOf('/');
    return i >= 0 ? t.substring(i + 1) : t;
  }

  static String _fmtBytes(int n) {
    if (n >= 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '$n B';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: Scaffold(
        backgroundColor: iosGroupedBackground(context),
        appBar: AppBar(
          leadingWidth: 72,
          leading: Platform.isWindows
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: TrafficLightsButton(tooltip: '', busy: _loading),
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
            onTap: _refresh,
            child: Text(
              _path.isEmpty ? '文件' : _basename(_path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pathBar(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _pathBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          CupertinoButton(
            padding: const EdgeInsets.all(8),
            onPressed: _canGoUp ? _goUp : null,
            child: const Icon(CupertinoIcons.arrow_up),
          ),
          Expanded(
            child: GestureDetector(
              onTap: _pick,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _path.isEmpty ? '…' : _path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: CupertinoColors.activeBlue,
                  ),
                ),
              ),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.all(8),
            onPressed: _newFolder,
            child: const Icon(CupertinoIcons.folder_badge_plus),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _error ?? '空文件夹',
          style: TextStyle(color: CupertinoColors.secondaryLabel),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      children: [
        CupertinoListSection.insetGrouped(
          margin: iosSectionMargin,
          decoration: iosSectionDecoration(context),
          children: [for (final e in _items) _buildEntryTile(e)],
        ),
      ],
    );
  }

  Widget _buildEntryTile(DshDirEntry e) {
    return GestureDetector(
      onSecondaryTapDown: (d) => _showActions(e),
      child: CupertinoListTile(
        leading: Icon(
          e.isDirectory ? CupertinoIcons.folder_fill : CupertinoIcons.doc,
          color: e.isDirectory
              ? CupertinoColors.activeBlue
              : CupertinoColors.systemGrey,
        ),
        title: Text(
          e.name,
          style: e.isDirectory
              ? const TextStyle(fontWeight: FontWeight.w500)
              : null,
        ),
        subtitle: e.isDirectory || e.size == null
            ? null
            : Text(_fmtBytes(e.size!)),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => _showActions(e),
          child: const Icon(CupertinoIcons.ellipsis),
        ),
        onTap: () => _open(e),
      ),
    );
  }
}
