import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'ios_style.dart';
import 'markdown_text.dart';

const _iosBlueLight = Color(0xFF007AFF);
const _iosBlueDark = Color(0xFF0A84FF);
const _iosGrayLight = Color(0xFFE9E9EB);
const _iosGrayDark = Color(0xFF2C2C2E);
const _toolbarIconWidth = 34.0;
const _messageListSidePadding = 12.0;

class MessageBubble extends StatefulWidget {
  final ChatMessage message;

  /// 流式实时文本：非空时用它渲染（独立刷新只更新这一条气泡）。
  final String? liveContent;

  /// 流式实时思考内容（reasoning_content）。
  final String? liveReasoning;
  final bool busy;
  final void Function(ChatMessage msg)? onCopy;
  final void Function(ChatMessage msg)? onDelete;
  final void Function(ChatMessage msg)? onRegenerate;
  final void Function(ChatMessage msg)? onSaveMemory;
  final void Function(ChatMessage msg)? onSaveSkill;
  final void Function(ChatMessage msg)? onSpeak;
  final VoidCallback? onStopSpeak;
  final bool speaking;

  const MessageBubble({
    super.key,
    required this.message,
    this.liveContent,
    this.liveReasoning,
    this.busy = false,
    this.onCopy,
    this.onDelete,
    this.onRegenerate,
    this.onSaveMemory,
    this.onSaveSkill,
    this.onSpeak,
    this.onStopSpeak,
    this.speaking = false,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  /// 思考内容是否展开（默认收起）。
  bool _showReasoning = false;

  /// 思考区滚动控制器（流式增长时自动跟随到最新）。
  final ScrollController _reasoningCtrl = ScrollController();

  @override
  void dispose() {
    _reasoningCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 流式思考内容增长时，思考区自动跟随到最新。
    final newR = widget.liveReasoning;
    if (newR != null && newR != oldWidget.liveReasoning && _showReasoning) {
      _scrollReasoningToBottom();
    }
  }

  /// 思考区滚到最底部（布局完成后执行）。
  void _scrollReasoningToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_reasoningCtrl.hasClients) return;
      _reasoningCtrl.jumpTo(_reasoningCtrl.position.maxScrollExtent);
    });
  }

  ChatMessage get message => widget.message;
  String? get liveContent => widget.liveContent;
  String? get liveReasoning => widget.liveReasoning;
  bool get busy => widget.busy;
  bool get speaking => widget.speaking;
  void Function(ChatMessage)? get onCopy => widget.onCopy;
  void Function(ChatMessage)? get onDelete => widget.onDelete;
  void Function(ChatMessage)? get onRegenerate => widget.onRegenerate;
  void Function(ChatMessage)? get onSaveMemory => widget.onSaveMemory;
  void Function(ChatMessage)? get onSaveSkill => widget.onSaveSkill;
  void Function(ChatMessage)? get onSpeak => widget.onSpeak;
  VoidCallback? get onStopSpeak => widget.onStopSpeak;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final isUser = message.role == 'user';
    final bubbleBlue = dark ? _iosBlueDark : _iosBlueLight;
    final maxBubbleWidth =
        MediaQuery.sizeOf(context).width -
        _messageListSidePadding * 2 -
        _toolbarIconWidth;

    Widget body;
    if (isUser) {
      body = Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: Container(
            key: const ValueKey('userBubble'),
            margin: const EdgeInsets.only(left: _toolbarIconWidth),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleBlue,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(7),
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: .18),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .18 : .06),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: _UserContent(
              content: message.content,
              style: theme.textTheme.bodyMedium!.copyWith(
                fontSize: 16,
                height: 1.45,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    } else {
      body = Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: Container(
            key: const ValueKey('assistantBubble'),
            margin: const EdgeInsets.only(top: 8, right: _toolbarIconWidth),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: dark ? _iosGrayDark : _iosGrayLight,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(7),
                bottomRight: Radius.circular(20),
              ),
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: .10)
                    : Colors.black.withValues(alpha: .06),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .18 : .06),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 思考内容（如有）：默认收起，点击展开/收回。
                // 进行中（streaming）也实时显示，让用户能看到模型的思考过程。
                if ((liveReasoning ?? message.reasoning).isNotEmpty) ...[
                  _reasoningHeader(theme),
                  if (_showReasoning)
                    _reasoningBody(theme, liveReasoning ?? message.reasoning),
                ] else if (message.streaming) ...[
                  _thinkingIndicator(theme),
                ],
                if ((liveContent ?? message.content).isNotEmpty)
                  AdaptiveMarkdownText(
                    liveContent ?? message.content,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      fontSize: 16,
                      height: 1.45,
                      color: dark
                          ? const Color(0xFFF2F2F7)
                          : const Color(0xFF1C1C1E),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final padded = GestureDetector(
      onLongPress: () => _showActions(context),
      child: body,
    );

    return Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        padded,
        _actionBar(theme, isUser),
        Padding(
          padding: EdgeInsets.only(
            left: isUser ? 0 : 16,
            right: isUser ? 16 : 0,
            top: 4,
          ),
          child: Text(
            isUser ? '你' : '拾忆',
            style: TextStyle(
              fontSize: 11,
              color: theme.hintColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  /// 「正在思考…」指示：spinner + 文字，进行中常驻显示。
  Widget _thinkingIndicator(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            '正在思考…',
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.disabledColor,
            ),
          ),
        ],
      ),
    );
  }

  /// 思考内容折叠头：点击展开/收回，进行中显示小 spinner。
  Widget _reasoningHeader(ThemeData theme) {
    final blue = theme.brightness == Brightness.dark
        ? _iosBlueDark
        : _iosBlueLight;
    return InkWell(
      onTap: () {
        setState(() => _showReasoning = !_showReasoning);
        // 展开时直接看到最新思考（而不是顶部）。
        if (!_showReasoning) return;
        _scrollReasoningToBottom();
      },
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showReasoning ? Icons.unfold_less : Icons.unfold_more,
              size: 15,
              color: blue,
            ),
            const SizedBox(width: 4),
            Text(
              _showReasoning ? '收起思考' : '思考过程',
              style: theme.textTheme.bodySmall!.copyWith(
                color: blue,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (message.streaming) ...[
              const SizedBox(width: 6),
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 思考内容正文：浅色块 + 小字，超高可滚动。
  Widget _reasoningBody(ThemeData theme, String reasoning) {
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: dark
            ? const Color(0xFF3A3A3C)
            : Colors.white.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          controller: _reasoningCtrl,
          child: SelectableText(
            reasoning,
            style: theme.textTheme.bodySmall!.copyWith(
              color: dark ? const Color(0xFFD1D1D6) : const Color(0xFF3A3A3C),
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  /// 消息底栏：常用操作直接放出来，随时可用（朗读/停止、复制、重新生成、记忆、技能、删除）。
  Widget _actionBar(ThemeData theme, bool isUser) {
    final canSpeak = !isUser && message.content.trim().isNotEmpty && !busy;
    final dark = theme.brightness == Brightness.dark;
    final actions = <Widget>[
      if (canSpeak)
        _barButton(
          theme: theme,
          icon: speaking ? Icons.stop_circle : Icons.volume_up_outlined,
          tooltip: speaking ? '停止朗读' : '朗读',
          color: speaking ? theme.colorScheme.primary : theme.hintColor,
          highlight: speaking,
          onTap: () {
            if (speaking) {
              onStopSpeak?.call();
            } else {
              onSpeak?.call(message);
            }
          },
        ),
      _barButton(
        theme: theme,
        icon: Icons.copy_all_outlined,
        tooltip: '复制',
        onTap: () => onCopy?.call(message),
      ),
      if (!isUser && !busy)
        _barButton(
          theme: theme,
          icon: Icons.refresh,
          tooltip: '重新生成',
          onTap: () => onRegenerate?.call(message),
        ),
      if (!busy) ...[
        _barButton(
          theme: theme,
          icon: Icons.bookmark_add_outlined,
          tooltip: '保存记忆',
          onTap: () => onSaveMemory?.call(message),
        ),
        _barButton(
          theme: theme,
          icon: Icons.rocket_launch_outlined,
          tooltip: '保存技能',
          onTap: () => onSaveSkill?.call(message),
        ),
      ],
      if (!busy)
        _barButton(
          theme: theme,
          icon: Icons.delete_outline,
          tooltip: '删除',
          onTap: () => onDelete?.call(message),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: DecoratedBox(
          key: const ValueKey('messageActionBar'),
          decoration: BoxDecoration(
            color: dark
                ? const Color(0xFF1C1C1E).withValues(alpha: .78)
                : Colors.white.withValues(alpha: .72),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: .08)
                  : Colors.black.withValues(alpha: .06),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? .14 : .05),
                blurRadius: 8,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        ),
      ),
    );
  }

  Widget _barButton({
    required ThemeData theme,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
    bool highlight = false,
  }) {
    final foreground = highlight
        ? theme.colorScheme.primary
        : color ?? theme.hintColor;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: highlight
                  ? theme.colorScheme.primary.withValues(alpha: .14)
                  : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 17, color: foreground),
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    final canSpeak =
        message.role == 'assistant' &&
        message.content.trim().isNotEmpty &&
        !busy;
    final sheetBg = Theme.of(context).scaffoldBackgroundColor;
    showIosFadeSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: sheetBg,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final dark = theme.brightness == Brightness.dark;
        final blue = dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '消息操作',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.hintColor,
                ),
              ),
              const SizedBox(height: 10),
              CupertinoListSection.insetGrouped(
                decoration: iosSectionDecoration(ctx),
                backgroundColor: iosGroupedBackground(ctx),
                children: [
                  _messageActionTile(
                    ctx: ctx,
                    icon: CupertinoIcons.textformat,
                    color: blue,
                    label: '选择文字',
                    onTap: () {
                      Navigator.pop(ctx);
                      _showSelectText();
                    },
                  ),
                  _messageActionTile(
                    ctx: ctx,
                    icon: CupertinoIcons.doc_on_doc,
                    color: const Color(0xFF8E8E93),
                    label: '复制',
                    onTap: () {
                      Navigator.pop(ctx);
                      onCopy?.call(message);
                    },
                  ),
                  if (canSpeak)
                    _messageActionTile(
                      ctx: ctx,
                      icon: speaking
                          ? CupertinoIcons.stop_circle_fill
                          : CupertinoIcons.speaker_2_fill,
                      color: const Color(0xFF34C759),
                      label: speaking ? '停止朗读' : '朗读',
                      onTap: () {
                        Navigator.pop(ctx);
                        if (speaking) {
                          onStopSpeak?.call();
                        } else {
                          onSpeak?.call(message);
                        }
                      },
                    ),
                  if (message.role == 'assistant' && !busy)
                    _messageActionTile(
                      ctx: ctx,
                      icon: CupertinoIcons.refresh,
                      color: const Color(0xFFFF9500),
                      label: '重新生成',
                      onTap: () {
                        Navigator.pop(ctx);
                        onRegenerate?.call(message);
                      },
                    ),
                  if (!busy) ...[
                    _messageActionTile(
                      ctx: ctx,
                      icon: CupertinoIcons.bookmark,
                      color: const Color(0xFF5856D6),
                      label: '保存记忆',
                      onTap: () {
                        Navigator.pop(ctx);
                        onSaveMemory?.call(message);
                      },
                    ),
                    _messageActionTile(
                      ctx: ctx,
                      icon: CupertinoIcons.rocket,
                      color: const Color(0xFFAF52DE),
                      label: '保存技能',
                      onTap: () {
                        Navigator.pop(ctx);
                        onSaveSkill?.call(message);
                      },
                    ),
                  ],
                ],
              ),
              if (!busy) ...[
                const SizedBox(height: 8),
                CupertinoListSection.insetGrouped(
                  decoration: iosSectionDecoration(ctx),
                  backgroundColor: iosGroupedBackground(ctx),
                  children: [
                    _messageActionTile(
                      ctx: ctx,
                      icon: CupertinoIcons.delete,
                      color: CupertinoColors.systemRed,
                      label: '删除',
                      labelColor: CupertinoColors.systemRed,
                      onTap: () {
                        Navigator.pop(ctx);
                        onDelete?.call(message);
                      },
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Material(
                color: iosSectionBackground(ctx),
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.pop(ctx),
                  child: SizedBox(
                    height: 50,
                    child: Center(
                      child: Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: blue,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _messageActionTile({
    required BuildContext ctx,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
    Color? labelColor,
  }) {
    return CupertinoListTile(
      leading: _MessageActionIconTile(icon: icon, color: color),
      title: Text(
        label,
        style: labelColor == null
            ? null
            : TextStyle(color: labelColor, fontSize: 16),
      ),
      onTap: onTap,
    );
  }

  Future<void> _showSelectText() async {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final text = stripImageMarkers(message.content);
    final content = text.isEmpty ? message.content : text;
    await showIosFadeSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(ctx),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '选择文字',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: dark
                          ? CupertinoColors.white
                          : CupertinoColors.black,
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('完成'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * 0.55,
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: dark ? const Color(0xFF2C2C2E) : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      content,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: dark
                            ? CupertinoColors.white
                            : CupertinoColors.black,
                      ),
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

/// 消息操作弹窗里的 iOS 图标方块，与设置页入口同款。
class _MessageActionIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _MessageActionIconTile({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 31,
      height: 31,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Icon(icon, size: 17, color: CupertinoColors.white),
    );
  }
}

/// 用户消息内容：本地图片标记 `![图片](路径)` 渲染为图片，其余文字正常显示。
class _UserContent extends StatelessWidget {
  final String content;
  final TextStyle style;
  const _UserContent({required this.content, required this.style});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[];
    var pos = 0;
    for (final m in imageMarkerRegExp.allMatches(content)) {
      if (m.start > pos) {
        children.add(Text(content.substring(pos, m.start), style: style));
      }
      final path = m.group(1)!.trim();
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220, maxHeight: 320),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(path),
                cacheWidth: (220 * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(
                  width: 140,
                  height: 90,
                  alignment: Alignment.center,
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: .5,
                  ),
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: theme.hintColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      pos = m.end;
    }
    if (pos < content.length) {
      children.add(Text(content.substring(pos), style: style));
    }
    if (children.isEmpty) {
      children.add(Text(content, style: style));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
