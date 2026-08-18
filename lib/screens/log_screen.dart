import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, MaterialType, Theme;

import '../services/file_workspace.dart';
import '../widgets/ios_style.dart';

/// 设置页内「日志」页：实时查看智能体错误日志（默认 /storage/emulated/0/agent/logs/error.log）。
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
      // 只读尾部（最多 256KB），避免每次 3 秒轮询全量读大日志文件。
      String text = '';
      if (exists) {
        final len = await file.length();
        const maxRead = 256 * 1024;
        final skip = len > maxRead ? len - maxRead : 0;
        final raf = await file.open();
        try {
          await raf.setPosition(skip);
          final bytes = await raf.read(len - skip);
          text = utf8.decode(bytes, allowMalformed: true);
          if (skip > 0) {
            // 从行边界开始，避免首行半截。
            final idx = text.indexOf('\n');
            if (idx != -1) text = text.substring(idx + 1);
          }
        } finally {
          await raf.close();
        }
      }
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
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定清空错误日志吗？'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lines = _content
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList()
        .reversed
        .toList();
    return CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: Material(
        type: MaterialType.transparency,
        child: CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: const Text('日志'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CupertinoButton(
                  padding: const EdgeInsets.all(8),
                  onPressed: () => _load(),
                  child: const Icon(CupertinoIcons.refresh),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.all(8),
                  onPressed: () => setState(() => _autoRefresh = !_autoRefresh),
                  child: Icon(
                    _autoRefresh
                        ? CupertinoIcons.arrow_2_circlepath
                        : CupertinoIcons.arrow_2_circlepath_circle,
                    color: _autoRefresh
                        ? CupertinoColors.activeBlue
                        : CupertinoColors.secondaryLabel,
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.all(8),
                  onPressed: _clear,
                  child: const Icon(
                    CupertinoIcons.trash,
                    color: CupertinoColors.systemRed,
                  ),
                ),
              ],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    _path.isEmpty ? '日志文件路径加载中…' : _path,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel,
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
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.6,
                              color: CupertinoColors.secondaryLabel,
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
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.4,
                                color: dark
                                    ? CupertinoColors.white.withValues(
                                        alpha: .82,
                                      )
                                    : CupertinoColors.black.withValues(
                                        alpha: .72,
                                      ),
                              ),
                            ),
                          ),
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
