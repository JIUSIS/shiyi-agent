import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/file_workspace.dart';

/// 侧边栏「日志」页：实时查看智能体错误日志（默认 /storage/emulated/0/agent/logs/error.log）。
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  String _content = '';
  String _path = '';
  bool _autoRefresh = true;
  bool _reading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_autoRefresh && mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_reading) return;
    _reading = true;
    try {
      final dir = await FileWorkspace.current();
      final file = File('$dir/logs/error.log');
      final exists = await file.exists();
      final text = exists ? await file.readAsString() : '';
      if (!mounted) return;
      if (silent && text == _content) return;
      setState(() {
        _path = file.path;
        _content = text;
      });
    } catch (_) {
      if (mounted) setState(() => _content = '（读取日志失败）');
    } finally {
      _reading = false;
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定清空错误日志吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final file = File(_path);
      if (await file.exists()) {
        await file.writeAsString('');
      }
      await _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _content
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList()
        .reversed
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(),
          ),
          IconButton(
            tooltip: _autoRefresh ? '自动刷新：开' : '自动刷新：关',
            icon: Icon(
              _autoRefresh
                  ? Icons.autorenew
                  : Icons.autorenew_outlined,
              color: _autoRefresh ? theme.colorScheme.primary : null,
            ),
            onPressed: () => setState(() => _autoRefresh = !_autoRefresh),
          ),
          IconButton(
            tooltip: '清空日志',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              _path.isEmpty ? '日志文件路径加载中…' : _path,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      '暂无错误日志\n生成错误或工具错误会自动记录到这里',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemCount: lines.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        lines[i],
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.4,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}