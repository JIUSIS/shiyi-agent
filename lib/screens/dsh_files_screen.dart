import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../services/dsh_api.dart';
import '../services/file_workspace.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import 'dsh_center_screen.dart';

/// 主机文件浏览页（host.describe / host.listDirectory / host.pickDirectory）。
/// Apple HIG Inset Grouped 风格目录导航。
/// [asTab]：作为 DS Harness 引擎的主页 tab（tab 2）时无返回键、大标题，
/// 点标题刷新当前目录，右上角为设置（DS Harness 中心），
/// 目录栈回退由页内箭头完成。
class DshFilesScreen extends StatefulWidget {
  final bool asTab;
  final ShiyiState? shiyi;
  final String? initialPath;
  const DshFilesScreen({
    super.key,
    this.asTab = false,
    this.shiyi,
    this.initialPath,
  });

  @override
  State<DshFilesScreen> createState() => _DshFilesScreenState();
}

class _DshFilesScreenState extends State<DshFilesScreen> {
  String _path = '';
  List<DshDirEntry> _items = [];
  bool _loading = true;
  String? _error;
  final List<String> _stack = [];

  DshApiClient get _api => DshApiClient.instance;

  @override
  void initState() {
    super.initState();
    final initialPath = widget.initialPath?.trim() ?? '';
    if (initialPath.isEmpty) {
      _loadHome();
    } else {
      _loadDir(initialPath);
    }
  }

  Future<void> _loadHome() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 默认浏览软件默认 agent 目录；不可用时回退 dsh 主机 cwd。
      final agent = FileWorkspace.defaultWorkspacePath;
      try {
        final items = await _api.listDirectory(agent);
        if (!mounted) return;
        setState(() {
          _path = agent;
          _items = items;
          _loading = false;
        });
        return;
      } catch (_) {}
      final host = await _api.hostDescribe();
      await _loadDir(host.cwd);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadDir(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _api.listDirectory(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _items = items;
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

  void _open(DshDirEntry e) {
    if (!e.isDirectory) return;
    _stack.add(_path);
    _loadDir(e.path);
  }

  void _back() {
    if (_stack.isEmpty) {
      // tab 模式（asTab）栈空时无上级；push 页则返回。
      if (!widget.asTab) _pop();
      return;
    }
    final prev = _stack.removeLast();
    _loadDir(prev);
  }

  Future<void> _pick() async {
    try {
      final path = await _api.pickDirectory();
      if (path == null || path.isEmpty) return;
      _loadDir(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('选择失败：$e')));
    }
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
        leading: widget.asTab && _stack.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: MacActionButton(
                    icon: _stack.isEmpty
                        ? CupertinoIcons.chevron_left
                        : CupertinoIcons.arrow_left,
                    tooltip: _stack.isEmpty ? '返回' : '上一级',
                    onTap: _back,
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
          // 主页 tab：点标题刷新当前目录。
          onTap: widget.asTab ? () => _loadDir(_path) : null,
          child: Text(
            _path.isEmpty ? '文件' : _basename(_path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: widget.asTab && _stack.isEmpty ? 28 : 22,
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
                    icon: CupertinoIcons.folder_badge_plus,
                    tooltip: '选择目录',
                    onTap: _pick,
                  ),
                  const SizedBox(width: 4),
                  MacActionButton(
                    icon: CupertinoIcons.refresh,
                    tooltip: '刷新',
                    onTap: () => _loadDir(_path),
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

  static String _basename(String p) {
    final t = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    final i = t.lastIndexOf('/');
    return i >= 0 ? t.substring(i + 1) : t;
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
            CupertinoButton.filled(
              onPressed: () => _loadDir(_path),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: isIosDark(context)
              ? const Color(0x3320A24C)
              : const Color(0x1A20A24C),
          child: Text(
            _path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isIosDark(context)
                  ? const Color(0xFF7DD3A8)
                  : const Color(0xFF1E8E4E),
            ),
          ),
        ),
        Expanded(
          child: _items.isEmpty
              ? const Center(child: Text('空目录'))
              : ListView(
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  children: [
                    CupertinoListSection.insetGrouped(
                      margin: iosSectionMargin,
                      decoration: iosSectionDecoration(context),
                      children: [
                        for (final e in _items)
                          CupertinoListTile(
                            key: ValueKey(e.path),
                            leading: Icon(
                              e.isDirectory
                                  ? CupertinoIcons.folder_fill
                                  : CupertinoIcons.doc_fill,
                              color: e.isDirectory
                                  ? CupertinoColors.activeBlue
                                  : CupertinoColors.systemGrey,
                            ),
                            title: Text(
                              e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: !e.isDirectory && e.size != null
                                ? Text(_sizeLabel(e.size!))
                                : null,
                            trailing: e.isDirectory
                                ? const Icon(
                                    CupertinoIcons.chevron_right,
                                    size: 16,
                                  )
                                : null,
                            onTap: e.isDirectory ? () => _open(e) : null,
                          ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  static String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
