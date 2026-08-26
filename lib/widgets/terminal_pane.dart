import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 命令输出偏灰绿，输入浅蓝，错误红，警告黄；命令行再按 token 分色。
const Color terminalOutputColor = Color(0xFF9BBB9B);
const Color terminalInputColor = Color(0xFF7DD3FC);
const Color terminalErrorColor = Color(0xFFFF6B6B);
const Color terminalWarningColor = Color(0xFFFFD166);
const Color terminalCommandColor = Color(0xFF86EFAC);
const Color terminalFlagColor = Color(0xFFD8B4FE);
const Color terminalStringColor = Color(0xFFFDBA74);
const Color terminalPathColor = Color(0xFF93C5FD);
const Color terminalGhostColor = Color(0x66FFFFFF);

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

/// 日志里 `$ 命令` 按 token 分色，错误红、警告黄，其余输出用输出色。
List<TerminalColorSpan> formatTerminalSpans({
  required String log,
  required String draft,
  bool cursorOn = false,
  String? suggestion,
  Color outputColor = terminalOutputColor,
  Color inputColor = terminalInputColor,
  Color errorColor = terminalErrorColor,
  Color warningColor = terminalWarningColor,
  Color commandColor = terminalCommandColor,
  Color flagColor = terminalFlagColor,
  Color stringColor = terminalStringColor,
  Color pathColor = terminalPathColor,
  Color ghostColor = terminalGhostColor,
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
    if (classifyTerminalLine(line) == TerminalLineKind.input) {
      final hasNl = line.endsWith('\n');
      final cmd = hasNl
          ? line.substring(2, line.length - 1)
          : line.substring(2);
      for (final s in formatCommandColorSpans(
        cmd,
        prompt: true,
        inputColor: inputColor,
        commandColor: commandColor,
        flagColor: flagColor,
        stringColor: stringColor,
        pathColor: pathColor,
      )) {
        add(s.text, s.color);
      }
      if (hasNl) {
        add('\n', spans.isNotEmpty ? spans.last.color : inputColor);
      }
    } else {
      add(line, colorOf(classifyTerminalLine(line)));
    }
    start = end;
  }
  for (final s in formatCommandColorSpans(
    draft,
    prompt: true,
    inputColor: inputColor,
    commandColor: commandColor,
    flagColor: flagColor,
    stringColor: stringColor,
    pathColor: pathColor,
  )) {
    add(s.text, s.color);
  }
  if (suggestion != null) {
    final ghost = terminalGhostSuffix(draft: draft, suggestion: suggestion);
    if (ghost.isNotEmpty) add(ghost, ghostColor);
  }
  if (cursor.isNotEmpty) {
    add(cursor, spans.isNotEmpty ? spans.last.color : inputColor);
  }
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

const double kTerminalFontSize = 13;
const double kMinTerminalFontSize = 1;
const double kMaxTerminalFontSize = 28;

const List<String> kTerminalFontFallbacks = [
  'NotoSansSC',
  'Noto Sans CJK SC',
  'sans-serif',
  'DroidSansFallback',
  'Noto Sans',
  'PingFang SC',
  'Microsoft YaHei',
];

TextStyle terminalTextStyle(double fontSize) => TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: kTerminalFontFallbacks,
  fontSize: fontSize,
  height: 1.35,
);

const List<String> kTerminalBuiltinCommands = [
  'apk',
  'apk add',
  'apk del',
  'apk update',
  'apk search',
  'apk info',
  'ls',
  'cd',
  'pwd',
  'cat',
  'echo',
  'clear',
  'curl',
  'wget',
  'mkdir',
  'rm',
  'cp',
  'mv',
  'chmod',
  'grep',
  'find',
  'head',
  'tail',
  'git',
  'git status',
  'git log',
  'git diff',
  'git add',
  'git commit',
  'git push',
  'git pull',
  'node',
  'npm',
  'npm install',
  'python',
  'python3',
  'uname',
  'whoami',
  'ps',
  'kill',
  'tar',
  'unzip',
  'bash',
  'sh',
  'nano',
];

