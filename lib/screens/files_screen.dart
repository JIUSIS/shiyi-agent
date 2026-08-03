import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../services/file_workspace.dart';
import '../services/permission_service.dart';
import '../widgets/markdown_text.dart';

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _permission = await PermissionService.isFullAccessGranted();
    _workspace = await FileWorkspace.current();
    if (_path.isEmpty) _path = _workspace;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: IconButton(
              tooltip: '把当前文件夹设为工作目录',
              icon: const Icon(Icons.star_outline),
              onPressed: () => _setWorkspace(),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _pathBar() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一级',
            icon: const Icon(Icons.arrow_upward),
            onPressed: _path == _workspace ? null : _goUp,
          ),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final dir = await _pickDirectory(context, _path);
                if (dir != null) setState(() => _path = dir);
              },
              child: Text(
                _path.isEmpty ? '…' : _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _newFolder,
          ),
        ],
      ),
    );
  }

  Widget _permissionBar() {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: .4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_off_outlined, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('需要「所有文件访问权限」才能读写 SD 卡'),
          ),
          TextButton(
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
    final Directory dir;
    try {
      dir = Directory(_path);
      if (!dir.existsSync()) {
        Directory(_workspace).createSync(recursive: true);
      }
    } catch (_) {
      return const Center(child: Text('无法访问目录'));
    }

    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
      entries.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad - bd;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      _error = null;
    } catch (e) {
      _error = '读取目录失败：$e';
      entries = [];
    }

    if (entries.isEmpty) {
      return const Center(child: Text('空文件夹', style: TextStyle(color: Colors.grey)));
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final name = e.path.split(Platform.pathSeparator).last;
        if (e is Directory) {
          return ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
            trailing: IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              onPressed: () => _showActions(e),
            ),
            onTap: () => setState(() => _path = e.path),
          );
        }
        final f = e as File;
        int? size;
        try {
          size = f.lengthSync();
        } catch (_) {}
        return ListTile(
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: Text(name),
          subtitle: size == null ? null : Text(_fmtBytes(size)),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert, size: 20),
            onPressed: () => _showActions(e),
          ),
          onTap: () => _previewFile(f),
        );
      },
    );
  }

  void _showActions(FileSystemEntity e) {
    final isDir = e is Directory;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制路径'),
              onTap: () {
                Navigator.pop(ctx);
                _copyPath(e.path);
              },
            ),
            if (isDir)
              ListTile(
                leading: const Icon(Icons.star_outline),
                title: const Text('设为工作目录'),
                onTap: () {
                  Navigator.pop(ctx);
                  _setWorkspaceTo(e.path);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(e);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _copyPath(String path) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('路径已复制：$path')),
    );
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
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('工作目录已设为：$path')),
    );
  }

  Future<void> _goUp() async {
    final parent = Directory(_path).parent.path;
    if (parent == _path) return;
    setState(() => _path = parent);
  }

  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      Directory('$_path/$name').createSync(recursive: true);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败：$e')),
        );
      }
    }
  }

  Future<void> _delete(FileSystemEntity e) async {
    final isDir = e is Directory;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? '删除文件夹' : '删除文件'),
        content: Text('确定删除「${e.path.split(Platform.pathSeparator).last}」吗？${isDir ? '（含里面所有内容）' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
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
      if (mounted) setState(() {});
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$err')),
        );
      }
    }
  }

  Future<void> _previewFile(File f) async {
    String content;
    try {
      if (f.lengthSync() > 512 * 1024) {
        content = '(文件过大，超过 512KB，无法预览，可用 run_terminal 读取)';
      } else {
        content = f.readAsStringSync();
      }
    } catch (e) {
      content = '读取失败：$e';
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
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
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static const Set<String> _textExts = {
    '.md', '.markdown', '.txt', '.json', '.jsonl', '.yaml', '.yml',
    '.sh', '.py', '.js', '.ts', '.dart', '.xml', '.html', '.htm',
    '.css', '.toml', '.ini', '.conf', '.cfg', '.sql', '.csv', '.log',
    '.rb', '.go', '.rs', '.php', '.svg', '.properties', '.env',
    '.gitignore', '.prompt', '.text', '.bat', '.ps1',
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
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlg) {
          Directory d;
          try {
            d = Directory(cur);
          } catch (_) {
            d = Directory('/');
          }
          List<FileSystemEntity> dirs;
          try {
            dirs = d.listSync().whereType<Directory>().toList()
              ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
          } catch (_) {
            dirs = [];
          }
          return AlertDialog(
            title: Text(cur, maxLines: 1, overflow: TextOverflow.ellipsis),
            content: SizedBox(
              width: 360,
              height: 380,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      label: const Text('上一级'),
                      onPressed: () {
                        final p = Directory(cur).parent.path;
                        if (p != cur) {
                          setDlg(() => cur = p);
                        }
                      },
                    ),
                  ),
                  Expanded(
                    child: dirs.isEmpty
                        ? const Center(child: Text('没有子文件夹'))
                        : ListView.builder(
                            itemCount: dirs.length,
                            itemBuilder: (_, i) => ListTile(
                              dense: true,
                              leading: const Icon(Icons.folder_outlined, size: 18),
                              title: Text(
                                dirs[i].path.split(Platform.pathSeparator).last,
                                style: const TextStyle(fontSize: 14),
                              ),
                              onTap: () => setDlg(() => cur = dirs[i].path),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dctx, cur),
                child: const Text('进入此文件夹'),
              ),
            ],
          );
        },
      ),
    );
  }
}
