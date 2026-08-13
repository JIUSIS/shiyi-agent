import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../services/file_workspace.dart';
import '../services/permission_service.dart';
import '../widgets/ios_style.dart';
import '../widgets/markdown_text.dart';
import '../widgets/traffic_lights_button.dart';

/// 文件管理页：浏览智能体工作目录（默认 /storage/emulated/0/agent），
/// 支持新建文件夹、预览文本文件、删除，以及把任意文件夹设为工作目录。
class FilesScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const FilesScreen({super.key, required this.shiyi});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  String _path = '';
  String _workspace = '';
  bool _permission = true;
  String? _error;
  Future<List<FileSystemEntity>>? _entriesFuture;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _permission = await PermissionService.isFullAccessGranted();
    _workspace = await FileWorkspace.current();
    if (_path.isEmpty) _path = _workspace;
    _entriesFuture = _listEntries(_path);
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    _entriesFuture = _listEntries(_path);
    if (mounted) setState(() {});
  }

  Future<List<FileSystemEntity>> _listEntries(String path) async {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        Directory(_workspace).createSync(recursive: true);
      }
      final entries = <FileSystemEntity>[];
      await for (final e in dir.list(followLinks: false)) {
        entries.add(e);
      }
      entries.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad - bd;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      _error = null;
      return entries;
    } catch (e) {
      _error = '读取目录失败：$e';
      return const <FileSystemEntity>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CupertinoTheme(
      data: CupertinoThemeData(brightness: theme.brightness),
      child: Scaffold(
        backgroundColor: iosGroupedBackground(context),
        appBar: AppBar(
          leadingWidth: 72,
          leading: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: ListenableBuilder(
              listenable: widget.shiyi,
              builder: (context, _) =>
                  TrafficLightsButton(tooltip: '', busy: widget.shiyi.isBusy),
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
            '文件',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          actions: [
            CupertinoButton(
              padding: const EdgeInsets.all(8),
              onPressed: _refresh,
              child: const Icon(CupertinoIcons.refresh),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CupertinoButton(
                padding: const EdgeInsets.all(8),
                onPressed: _setWorkspace,
                child: const Icon(CupertinoIcons.star),
              ),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pathBar(),
            if (!_permission) _permissionBar(),
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
            onPressed: _path == _workspace ? null : _goUp,
            child: const Icon(CupertinoIcons.arrow_up),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final dir = await _pickDirectory(context, _path);
                if (dir != null && mounted) {
                  setState(() {
                    _path = dir;
                    _entriesFuture = _listEntries(dir);
                  });
                }
              },
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

  Widget _permissionBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: CupertinoColors.systemYellow.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.folder_badge_minus,
            size: 18,
            color: CupertinoColors.systemOrange,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '需要「所有文件访问权限」才能读写 SD 卡',
              style: TextStyle(fontSize: 13),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: () async {
              final ok = await PermissionService.requestFullAccess();
              if (mounted) setState(() => _permission = ok);
            },
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final future = _entriesFuture;
    if (future == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return FutureBuilder<List<FileSystemEntity>>(
      future: future,
      builder: (context, snap) {
        final entries = snap.data ?? const <FileSystemEntity>[];
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (entries.isEmpty) {
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
              children: [for (final e in entries) _buildEntryTile(e)],
            ),
          ],
        );
      },
    );
  }

  Widget _buildEntryTile(FileSystemEntity e) {
    final name = e.path.split(Platform.pathSeparator).last;
    if (e is Directory) {
      return CupertinoListTile(
        leading: const Icon(
          CupertinoIcons.folder_fill,
          color: CupertinoColors.activeBlue,
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => _showActions(e),
          child: const Icon(CupertinoIcons.ellipsis),
        ),
        onTap: () => setState(() => _path = e.path),
      );
    }
    final f = e as File;
    int? size;
    try {
      size = f.lengthSync();
    } catch (_) {}
    return CupertinoListTile(
      leading: const Icon(
        CupertinoIcons.doc,
        color: CupertinoColors.systemGrey,
      ),
      title: Text(name),
      subtitle: size == null ? null : Text(_fmtBytes(size)),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => _showActions(e),
        child: const Icon(CupertinoIcons.ellipsis),
      ),
      onTap: () => _previewFile(f),
    );
  }

  void _showActions(FileSystemEntity e) {
    final isDir = e is Directory;
    final name = e.path.split(Platform.pathSeparator).last;
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              _copyPath(e.path);
            },
            child: const Text('复制路径'),
          ),
          if (isDir)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _setWorkspaceTo(e.path);
              },
              child: const Text('设为工作目录'),
            ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              _delete(e);
            },
            child: const Text('删除'),
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('路径已复制：$path')));
  }

  Future<void> _setWorkspace() async {
    await _setWorkspaceTo(_path);
  }

  Future<void> _setWorkspaceTo(String path) async {
    await FileWorkspace.setPath(path);
    if (!mounted) return;
    setState(() {
      _workspace = path;
      _path = path;
      _entriesFuture = _listEntries(path);
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('工作目录已设为：$path')));
  }

  Future<void> _goUp() async {
    final parent = Directory(_path).parent.path;
    if (parent == _path) return;
    setState(() {
      _path = parent;
      _entriesFuture = _listEntries(parent);
    });
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
    if (name == null || name.isEmpty) return;
    try {
      Directory('$_path/$name').createSync(recursive: true);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建失败：$e')));
      }
    }
  }

  Future<void> _delete(FileSystemEntity e) async {
    final isDir = e is Directory;
    final name = e.path.split(Platform.pathSeparator).last;
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(isDir ? '删除文件夹' : '删除文件'),
        content: Text('确定删除「$name」吗？${isDir ? '（含里面所有内容）' : ''}'),
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
      if (isDir) {
        e.deleteSync(recursive: true);
      } else {
        e.deleteSync();
      }
      await _refresh();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$err')));
      }
    }
  }

  Future<void> _previewFile(File f) async {
    String content;
    try {
      if (await f.length() > 512 * 1024) {
        content = '(文件过大，超过 512KB，无法预览，可用 run_terminal 读取)';
      } else {
        content = await f.readAsString();
      }
    } catch (e) {
      content = '读取失败：$e';
    }
    if (!mounted) return;
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(
          f.path.split(Platform.pathSeparator).last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 420,
          height: 420,
          child: _isTextPath(f.path)
              ? SingleChildScrollView(
                  child: AdaptiveMarkdownText(
                    content,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    content,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static const Set<String> _textExts = {
    '.md',
    '.markdown',
    '.txt',
    '.json',
    '.jsonl',
    '.yaml',
    '.yml',
    '.sh',
    '.py',
    '.js',
    '.ts',
    '.dart',
    '.xml',
    '.html',
    '.htm',
    '.css',
    '.toml',
    '.ini',
    '.conf',
    '.cfg',
    '.sql',
    '.csv',
    '.log',
    '.rb',
    '.go',
    '.rs',
    '.php',
    '.svg',
    '.properties',
    '.env',
    '.gitignore',
    '.prompt',
    '.text',
    '.bat',
    '.ps1',
  };

  static bool _isTextPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return _textExts.contains(path.substring(dot).toLowerCase());
  }

  static String _fmtBytes(int n) {
    if (n >= 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '$n B';
  }

  /// 让用户浏览选择一个目录（用于切换浏览位置）。
  Future<String?> _pickDirectory(BuildContext ctx, String start) async {
    var cur = start;
    var dirsFuture = _listSubdirectories(cur);
    return showIosFadeDialog<String>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlg) {
          return CupertinoAlertDialog(
            title: Text(cur, maxLines: 1, overflow: TextOverflow.ellipsis),
            content: SizedBox(
              width: 360,
              height: 380,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: () {
                        final p = Directory(cur).parent.path;
                        if (p != cur) {
                          cur = p;
                          dirsFuture = _listSubdirectories(cur);
                          setDlg(() {});
                        }
                      },
                      child: const Text('上一级'),
                    ),
                  ),
                  Expanded(
                    child: FutureBuilder<List<Directory>>(
                      future: dirsFuture,
                      builder: (context, snap) {
                        final dirs = snap.data ?? const <Directory>[];
                        if (snap.connectionState != ConnectionState.done) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (dirs.isEmpty) {
                          return const Center(child: Text('没有子文件夹'));
                        }
                        return ListView.builder(
                          itemCount: dirs.length,
                          itemBuilder: (_, i) => CupertinoListTile(
                            leading: const Icon(
                              CupertinoIcons.folder,
                              size: 18,
                            ),
                            title: Text(
                              dirs[i].path.split(Platform.pathSeparator).last,
                              style: const TextStyle(fontSize: 14),
                            ),
                            onTap: () {
                              cur = dirs[i].path;
                              dirsFuture = _listSubdirectories(cur);
                              setDlg(() {});
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dctx),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(dctx, cur),
                child: const Text('进入此文件夹'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<List<Directory>> _listSubdirectories(String path) async {
    try {
      final dirs = <Directory>[];
      await for (final e in Directory(path).list(followLinks: false)) {
        if (e is Directory) dirs.add(e);
      }
      dirs.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      return dirs;
    } catch (_) {
      return const <Directory>[];
    }
  }
}