List<String> extractTerminalHistoryCommands(String log) {
  final out = <String>[];
  for (final line in log.split('\n')) {
    if (!line.startsWith(r'$ ')) continue;
    final cmd = line.substring(2).trimRight();
    if (cmd.isNotEmpty) out.add(cmd);
  }
  return out;
}

String? suggestTerminalCommand({
  required String draft,
  List<String> history = const [],
  List<String> builtins = kTerminalBuiltinCommands,
}) {
  if (draft.isEmpty) return null;
  for (final cmd in history.reversed) {
    if (cmd.startsWith(draft) && cmd != draft) return cmd;
  }
  if (builtins.contains(draft)) return null;
  for (final cmd in builtins) {
    if (cmd.startsWith(draft) && cmd != draft) return cmd;
  }
  return null;
}

String terminalGhostSuffix({
  required String draft,
  required String suggestion,
}) {
  if (suggestion == draft || !suggestion.startsWith(draft)) return '';
  return suggestion.substring(draft.length);
}

List<TerminalColorSpan> formatCommandColorSpans(
  String command, {
  bool prompt = false,
  Color inputColor = terminalInputColor,
  Color commandColor = terminalCommandColor,
  Color flagColor = terminalFlagColor,
  Color stringColor = terminalStringColor,
  Color pathColor = terminalPathColor,
}) {
  final spans = <TerminalColorSpan>[];
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

  if (prompt) add(r'$ ', inputColor);
  var i = 0;
  var firstWord = true;
  while (i < command.length) {
    final ch = command[i];
    if (ch == ' ' || ch == '\t') {
      final start = i;
      while (i < command.length && (command[i] == ' ' || command[i] == '\t')) {
        i++;
      }
      add(command.substring(start, i), inputColor);
      continue;
    }
    if (ch == '"' || ch == "'") {
      final quote = ch;
      final start = i;
      i++;
      while (i < command.length && command[i] != quote) {
        i++;
      }
      if (i < command.length) i++;
      add(command.substring(start, i), stringColor);
      firstWord = false;
      continue;
    }
    final start = i;
    while (i < command.length && command[i] != ' ' && command[i] != '\t') {
      i++;
    }
    final token = command.substring(start, i);
    final color = firstWord
        ? commandColor
        : token.startsWith('-')
        ? flagColor
        : (token.startsWith('/') ||
              token.startsWith('~/') ||
              token.startsWith('./') ||
              token.contains('/') ||
              token.contains(r'\'))
        ? pathColor
        : inputColor;
    add(token, color);
    firstWord = false;
  }
  return spans;
}

double clampTerminalFontSize(double size) =>
    size.clamp(kMinTerminalFontSize, kMaxTerminalFontSize).toDouble();

double scaledTerminalFontSize({required double base, required double scale}) =>
    clampTerminalFontSize(base * scale);

/// 滑动看历史或双指缩放不弹输入法，只有轻点才弹。
bool shouldOpenKeyboardOnPointer({required bool moved, bool scaled = false}) =>
    !moved && !scaled;

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
  static const suggestKey = ValueKey('terminal-suggest');

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
  bool _pinching = false;
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double _pinchStartFont = kTerminalFontSize;
  double _fontSize = kTerminalFontSize;
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

  double _pointerDistance() {
    final pts = _pointers.values.toList();
    if (pts.length < 2) return 0;
    return (pts[0] - pts[1]).distance;
  }

  void _applyPinchScale(double scale) {
    final next = scaledTerminalFontSize(base: _pinchStartFont, scale: scale);
    if (next == _fontSize && _pinching) return;
    setState(() {
      _pinching = true;
      _fontSize = next;
    });
  }

  void _endPinch() {
    if (!_pinching) return;
    setState(() => _pinching = false);
  }

  void _trackPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 1) {
      _pointerDown = e.position;
      _pointerMoved = false;
      _pinching = false;
    }
    if (_pointers.length >= 2) {
      _pinchStartFont = _fontSize;
      _pinchStartDistance = _pointerDistance();
      if (!_pinching) setState(() => _pinching = true);
    }
  }

  void _trackPointerMove(PointerMoveEvent e) {
    _pointers[e.pointer] = e.position;
    final startDist = _pinchStartDistance;
    if (_pinching &&
        _pointers.length >= 2 &&
        startDist != null &&
        startDist > 0) {
      _applyPinchScale(_pointerDistance() / startDist);
      return;
    }
    final start = _pointerDown;
    if (start == null) return;
    if ((e.position - start).distance > 8) _pointerMoved = true;
  }

  void _trackPointerUp(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length < 2) _pinchStartDistance = null;
    if (_pointers.isNotEmpty) return;
    final moved = _pointerMoved;
    final scaled = _pinching;
    _pointerDown = null;
    _pointerMoved = false;
    _endPinch();
    if (!widget.ready) return;
    if (!shouldOpenKeyboardOnPointer(moved: moved, scaled: scaled)) return;
    unawaited(requestTerminalKeyboard(widget.focusNode));
    _stickLatest();
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _pinchStartFont = _fontSize;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if ((e.scale - 1).abs() < 0.02) return;
    _applyPinchScale(e.scale);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent e) {
    _endPinch();
  }

  void _acceptSuggestion(String suggestion) {
    widget.controller.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    _stickLatest();
  }

  @override
  Widget build(BuildContext context) {
    final base = terminalTextStyle(_fontSize);
    Color tone(Color c) => widget.busy ? c.withValues(alpha: 0.85) : c;
    final out = tone(terminalOutputColor);
    final inp = tone(terminalInputColor);
    final err = tone(terminalErrorColor);
    final warn = tone(terminalWarningColor);
    return Listener(
      key: TerminalPane.paneKey,
      behavior: HitTestBehavior.translucent,
      onPointerDown: _trackPointerDown,
      onPointerMove: _trackPointerMove,
      onPointerUp: (e) => _trackPointerUp(e.pointer),
      onPointerCancel: (e) => _trackPointerUp(e.pointer),
      onPointerPanZoomStart: _onPanZoomStart,
      onPointerPanZoomUpdate: _onPanZoomUpdate,
      onPointerPanZoomEnd: _onPanZoomEnd,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyC, control: true):
              widget.onInterrupt,
          const SingleActivator(LogicalKeyboardKey.tab): () {
            final suggestion = suggestTerminalCommand(
              draft: widget.controller.text,
              history: extractTerminalHistoryCommands(widget.log),
            );
            if (suggestion != null) _acceptSuggestion(suggestion);
          },
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: SingleChildScrollView(
                controller: widget.scrollController,
                physics: _pinching
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: widget.controller,
                    builder: (context, value, _) {
                      final suggestion = suggestTerminalCommand(
                        draft: value.text,
                        history: extractTerminalHistoryCommands(widget.log),
                      );
                      final spans = formatTerminalSpans(
                        log: widget.log,
                        draft: value.text,
                        cursorOn: widget.focusNode.hasFocus && _cursorOn,
                        suggestion: suggestion,
                        outputColor: out,
                        inputColor: inp,
                        errorColor: err,
                        warningColor: warn,
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
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
                          ),
                          if (suggestion != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: GestureDetector(
                                key: TerminalPane.suggestKey,
                                onTap: () => _acceptSuggestion(suggestion),
                                child: Text(
                                  suggestion,
                                  style: base.copyWith(
                                    color: terminalGhostColor,
                                    fontSize: _fontSize,
                                  ),
                                ),
                              ),
                            ),
                        ],
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
                  style: terminalTextStyle(
                    _fontSize,
                  ).copyWith(color: Colors.transparent),
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
