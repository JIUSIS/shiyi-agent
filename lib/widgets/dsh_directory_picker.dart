import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/dsh_api.dart';
import 'ios_style.dart';

/// DSH 远程/局域网工作区目录选择器。
///
/// 远端不能调用手机的系统文件选择器，目录必须通过 DSH 主机 API 浏览。
Future<String?> pickDshHostDirectory(
  BuildContext context, {
  required DshApiClient api,
  String initialPath = '',
}) {
  return showIosFadeDialog<String>(
    context: context,
    builder: (_) => _DshHostDirectoryPicker(api: api, initialPath: initialPath),
  );
}

/// 取得当前 DSH 主机默认工作目录，不能回退到手机的 agent 目录。
Future<String> dshHostDefaultDirectory(DshApiClient api) async {
  try {
    final host = await api.hostDescribe();
    final path = host.cwd.trim().isNotEmpty ? host.cwd : host.home;
    if (path.trim().isNotEmpty) return path.trim();
  } catch (_) {
    // 旧版 DSH 可能没有 host.describe，继续用目录接口探测。
  }
  final listing = await api.directoryListing();
  return (listing.path.trim().isNotEmpty ? listing.path : listing.home).trim();
}

class _DshHostDirectoryPicker extends StatefulWidget {
  final DshApiClient api;
  final String initialPath;

  const _DshHostDirectoryPicker({required this.api, required this.initialPath});

  @override
  State<_DshHostDirectoryPicker> createState() =>
      _DshHostDirectoryPickerState();
}

class _DshHostDirectoryPickerState extends State<_DshHostDirectoryPicker> {
  String _path = '';
  String _platform = '';
  String _error = '';
  List<DshDirEntry> _items = const [];
  List<DshDirEntry> _roots = const [];
  final List<String> _history = <String>[];
  bool _loading = true;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInitial());
  }

  Future<void> _loadInitial() async {
    var path = widget.initialPath.trim();
    try {
      final host = await widget.api.hostDescribe();
      _platform = host.platform;
      if (path.isEmpty) path = host.cwd.trim();
      if (path.isEmpty) path = host.home.trim();
    } catch (_) {
      // directoryListing() 仍可提供 path/home，兼容旧版 DSH。
    }
    try {
      final listing = await widget.api.directoryListing(
        path.isEmpty ? null : path,
      );
      if (path.isEmpty) {
        path = listing.path.trim().isNotEmpty
            ? listing.path.trim()
            : listing.home.trim();
      }
      final roots = await widget.api.scanRootDirectories(
        platform: _platform,
        pathHint: listing.path.isNotEmpty ? listing.path : path,
      );
      if (!mounted) return;
      setState(() {
        _roots = roots;
        _apply(listing, fallbackPath: path);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadPath(String path, {bool pushHistory = true}) async {
    final next = path.trim();
    if (next.isEmpty) return;
    final epoch = ++_epoch;
    if (pushHistory && _path.isNotEmpty && _path != next) {
      _history.add(_path);
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final listing = await widget.api.directoryListing(next);
      if (!mounted || epoch != _epoch) return;
      setState(() => _apply(listing, fallbackPath: next));
    } catch (e) {
      if (!mounted || epoch != _epoch) return;
      if (pushHistory && _history.isNotEmpty && _history.last == _path) {
        _history.removeLast();
      }
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _apply(DshDirectoryListing listing, {required String fallbackPath}) {
    _path = listing.path.trim().isNotEmpty ? listing.path.trim() : fallbackPath;
    _items = listing.entries.where((e) => e.isDirectory).toList();
    _loading = false;
    _error = '';
  }

  Future<void> _showRoots() async {
    if (_roots.isEmpty || !mounted) return;
    final selected = await showIosFadeModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('选择电脑盘符'),
        actions: [
          for (final root in _roots)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, root.path),
              child: Text(root.name.isEmpty ? root.path : root.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected == null || selected == _path) return;
    _history.clear();
    await _loadPath(selected, pushHistory: false);
  }

  void _goUp() {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    _loadPath(previous, pushHistory: false);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: const Text('选择电脑工作目录'),
      content: SizedBox(
        width: 330,
        height: 390,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Row(
              children: [
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: _history.isEmpty ? null : _goUp,
                  child: const Icon(CupertinoIcons.arrow_up),
                ),
                Expanded(
                  child: Text(
                    _path.isEmpty ? '正在读取电脑目录…' : _path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: _roots.isEmpty ? null : _showRoots,
                  child: const Icon(CupertinoIcons.square_grid_2x2),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _path.isEmpty || _loading
              ? null
              : () => Navigator.pop(context, _path),
          child: const Text('选择此目录'),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Text(
          _error,
          textAlign: TextAlign.center,
          style: const TextStyle(color: CupertinoColors.systemRed),
        ),
      );
    }
    if (_items.isEmpty) return const Center(child: Text('空目录'));
    return CupertinoScrollbar(
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
            onPressed: () => _loadPath(item.path),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.folder_fill,
                  size: 18,
                  color: CupertinoColors.activeBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 14,
                    ),
                  ),
                ),
                const Icon(CupertinoIcons.chevron_right, size: 14),
              ],
            ),
          );
        },
      ),
    );
  }
}
