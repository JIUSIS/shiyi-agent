import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import 'markdown_text.dart';

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
    final isUser = message.role == 'user';

    Widget body;
    if (isUser) {
      body = Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: _UserContent(
            content: message.content,
            style: theme.textTheme.bodyMedium!.copyWith(color: Colors.white),
          ),
        ),
      );
    } else {
      body = Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(top: 8, right: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(6),
              bottomRight: Radius.circular(18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 思考内容（如有）：默认收起，点击展开/收回。
              // 进行中（streaming）也实时显示，让用户能看到模型的思考过程。
              // 有思考内容时用「思考过程」折叠头（自带 spinner），
              // 不再叠加单独的「正在思考…」；无思考内容的模型保留原占位。
              if ((liveReasoning ?? message.reasoning).isNotEmpty) ...[
                _reasoningHeader(theme),
                if (_showReasoning)
                  _reasoningBody(
                    theme,
                    liveReasoning ?? message.reasoning,
                  ),
              ] else if (message.streaming) ...[
                _thinkingIndicator(theme),
              ],
              if ((liveContent ?? message.content).isNotEmpty)
                AdaptiveMarkdownText(liveContent ?? message.content),
            ],
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
          padding: const EdgeInsets.only(left: 6, right: 6, top: 2),
          child: Text(
            isUser ? '你' : '拾忆',
            style: TextStyle(fontSize: 10, color: theme.hintColor),
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
    return InkWell(
      onTap: () => setState(() => _showReasoning = !_showReasoning),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showReasoning ? Icons.unfold_less : Icons.unfold_more,
              size: 15,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Text(
              _showReasoning ? '收起思考' : '思考过程',
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.primary,
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
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          child: SelectableText(
            reasoning,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
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
    return Padding(
      padding: EdgeInsets.only(
        left: isUser ? 12 : 2,
        right: isUser ? 2 : 12,
        top: 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
        ],
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
    final btn = IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      color: color ?? theme.hintColor,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    );
    if (!highlight) return btn;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: btn,
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制'),
              onTap: () {
                Navigator.pop(ctx);
                onCopy?.call(message);
              },
            ),
            if (message.role == 'assistant' &&
                message.content.trim().isNotEmpty &&
                !busy)
              ListTile(
                leading: Icon(
                  speaking
                      ? Icons.stop_circle_outlined
                      : Icons.volume_up_outlined,
                ),
                title: Text(speaking ? '停止朗读' : '朗读'),
                subtitle: const Text('用 Edge 在线语音播报这条回复'),
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
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重新生成'),
                subtitle: const Text('基于此前对话重新生成这条回复'),
                onTap: () {
                  Navigator.pop(ctx);
                  onRegenerate?.call(message);
                },
              ),
            if (!busy)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除'),
                subtitle: const Text('删除这条消息'),
                onTap: () {
                  Navigator.pop(ctx);
                  onDelete?.call(message);
                },
              ),
            if (!busy) ...[
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: const Text('保存为长期记忆'),
                subtitle: const Text('跨会话记住这段内容'),
                onTap: () {
                  Navigator.pop(ctx);
                  onSaveMemory?.call(message);
                },
              ),
              ListTile(
                leading: const Icon(Icons.rocket_launch_outlined),
                title: const Text('保存为技能'),
                subtitle: const Text('沉淀为可复用的技能/脚本'),
                onTap: () {
                  Navigator.pop(ctx);
                  onSaveSkill?.call(message);
                },
              ),
            ],
          ],
        ),
      ),
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
