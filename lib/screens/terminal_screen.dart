import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../services/embedded_shell.dart';
import '../services/termux_runtime.dart';
import '../widgets/ios_style.dart';
import '../widgets/terminal_pane.dart';
import '../widgets/traffic_lights_button.dart';

/// 主页终端 Tab：命令走内嵌 Alpine proot（init-host），Windows 走设置后端。
class TerminalScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const TerminalScreen({super.key, required this.shiyi});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  final _session = TerminalSession.shared;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _ready = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_boot());
  }

  @override
  void dispose() {
    // 两端共用 Alpine，页面销毁 / 切引擎都不发 Ctrl+C，只等停止按钮。
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _jumpBottom();
  }

  Future<void> _boot() async {
    await _session.ensureCwd();
    if (Platform.isAndroid) {
      final installed = await TermuxRuntime.isInstalled();
      if (!installed) {
        _status = '正在准备 Alpine / proot 环境…';
        if (mounted) setState(() {});
        try {
          await TermuxRuntime.ensureInstalled();
        } catch (e) {
          _status = '内嵌终端不可用：$e';
          if (mounted) setState(() {});
          return;
        }
      }
      _status = 'Alpine Linux · proot（init-host）';
    } else {
      _status = 'Windows · ${_session.cwd}';
    }
    _ready = true;
    _session.log.writeln(_banner());
    if (mounted) setState(() {});
  }

  String _banner() {
    if (Platform.isAndroid) {
      return '拾忆内嵌终端（Alpine / proot）\n'
          '命令经 init-host 在沙箱内执行，不是系统 Termux。\n'
          '宿主工作目录 ${_session.cwd}\n'
          '点画面输入，回车执行。停止按钮注入 Ctrl+C。\n';
    }
    return '拾忆终端\n工作目录 ${_session.cwd}\n';
  }

  Future<void> _run() async {
    final cmd = _input.text;
    if (!_ready) return;
    if (cmd.trim().isEmpty && !_session.busy) return;
    _input.clear();
    await _session.submit(
      cmd,
      terminalBackend: widget.shiyi.settings.terminalBackend,
      onUpdate: () {
        if (mounted) {
          setState(() {});
          _jumpBottom();
        }
      },
    );
    if (mounted) _jumpBottom();
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      jumpTerminalToLatest(_scroll);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyC &&
        HardwareKeyboard.instance.isControlPressed) {
      _session.interrupt();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF0B0B0D) : const Color(0xFF1C1C1E);
    return CupertinoTheme(
      data: iosCupertinoTheme(context),
      child: Scaffold(
        backgroundColor: iosGroupedBackground(context),
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          leadingWidth: 72,
          leading: Platform.isWindows
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: ListenableBuilder(
                    listenable: widget.shiyi,
                    builder: (context, _) => TrafficLightsButton(
                      tooltip: '',
                      busy: widget.shiyi.isBusy,
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
          title: const Text(
            '终端',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          actions: [
            if (_session.busy)
              CupertinoButton(
                padding: const EdgeInsets.all(8),
                onPressed: () {
                  _session.interrupt();
                  if (mounted) setState(() {});
                },
                child: const Icon(
                  CupertinoIcons.stop_circle,
                  color: CupertinoColors.systemRed,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CupertinoButton(
                padding: const EdgeInsets.all(8),
                onPressed: () {
                  setState(() {
                    _session.clear();
                    _session.log.writeln(_banner());
                  });
                },
                child: const Icon(CupertinoIcons.trash),
              ),
            ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _status!,
                      style: TextStyle(
                        fontSize: 12,
                        color: dark
                            ? CupertinoColors.white.withValues(alpha: .55)
                            : CupertinoColors.black.withValues(alpha: .5),
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Focus(
                    onKeyEvent: _onKey,
                    child: TerminalPane(
                      log: _session.log.toString(),
                      controller: _input,
                      focusNode: _focus,
                      scrollController: _scroll,
                      ready: _ready,
                      busy: _session.busy,
                      onSubmit: _run,
                      onInterrupt: _session.interrupt,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
