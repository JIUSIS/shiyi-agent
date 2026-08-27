import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show Material, MaterialType, Theme, Tooltip;
import 'package:flutter/services.dart';

import '../services/file_workspace.dart';
import '../services/runtime_logger.dart';
import '../widgets/ios_style.dart';

/// 设置页内「日志」页：查看 App 全链路运行审计。
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _logger = RuntimeLogger.instance;
  final _queryController = TextEditingController();
  List<RuntimeLogEntry> _entries = const [];
  String _path = '';
  String _module = '';
  String _level = 'all';
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_reading) return;
    _reading = true;
    try {
      final entries = await _logger.read(limit: 1000);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _path = _logger.path ?? '';
      });
    } catch (_) {
      if (mounted) setState(() => _entries = const []);
    } finally {
      _reading = false;
    }
  }

  List<RuntimeLogEntry> get _filtered {
    final query = _queryController.text.trim().toLowerCase();
    return _entries
        .where((entry) {
          if (_module.isNotEmpty && entry.module != _module) return false;
          if (_level != 'all' && entry.level != _level) return false;
          if (query.isNotEmpty &&
              !entry.oneLine.toLowerCase().contains(query)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  Future<void> _clear() async {
    final ok = await showIosFadeDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('清空运行日志'),
        content: const Text('会清空结构化运行审计日志，保留应用功能不变。'),
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
    await _logger.clear();
    try {
      final dir = await FileWorkspace.current();
      final old = File('$dir/logs/error.log');
      if (await old.exists()) await old.writeAsString('');
    } catch (_) {}
    await _load();
  }

  Future<void> _copy(RuntimeLogEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.oneLine));
    if (!mounted) return;
    await showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('已复制'),
        content: const Text('日志详情已复制到剪贴板。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showDetails(RuntimeLogEntry entry) {
    showIosFadeDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('${entry.module} · ${entry.event}'),
        content: SingleChildScrollView(
          child: Text(
            entry.oneLine,
            textAlign: TextAlign.left,
            style: const TextStyle(fontSize: 12, height: 1.45),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () {
              Navigator.pop(ctx);
              _copy(entry);
            },
            child: const Text('复制'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _levelButton(String value, String label) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    onPressed: () => setState(() => _level = value),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12,
        color: _level == value
            ? CupertinoColors.activeBlue
            : CupertinoColors.secondaryLabel,
        fontWeight: _level == value ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final entries = _filtered;
    final modules =
        _entries
            .map((e) => e.module)
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final errors = _entries.where((e) => e.level == 'error').length;
    final warnings = _entries.where((e) => e.level == 'warn').length;
    return CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: Material(
        type: MaterialType.transparency,
        child: CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: const Text('运行日志'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: '手动刷新',
                  child: CupertinoButton(
                    padding: const EdgeInsets.all(8),
                    onPressed: _load,
                    child: const Icon(CupertinoIcons.refresh),
                  ),
                ),
                Tooltip(
                  message: '删除日志',
                  child: CupertinoButton(
                    padding: const EdgeInsets.all(8),
                    onPressed: _clear,
                    child: const Icon(
                      CupertinoIcons.trash,
                      color: CupertinoColors.systemRed,
                    ),
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
                  child: CupertinoSearchTextField(
                    controller: _queryController,
                    placeholder: '搜索事件、模块、会话、错误或详情',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      _levelButton('all', '全部'),
                      _levelButton('info', '信息'),
                      _levelButton('warn', '警告 $warnings'),
                      _levelButton('error', '错误 $errors'),
                      const Spacer(),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        onPressed: () => setState(() => _module = ''),
                        child: Text(
                          _module.isEmpty ? '全部模块' : _module,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                if (modules.isNotEmpty)
                  SizedBox(
                    height: 32,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final module in modules)
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            onPressed: () => setState(() => _module = module),
                            child: Text(
                              module,
                              style: TextStyle(
                                fontSize: 12,
                                color: _module == module
                                    ? CupertinoColors.activeBlue
                                    : CupertinoColors.secondaryLabel,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    _path.isEmpty ? '结构化日志路径加载中…' : _path,
                    style: const TextStyle(
                      fontSize: 11,
                      color: CupertinoColors.secondaryLabel,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Text(
                            _entries.isEmpty ? '暂无运行日志' : '没有匹配的运行日志',
                            style: const TextStyle(
                              fontSize: 14,
                              color: CupertinoColors.secondaryLabel,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemCount: entries.length,
                          itemBuilder: (context, i) {
                            final entry = entries[i];
                            final color = entry.level == 'error'
                                ? CupertinoColors.systemRed
                                : entry.level == 'warn'
                                ? CupertinoColors.systemOrange
                                : CupertinoColors.activeBlue;
                            return CupertinoListTile(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              leading: Icon(
                                CupertinoIcons.circle_fill,
                                size: 8,
                                color: color,
                              ),
                              title: Text(
                                '${entry.module} · ${entry.event}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: dark
                                      ? CupertinoColors.white
                                      : CupertinoColors.black,
                                ),
                              ),
                              subtitle: Text(
                                '${entry.timestamp}  ${entry.result.isEmpty ? '' : entry.result} ${entry.durationMs == null ? '' : '${entry.durationMs}ms'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: CupertinoColors.secondaryLabel,
                                ),
                              ),
                              onTap: () => _showDetails(entry),
                            );
                          },
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
