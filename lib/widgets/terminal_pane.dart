import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 命令输出偏灰绿，输入浅蓝，错误红，警告黄。
const Color terminalOutputColor = Color(0xFF9BBB9B);
const Color terminalInputColor = Color(0xFF7DD3FC);
const Color terminalErrorColor = Color(0xFFFF6B6B);
const Color terminalWarningColor = Color(0xFFFFD166);

enum TerminalLineKind { input, output, error, warning }

class TerminalColorSpan {
  final String text;
  final Color color;
  const TerminalColorSpan(this.text, this.color);
}

final _errorLine = RegExp(
  r'(error|traceback|exception|fatal|panic|failed|failure|'
  r'command not found|permission denied|no such file|'
  r'启动失败|错误)',
  caseSensitive: false,
);
final _warningLine = RegExp(
  r'(warning|warn|deprecated|警告)',
  caseSensitive: false,
);
final _failedExit = RegExp(r'^\[exit ([1-9]\d*)\]\s*$');

/// `$ 命令` 是输入；含 error 标红，含 warning 标黄，其余是正常输出。
TerminalLineKind classifyTerminalLine(String line) {
  final text = line.endsWith('\n') ? line.substring(0, line.length - 1) : line;
  if (text.startsWith(r'$ ')) return TerminalLineKind.input;
  if (_failedExit.hasMatch(text) || _errorLine.hasMatch(text)) {
    return TerminalLineKind.error;
  }
  if (_warningLine.hasMatch(text)) return TerminalLineKind.warning;
  return TerminalLineKind.output;
}

/// 把已输出日志和当前草稿拼成终端画面（没有独立提示框）。
/// [cursorOn] 为 true 时在草稿末尾画块状光标，空格也能看见。
String formatTerminalView({
  required String log,
  required String draft,
  bool cursorOn = false,
}) {
  final body = log.endsWith('\n') || log.isEmpty ? log : '$log\n';
  final cursor = cursorOn ? '█' : '';
  return '$body\$ $draft$cursor';
}

/// 日志里 `$ 命令` 和当前草稿用输入色，错误红、警告黄，其余输出用输出色。
List<TerminalColorSpan> formatTerminalSpans({
  required String log,
  required String draft,
  bool cursorOn = false,
  Color outputColor = terminalOutputColor,
  Color inputColor = terminalInputColor,
  Color errorColor = terminalErrorColor,
  Color warningColor = terminalWarningColor,
}) {
  final body = log.endsWith('\n') || log.isEmpty ? log : '$log\n';
  final cursor = cursorOn ? '█' : '';
  final spans = <TerminalColorSpan>[];

  Color colorOf(TerminalLineKind kind) => switch (kind) {
    TerminalLineKind.input => inputColor,
    TerminalLineKind.output => outputColor,
    TerminalLineKind.error => errorColor,
    TerminalLineKind.warning => warningColor,
  };

  void add(String text, Color color) {
    if (text.isEmpty) return;
    if (spans.isNotEmpty && spans.last.color == color) {
      spans[spans.length - 1] = TerminalColorSpan(
        '${spans.last.text}$text',
        color,
      );
      return;
    }
    spans.add(TerminalColorSpan(text, color));
  }

  var start = 0;
  while (start < body.length) {
    final nl = body.indexOf('\n', start);
    final end = nl < 0 ? body.length : nl + 1;
    final line = body.substring(start, end);
    add(line, colorOf(classifyTerminalLine(line)));
    start = end;
  }
  add('\$ $draft$cursor', inputColor);
  return spans;
}

/// 输入法弹出、输出增长时：有滚动客户端就贴底看最新。
bool shouldStickTerminalToLatest({required bool hasClients}) => hasClients;

void jumpTerminalToLatest(ScrollController scroll) {
  if (!shouldStickTerminalToLatest(hasClients: scroll.hasClients)) return;
  final max = scroll.position.maxScrollExtent;
  if (scroll.offset != max) scroll.jumpTo(max);
}

/// 已聚焦时不要先松焦点再 show，否则回车会闪键盘。
bool shouldRefocusTerminalKeyboard({required bool hasFocus}) => !hasFocus;

/// 滑动看历史不弹输入法，只有轻点才弹。
bool shouldOpenKeyboardOnPointer({required bool moved}) => !moved;

/// 部分输入法会把「字母 + 空格 + /」收成「字母/」。把被吃掉的空格补回来。
String restoreEatenSpaceBeforeSlash({
  required String previous,
  required String next,
}) {
  if (!next.endsWith('/')) return next;
  final stem = next.substring(0, next.length - 1);
  if (!previous.startsWith(stem)) return next;
  final eaten = previous.substring(stem.length);
  if (eaten.isEmpty || eaten.trim().isNotEmpty) return next;
  return '$stem$eaten/';
}

