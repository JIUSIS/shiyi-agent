import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path/path.dart' as p;

const _iosBlue = Color(0xFF0A84FF);
const _iosRed = Color(0xFFFF3B30);

LiquidGlassStyle chatLiquidGlassStyle(
  BuildContext context, {
  double cornerRadius = 16,
  Color? tint,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: cornerRadius,
      borderWidth: 1,
      borderColor: Colors.white.withValues(alpha: dark ? .14 : .48),
      lightIntensity: .78,
      lightDirection: 110,
    ),
    appearance: LiquidGlassAppearance(
      color: tint ?? (dark ? const Color(0x403A3A3C) : const Color(0x48FFFFFF)),
      blur: const LiquidGlassBlur(sigmaX: 14, sigmaY: 14),
      saturation: 1.1,
    ),
    refraction: const LiquidGlassRefraction(
      distortion: .05,
      distortionWidth: 18,
      magnification: 1.008,
      chromaticAberration: .001,
    ),
  );
}

/// 拾忆与 DSH 共用的子代理运行状态条。
/// 只负责统一液态玻璃外观，状态文本和可见性由各引擎提供。
class SubagentStatusBar extends StatelessWidget {
  final String text;

  const SubagentStatusBar({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: LiquidGlassLens(
        style: chatLiquidGlassStyle(context, cornerRadius: 10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 思考强度选项。空字符串表示跟随提供商默认，`off` 表示显式关闭。
class ThinkingIntensityOption {
  final String value;
  final String label;

  const ThinkingIntensityOption(this.value, this.label);
}

/// 根据能力映射构建选项列表；兼容 DSH 的 `session.models` 格式和拾忆的
/// `LlmClient.reasoningEffortsForModel` 格式。
List<ThinkingIntensityOption> buildReasoningOptions(
  Map<String, String?> capabilities,
) {
  final options = <ThinkingIntensityOption>[];
  if (capabilities.containsKey('off')) {
    options.add(const ThinkingIntensityOption('', 'Default'));
  }
  if (capabilities.containsKey('low')) {
    options.add(const ThinkingIntensityOption('low', 'Low'));
  }
  if (capabilities.containsKey('medium')) {
    options.add(const ThinkingIntensityOption('medium', 'Medium'));
  }
  if (capabilities.containsKey('high')) {
    options.add(const ThinkingIntensityOption('high', 'High'));
  }
  if (capabilities.containsKey('xhigh')) {
    options.add(const ThinkingIntensityOption('xhigh', 'XHigh'));
  }
  if (capabilities.containsKey('max')) {
    options.add(const ThinkingIntensityOption('max', 'Max'));
  }
  return options;
}

/// 拾忆与 DSH 共用的思考强度选择器；只负责展示和回调，不持有引擎状态。
/// 以 iOS 工具栏控件呈现，从按钮上沿拉开未选项的液态玻璃抽屉。
class ThinkingIntensitySelector extends StatefulWidget {
  final List<ThinkingIntensityOption> options;
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  const ThinkingIntensitySelector({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<ThinkingIntensitySelector> createState() =>
      _ThinkingIntensitySelectorState();
}

class _ThinkingIntensitySelectorState extends State<ThinkingIntensitySelector>
    with SingleTickerProviderStateMixin {
  final _buttonKey = GlobalKey();
  OverlayEntry? _popup;
  Rect _anchor = Rect.zero;
  late final AnimationController _anim;
  late final Animation<double> _reveal;

  static const _gap = 6.0;
  static const _rowPadding = 28.0;
  static const _minMenuWidth = 56.0;
  static const _maxMenuWidth = 160.0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _reveal = CurvedAnimation(
      parent: _anim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  bool get _isOpen => _popup != null;

  void _togglePopup() {
    if (_isOpen) {
      _dismissPopup();
    } else {
      _showPopup();
    }
  }

  Future<void> _dismissPopup() async {
    final entry = _popup;
    if (entry == null) return;
    _popup = null;
    if (mounted) setState(() {});
    if (_anim.value > 0) {
      try {
        await _anim.reverse();
      } catch (_) {}
    }
    entry.remove();
  }

  void _showPopup() {
    if (_drawerOptions.isEmpty) return;
    final box = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    _anchor = box.localToGlobal(Offset.zero) & box.size;
    HapticFeedback.selectionClick();
    _popup = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_popup!);
    _anim.forward(from: 0);
    setState(() {});
  }

  String get _selectedValue {
    if (widget.options.any((item) => item.value == widget.value)) {
      return widget.value;
    }
    return widget.options.first.value;
  }

  List<ThinkingIntensityOption> get _drawerOptions =>
      widget.options.where((item) => item.value != _selectedValue).toList();

  double _menuWidthFor(
    BuildContext context,
    List<ThinkingIntensityOption> items,
  ) {
    final style =
        Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontSize: 15, letterSpacing: -0.24) ??
        const TextStyle(fontSize: 15, letterSpacing: -0.24);
    final painter = TextPainter(textDirection: TextDirection.ltr);
    var maxWidth = 0.0;
    for (final item in items) {
      painter.text = TextSpan(text: item.label, style: style);
      painter.layout();
      if (painter.width > maxWidth) maxWidth = painter.width;
    }
    painter.dispose();
    return (maxWidth + _rowPadding).clamp(_minMenuWidth, _maxMenuWidth);
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final dark = Theme.of(overlayContext).brightness == Brightness.dark;
    final mq = MediaQuery.of(overlayContext);
    final items = _drawerOptions;
    if (items.isEmpty) return const SizedBox.shrink();
    final menuWidth = _menuWidthFor(overlayContext, items);

    // 抽屉贴在按钮上沿，右对齐；空间不够时再夹回安全区内。
    final right = (mq.size.width - _anchor.right).clamp(
      8.0,
      (mq.size.width - menuWidth - 8.0).clamp(8.0, mq.size.width),
    );
    final bottom = (mq.size.height - _anchor.top + _gap).clamp(
      mq.padding.bottom + 8.0,
      mq.size.height - mq.padding.top - 48.0,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissPopup,
          ),
        ),
        Positioned(
          right: right,
          bottom: bottom,
          width: menuWidth,
          child: Material(
            color: Colors.transparent,
            child: SizeTransition(
              sizeFactor: _reveal,
              alignment: Alignment.bottomRight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? .36 : .14),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: LiquidGlassLens(
                  style: chatLiquidGlassStyle(overlayContext, cornerRadius: 14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final item in items)
                          _ThinkingMenuRow(
                            label: item.label,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              _dismissPopup();
                              widget.onChanged(item.value);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _popup?.remove();
    _popup = null;
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final selected = widget.options.any((item) => item.value == widget.value)
        ? widget.value
        : widget.options.first.value;
    final label = widget.options
        .firstWhere((item) => item.value == selected)
        .label;
    final accent = widget.enabled
        ? (_isOpen ? _iosBlue : theme.colorScheme.onSurfaceVariant)
        : theme.disabledColor;

    return Tooltip(
      message: '思考强度',
      child: GestureDetector(
        key: _buttonKey,
        onTap: widget.enabled ? _togglePopup : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: widget.enabled ? 1 : 0.38,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 2, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.24,
                  ),
                ),
                const SizedBox(width: 1),
                Icon(
                  _isOpen
                      ? CupertinoIcons.chevron_down
                      : CupertinoIcons.chevron_up,
                  size: 11,
                  color: accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThinkingMenuRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ThinkingMenuRow({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 36,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w400,
                color: theme.colorScheme.onSurface,
                letterSpacing: -0.24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 会话页共用的思考开关；点亮为开，点灭为关。不持有引擎状态。
class ThinkingToggleButton extends StatelessWidget {
  final bool on;
  final VoidCallback? onPressed;

  const ThinkingToggleButton({
    super.key,
    required this.on,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    final color = !enabled
        ? theme.disabledColor
        : on
        ? _iosBlue
        : theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: on ? '思考已开启' : '思考已关闭',
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: onPressed,
        color: color,
        disabledColor: theme.disabledColor,
        icon: Icon(
          on ? CupertinoIcons.lightbulb_fill : CupertinoIcons.lightbulb,
        ),
      ),
    );
  }
}

/// 会话页共用的紧凑压缩入口；压缩实现仍由各引擎自己的回调负责。
class ChatCompressionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool busy;

  const ChatCompressionButton({
    super.key,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: busy ? '正在压缩上下文' : '压缩上下文',
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: onPressed,
        color: theme.colorScheme.onSurfaceVariant,
        disabledColor: theme.disabledColor,
        icon: busy
            ? const CupertinoActivityIndicator(radius: 7)
            : const Icon(CupertinoIcons.rectangle_compress_vertical),
      ),
    );
  }
}

class LiquidGlassChatComposer extends StatelessWidget {
  final TextEditingController input;
  final bool busy;
  final bool questionActive;
  final bool enterToSend;
  final bool allowSendWhileBusy;
  final List<String> pendingImages;
  final List<String> pendingFiles;
  final VoidCallback onPickAttachment;
  final ValueChanged<int> onRemoveImage;
  final ValueChanged<int> onRemoveFile;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String idleHint;
  final String busyHint;
  final List<ThinkingIntensityOption> thinkingOptions;
  final String thinkingValue;
  final ValueChanged<String>? onThinkingChanged;
  final bool thinkingEnabled;
  final bool thinkingOn;
  final ValueChanged<bool>? onThinkingToggled;
  final VoidCallback? onCompress;
  final bool compressBusy;

  const LiquidGlassChatComposer({
    super.key,
    required this.input,
    required this.busy,
    required this.enterToSend,
    required this.pendingImages,
    required this.pendingFiles,
    required this.onPickAttachment,
    required this.onRemoveImage,
    required this.onRemoveFile,
    required this.onSend,
    required this.onStop,
    this.questionActive = false,
    this.allowSendWhileBusy = false,
    this.idleHint = '输入消息…',
    this.busyHint = 'agent 运行中…',
    this.thinkingOptions = const [],
    this.thinkingValue = '',
    this.onThinkingChanged,
    this.thinkingEnabled = true,
    this.thinkingOn = true,
    this.onThinkingToggled,
    this.onCompress,
    this.compressBusy = false,
  });

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return false;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl) {
      if (enterToSend) {
        final text = input.text;
        final selection = input.selection;
        final start = selection.isValid ? selection.start : text.length;
        final end = selection.isValid ? selection.end : text.length;
        input.text = text.replaceRange(start, end, '\n');
        input.selection = TextSelection.collapsed(offset: start + 1);
      } else {
        onSend();
      }
      return true;
    }
    if (enterToSend) {
      onSend();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Container(
        key: const ValueKey('liquidGlassChatComposer'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .28 : .10),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: LiquidGlassLens(
          style: chatLiquidGlassStyle(
            context,
            cornerRadius: 26,
            tint: dark ? const Color(0x8A1C1C1E) : const Color(0x8AF2F2F7),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (thinkingOptions.isNotEmpty && onThinkingChanged != null ||
                    onThinkingToggled != null ||
                    onCompress != null) ...[
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onCompress != null)
                          ChatCompressionButton(
                            onPressed: onCompress,
                            busy: compressBusy,
                          ),
                        if (onThinkingToggled != null &&
                            thinkingOptions.isNotEmpty)
                          ThinkingToggleButton(
                            on: thinkingOn,
                            onPressed: thinkingEnabled
                                ? () => onThinkingToggled!(!thinkingOn)
                                : null,
                          ),
                        if (thinkingOptions.isNotEmpty &&
                            onThinkingChanged != null)
                          ThinkingIntensitySelector(
                            options: thinkingOptions,
                            value: thinkingValue,
                            onChanged: onThinkingChanged!,
                            enabled: thinkingEnabled,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                if (pendingImages.isNotEmpty || pendingFiles.isNotEmpty) ...[
                  _previewRow(theme),
                  const SizedBox(height: 6),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton(
                        onPressed: onPickAttachment,
                        icon: const Icon(
                          CupertinoIcons.plus_circle,
                          size: 24,
                          color: _iosBlue,
                        ),
                        tooltip: '添加附件',
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: dark
                              ? Colors.black.withValues(alpha: .18)
                              : Colors.white.withValues(alpha: .32),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: dark ? .10 : .42,
                            ),
                          ),
                        ),
                        child: Focus(
                          onKeyEvent: (node, event) => _handleKey(event)
                              ? KeyEventResult.handled
                              : KeyEventResult.ignored,
                          child: TextField(
                            controller: input,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: enterToSend
                                ? TextInputAction.send
                                : TextInputAction.newline,
                            onSubmitted: enterToSend ? (_) => onSend() : null,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 16,
                              height: 1.25,
                            ),
                            decoration: InputDecoration(
                              hintText: questionActive
                                  ? '直接输入你的回答…'
                                  : busy
                                  ? busyHint
                                  : idleHint,
                              hintStyle: TextStyle(color: theme.hintColor),
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: input,
                      builder: (context, value, _) {
                        final hasInput =
                            value.text.trim().isNotEmpty ||
                            pendingImages.isNotEmpty ||
                            pendingFiles.isNotEmpty;
                        return _sendControl(dark: dark, hasInput: hasInput);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sendControl({required bool dark, required bool hasInput}) {
    if (busy) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _roundIconButton(
            onPressed: onStop,
            icon: CupertinoIcons.stop_circle_fill,
            color: _iosRed,
            tooltip: '停止',
          ),
          if (allowSendWhileBusy && hasInput) ...[
            const SizedBox(width: 2),
            _roundIconButton(
              onPressed: onSend,
              icon: CupertinoIcons.arrow_up_circle_fill,
              color: _iosBlue,
              tooltip: questionActive ? '发送回答' : '发送并引导',
            ),
          ],
        ],
      );
    }
    return _roundIconButton(
      onPressed: hasInput ? onSend : null,
      icon: hasInput
          ? CupertinoIcons.arrow_up_circle_fill
          : CupertinoIcons.arrow_up_circle,
      color: hasInput
          ? _iosBlue
          : dark
          ? const Color(0xFF48484A)
          : const Color(0xFFC7C7CC),
      tooltip: questionActive ? '发送回答' : '发送',
    );
  }

  Widget _roundIconButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required Color color,
    required String tooltip,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 32, color: color),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      tooltip: tooltip,
    );
  }

  Widget _previewRow(ThemeData theme) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pendingImages.length + pendingFiles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index < pendingImages.length) {
            final path = pendingImages[index];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(path),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 56,
                      height: 56,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: theme.hintColor,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => onRemoveImage(index),
                    child: _removeBadge(),
                  ),
                ),
              ],
            );
          }
          final fileIndex = index - pendingImages.length;
          final file = pendingFiles[fileIndex];
          return Stack(
            children: [
              Container(
                width: 140,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.insert_drive_file_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.basename(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () => onRemoveFile(fileIndex),
                  child: _removeBadge(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _removeBadge() => Container(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Icon(Icons.close, size: 14, color: Colors.white),
  );
}
