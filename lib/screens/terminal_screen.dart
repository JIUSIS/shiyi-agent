import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../services/termux_runtime.dart';

/// 终端页：直接在内嵌 Termux（完整 Linux 环境）里执行命令。
class TerminalScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const TerminalScreen({super.key, required this.shiyi});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final TextEditingController _cmd = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<String> _lines = [];
  bool _running = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _checkReady();
  }

  @override
  void dispose() {
    _cmd.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _checkReady() async {
    final ok = await TermuxRuntime.isInstalled();
    if (!mounted) return;
    setState(() => _ready = ok);
    if (!ok) {
      // 后台触发部署，就绪后刷新。
      try {
        await TermuxRuntime.ensureInstalled();
      } catch (_) {}
      if (!mounted) return;
      final ok = await TermuxRuntime.isInstalled();
      if (!mounted) return;
      setState(() => _ready = ok);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _run() async {
    final command = _cmd.text.trim();
    if (command.isEmpty || _running) return;
    if (!_ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('终端环境部署中，请稍候…')),
      );
      return;
    }
    setState(() {
      _running = true;
      _lines.add('\$ $command');
    });
    _cmd.clear();
    _scrollToBottom();
    try {
      final shell = await TermuxRuntime.shellPath();
      final env = await TermuxRuntime.environment();
      final result = await Process.run(
        shell,
        ['-c', command],
        environment: env,
      ).timeout(const Duration(seconds: 120));
      final out = result.stdout.toString().trim();
      final err = result.stderr.toString().trim();
      final buf = StringBuffer();
      if (out.isNotEmpty) buf.write(out);
      if (err.isNotEmpty) buf.write(buf.isEmpty ? err : '\n$err');
      var text = buf.toString();
      if (text.isEmpty) text = '（无输出，退出码 ${result.exitCode}）';
      if (!mounted) return;
      setState(() {
        _lines.add(text);
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lines.add('执行异常: $e');
        _running = false;
      });
    }
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('终端'),
        actions: [
          IconButton(
            tooltip: '清空',
            onPressed: () => setState(_lines.clear),
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.terminal_outlined,
                          size: 56,
                          color: theme.colorScheme.primary.withValues(alpha: .6),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _ready ? '内嵌 Linux 终端（bash / apt / pkg）' : '终端环境部署中…',
                          style: theme.textTheme.bodyMedium!
                              .copyWith(color: theme.hintColor),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(14),
                    itemCount: _lines.length,
                    itemBuilder: (context, i) {
                      final line = _lines[i];
                      final isCmd = line.startsWith('\$ ');
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: SelectableText(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.45,
                            color: isCmd
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer.withValues(alpha: .92),
                border: Border(
                  top: BorderSide(
                    color: theme.dividerColor.withValues(alpha: .4),
                  ),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _cmd,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _run(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        hintText: '输入命令，如 pkg install python',
                        hintStyle: TextStyle(color: theme.hintColor),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  IconButton.filled(
                    onPressed: _running ? null : _run,
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    tooltip: '执行',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