/// 提交态下补回被输入法吃掉的斜杠前空格；组字中不改。
class RestoreSpaceBeforeSlashFormatter extends TextInputFormatter {
  const RestoreSpaceBeforeSlashFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.composing.isValid) return newValue;
    final restored = restoreEatenSpaceBeforeSlash(
      previous: oldValue.text,
      next: newValue.text,
    );
    if (restored == newValue.text) return newValue;
    final delta = restored.length - newValue.text.length;
    return newValue.copyWith(
      text: restored,
      selection: TextSelection.collapsed(
        offset: (newValue.selection.baseOffset + delta).clamp(
          0,
          restored.length,
        ),
      ),
    );
  }
}

/// 点画面弹出输入法：已聚焦只补 show；未聚焦才 requestFocus。
Future<void> requestTerminalKeyboard(FocusNode focus) async {
  if (!focus.canRequestFocus) return;
  if (shouldRefocusTerminalKeyboard(hasFocus: focus.hasFocus)) {
    focus.requestFocus();
  }
  try {
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  } catch (_) {}
}

/// 点终端画面就能输入：日志即画面，IME 透明叠在上面。
class TerminalPane extends StatefulWidget {
  static const paneKey = ValueKey('terminal-pane');
  static const imeKey = ValueKey('terminal-ime');

  final String log;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final bool ready;
  final bool busy;
  final VoidCallback onSubmit;
  final VoidCallback onInterrupt;

  const TerminalPane({
    super.key,
    required this.log,
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.ready,
    required this.busy,
    required this.onSubmit,
    required this.onInterrupt,
  });

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane>
    with WidgetsBindingObserver {
  Offset? _pointerDown;
  bool _pointerMoved = false;
  Timer? _cursorTimer;
  bool _cursorOn = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onDraftChanged);
    widget.focusNode.addListener(_onFocusChanged);
    _cursorTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!mounted || !widget.focusNode.hasFocus) return;
      setState(() => _cursorOn = !_cursorOn);
    });
  }

  @override
  void dispose() {
    _cursorTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onDraftChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onDraftChanged);
      widget.controller.addListener(_onDraftChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
    if (oldWidget.log != widget.log && widget.focusNode.hasFocus) {
      _stickLatest();
    }
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _cursorOn = widget.focusNode.hasFocus);
  }

  void _onDraftChanged() {
    if (!widget.focusNode.hasFocus) return;
    setState(() => _cursorOn = true);
    _stickLatest();
  }

  @override
  void didChangeMetrics() {
    if (widget.focusNode.hasFocus) _stickLatest();
  }

  void _stickLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      jumpTerminalToLatest(widget.scrollController);
    });
  }

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35);
    Color tone(Color c) => widget.busy ? c.withValues(alpha: 0.85) : c;
    final out = tone(terminalOutputColor);
    final inp = tone(terminalInputColor);
    final err = tone(terminalErrorColor);
    final warn = tone(terminalWarningColor);
    return Listener(
      key: TerminalPane.paneKey,
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _pointerDown = e.position;
        _pointerMoved = false;
      },
      onPointerMove: (e) {
        final start = _pointerDown;
        if (start == null) return;
        if ((e.position - start).distance > 8) _pointerMoved = true;
      },
      onPointerUp: (_) {
        if (!widget.ready) return;
        if (!shouldOpenKeyboardOnPointer(moved: _pointerMoved)) return;
        unawaited(requestTerminalKeyboard(widget.focusNode));
        _stickLatest();
      },
      onPointerCancel: (_) {
        _pointerDown = null;
        _pointerMoved = false;
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyC, control: true):
              widget.onInterrupt,
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: SingleChildScrollView(
                controller: widget.scrollController,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: widget.controller,
                    builder: (context, value, _) {
                      final spans = formatTerminalSpans(
                        log: widget.log,
                        draft: value.text,
                        cursorOn: widget.focusNode.hasFocus && _cursorOn,
                        outputColor: out,
                        inputColor: inp,
                        errorColor: err,
                        warningColor: warn,
                      );
                      return Text.rich(
                        TextSpan(
                          style: base,
                          children: [
                            for (final s in spans)
                              TextSpan(
                                text: s.text,
                                style: TextStyle(color: s.color),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: TextField(
                  key: TerminalPane.imeKey,
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  enabled: widget.ready,
                  readOnly: false,
                  autofocus: false,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableInteractiveSelection: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  showCursor: false,
                  maxLines: null,
                  expands: true,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.send,
                  inputFormatters: const [RestoreSpaceBeforeSlashFormatter()],
                  onSubmitted: (_) => widget.onSubmit(),
                  onTap: _stickLatest,
                  onChanged: (_) => _stickLatest(),
                  style: const TextStyle(
                    color: Colors.transparent,
                    fontSize: 13,
                    height: 1.35,
                  ),
                  cursorColor: Colors.transparent,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    filled: false,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
