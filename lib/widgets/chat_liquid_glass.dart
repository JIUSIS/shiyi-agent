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

/// 拾忆与 DSH 共用的聊天输入区。视觉、附件预览和键盘交互只维护一份；
/// 引擎能力差异通过 [allowSendWhileBusy] 与 [questionActive] 参数表达。
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
