import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../core/models.dart';
import 'context_menu.dart';
import 'ios_style.dart';
import 'markdown_text.dart';

const _iosBlueLight = Color(0xFF007AFF);
const _iosBlueDark = Color(0xFF0A84FF);
const _toolbarIconWidth = 34.0;
const _messageListSidePadding = 12.0;
const _subagentResultMarker = '<子代理返回信息>';
const _subagentPromptMarker = '<子代理提示词注入>';
const _subagentSummaryMarker = '<子代理总结>';

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

  /// 刚发出的用户气泡做水滴分离；新出现的流式助手气泡做轻入场。
  /// 打开历史、滚动回收不要打开。
  final bool animateEnter;

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
    this.animateEnter = false,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  /// 思考内容是否展开（默认收起）。
  bool _showReasoning = false;

  /// DSH 运行时上下文是否展开（默认收起）。
  bool _showRuntimeContext = false;

  /// DSH 子代理返回内容是否展开（默认收起）。
  bool _showSubagentResult = false;

  /// DSH 子代理提示词是否展开（默认收起）。
  bool _showSubagentPrompt = false;

  /// 主模型对子代理结果的总结是否展开（默认收起）。
  bool _showSubagentSummary = false;

  /// 思考区滚动控制器（流式增长时自动跟随到最新）。
  final ScrollController _reasoningCtrl = ScrollController();

  /// 入场只播一次：父级下一帧就会把 animateEnter 关掉，这里锁住避免拆掉动画。
  late final bool _playEnter;

  @override
  void initState() {
    super.initState();
    _playEnter = widget.animateEnter;
  }

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

  String? _extractMarkedContent(String content, String marker) {
    final trimmed = content.trimLeft();
    if (!trimmed.startsWith(marker)) return null;
    return trimmed.substring(marker.length).trimLeft();
  }

  LiquidGlassStyle _glassStyle({
    required bool dark,
    required bool isUser,
    double cornerRadius = 20,
  }) {
    final tint = isUser
        ? (dark ? const Color(0x991A4DAD) : const Color(0x5C9EC5FF))
        : (dark ? const Color(0x733A3A3E) : const Color(0x70FFFFFF));
    return LiquidGlassStyle(
      shape: LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: cornerRadius,
        borderWidth: 1,
        borderColor: dark
            ? Colors.white.withValues(alpha: .18)
            : Colors.white.withValues(alpha: .55),
        lightIntensity: .85,
        lightDirection: isUser ? 55 : 125,
      ),
      appearance: LiquidGlassAppearance(
        color: tint,
        blur: const LiquidGlassBlur(sigmaX: 14, sigmaY: 14),
        saturation: 1.12,
      ),
      refraction: const LiquidGlassRefraction(
        distortion: .08,
        distortionWidth: 22,
        magnification: 1.01,
        chromaticAberration: .0015,
      ),
    );
  }

  Widget _maybeEnter({required bool isUser, required Widget child}) {
    if (!_playEnter) return child;
    return _BubbleEnter(isUser: isUser, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final isUser = message.role == 'user';
    // 流式缓冲可能暂时为空；这时回退到消息自身，避免历史 reasoning/content
    // 被一个空的 ValueNotifier 覆盖掉。
    final assistantContent = liveContent?.isNotEmpty == true
        ? liveContent!
        : message.content;
    final visibleReasoning = liveReasoning?.isNotEmpty == true
        ? liveReasoning!
        : message.reasoning;
    final legacySubagentResult = isUser
        ? null
        : _extractMarkedContent(assistantContent, _subagentResultMarker);
    final foldedSubagentResult = message.subagentResult.trim().isNotEmpty
        ? message.subagentResult.trim()
        : legacySubagentResult ?? '';
    final subagentPrompt = isUser
        ? null
        : _extractMarkedContent(assistantContent, _subagentPromptMarker);
    final legacySubagentSummary = isUser
        ? null
        : _extractMarkedContent(assistantContent, _subagentSummaryMarker);
    final foldedSubagentSummary = message.subagentSummary.trim().isNotEmpty
        ? message.subagentSummary.trim()
        : legacySubagentSummary ?? '';
    final hasMarkedSubagentContent =
        legacySubagentResult != null ||
        subagentPrompt != null ||
        legacySubagentSummary != null;
    final visibleAssistantContent = hasMarkedSubagentContent
        ? ''
        : assistantContent;
    // 用户气泡前景色：深色模式用白、浅色模式用深灰蓝，保证在液态玻璃上的对比度。
    final userFg = dark ? Colors.white : const Color(0xFF14264A);
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
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(7),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .22 : .10),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: LiquidGlassLens(
              key: const ValueKey('userLiquidGlassLens'),
              style: _glassStyle(dark: dark, isUser: true),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.runtimeContext.trim().isNotEmpty) ...[
                      _runtimeContextHeader(
                        theme,
                        onBlue: true,
                        foreground: userFg,
                      ),
                      if (_showRuntimeContext)
                        _runtimeContextBody(
                          theme,
                          message.runtimeContext,
                          onBlue: true,
                          foreground: userFg,
                        ),
                    ],
                    if (message.content.isNotEmpty)
                      _UserContent(
                        content: message.content,
                        style: theme.textTheme.bodyMedium!.copyWith(
                          fontSize: 16,
                          height: 1.45,
                          color: userFg,
                        ),
                      ),
                  ],
                ),
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
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(7),
                bottomRight: Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? .22 : .08),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: LiquidGlassLens(
              key: const ValueKey('assistantLiquidGlassLens'),
              style: _glassStyle(dark: dark, isUser: false),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.runtimeContext.trim().isNotEmpty) ...[
                      _runtimeContextHeader(theme, onBlue: false),
                      if (_showRuntimeContext)
                        _runtimeContextBody(
                          theme,
                          message.runtimeContext,
                          onBlue: false,
                        ),
                    ],
                    // 流式期间与已完成的思考统一为一个可展开面板，不再让
                    // 子代理总结、工具调用或空 live 缓冲把 reasoning 隐藏掉。
                    if (message.streaming || visibleReasoning.isNotEmpty) ...[
                      _reasoningHeader(theme, streaming: message.streaming),
                      if (_showReasoning && visibleReasoning.isNotEmpty)
                        _reasoningBody(theme, visibleReasoning),
                    ],
                    if (foldedSubagentResult.isNotEmpty) ...[
                      _subagentResultHeader(theme),
                      if (_showSubagentResult)
                        _subagentMessageBody(theme, foldedSubagentResult),
                    ],
                    if (subagentPrompt != null) ...[
                      _subagentPromptHeader(theme),
                      if (_showSubagentPrompt && subagentPrompt.isNotEmpty)
                        _subagentMessageBody(theme, subagentPrompt),
                    ],
                    if (foldedSubagentSummary.isNotEmpty) ...[
                      _subagentSummaryHeader(theme),
                      if (_showSubagentSummary)
                        _subagentMessageBody(theme, foldedSubagentSummary),
                    ],
                    if (visibleAssistantContent.isNotEmpty)
                      _assistantContent(
                        theme,
                        dark,
                        visibleAssistantContent,
                        isStreaming: message.streaming,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final padded = GestureDetector(
      onLongPress: () => _showActions(context),
      // Windows 桌面：右键弹出同一操作菜单（手机端长按不变）。
      onSecondaryTapDown: (d) => _showActionsDesktop(context, d.globalPosition),
      child: body,
    );

    return _maybeEnter(
      isUser: isUser,
      child: Column(
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
      ),
    );
  }

  /// 流式和结束后都走同一套 Markdown，避免切组件时整段消失再出现。
  Widget _assistantContent(
    ThemeData theme,
    bool dark,
    String content, {
    required bool isStreaming,
  }) {
    final textStyle = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 16,
      height: 1.45,
      color: dark ? const Color(0xFFF2F2F7) : const Color(0xFF1C1C1E),
    );
    return AdaptiveMarkdownText(
      content,
      isStreaming: isStreaming,
      style: textStyle,
    );
  }

  /// 思考内容折叠头：流式期间显示 spinner + “思考中”，结束后显示“思考过程”。
  Widget _reasoningHeader(ThemeData theme, {required bool streaming}) {
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
            if (streaming)
              const SizedBox(
                width: 15,
                height: 15,
                child: CupertinoActivityIndicator(radius: 7),
              )
            else
              Icon(
                _showReasoning ? Icons.unfold_less : Icons.unfold_more,
                size: 15,
                color: blue,
              ),
            const SizedBox(width: 4),
            Text(
              _showReasoning ? '收起思考' : (streaming ? '思考中' : '思考过程'),
              style: theme.textTheme.bodySmall!.copyWith(
                color: blue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 思考内容正文：浅色块 + 小字，超高可滚动。
  Widget _reasoningBody(ThemeData theme, String reasoning) {
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: LiquidGlassLens(
        style: _glassStyle(dark: dark, isUser: false, cornerRadius: 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              controller: _reasoningCtrl,
              child: SelectableText(
                reasoning,
                style: theme.textTheme.bodySmall!.copyWith(
                  color: dark
                      ? const Color(0xFFD1D1D6)
                      : const Color(0xFF3A3A3C),
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _subagentResultHeader(ThemeData theme) {
    final blue = theme.brightness == Brightness.dark
        ? _iosBlueDark
        : _iosBlueLight;
    return InkWell(
      onTap: () => setState(() => _showSubagentResult = !_showSubagentResult),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showSubagentResult ? Icons.unfold_less : Icons.unfold_more,
              size: 15,
              color: blue,
            ),
            const SizedBox(width: 4),
            Text(
              _showSubagentResult ? '收起子代理' : '子代理返回信息',
              style: theme.textTheme.bodySmall!.copyWith(
                color: blue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subagentPromptHeader(ThemeData theme) {
    final blue = theme.brightness == Brightness.dark
        ? _iosBlueDark
        : _iosBlueLight;
    return InkWell(
      onTap: () => setState(() => _showSubagentPrompt = !_showSubagentPrompt),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showSubagentPrompt ? Icons.unfold_less : Icons.unfold_more,
              size: 15,
              color: blue,
            ),
            const SizedBox(width: 4),
            Text(
              _showSubagentPrompt ? '收起提示词' : '子代理提示词注入',
              style: theme.textTheme.bodySmall!.copyWith(
                color: blue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subagentSummaryHeader(ThemeData theme) {
    final blue = theme.brightness == Brightness.dark
        ? _iosBlueDark
        : _iosBlueLight;
    return InkWell(
      onTap: () => setState(() => _showSubagentSummary = !_showSubagentSummary),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showSubagentSummary ? Icons.unfold_less : Icons.unfold_more,
              size: 15,
              color: blue,
            ),
            const SizedBox(width: 4),
            Text(
              _showSubagentSummary ? '收起总结' : '子代理总结',
              style: theme.textTheme.bodySmall!.copyWith(
                color: blue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subagentMessageBody(ThemeData theme, String text) {
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: LiquidGlassLens(
        style: _glassStyle(dark: dark, isUser: false, cornerRadius: 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: AdaptiveMarkdownText(
                text,
                style: theme.textTheme.bodySmall!.copyWith(
                  color: dark
                      ? const Color(0xFFD1D1D6)
                      : const Color(0xFF3A3A3C),
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 运行时上下文折叠头：有注入才画，默认收起。
  Widget _runtimeContextHeader(
    ThemeData theme, {
    required bool onBlue,
    Color? foreground,
  }) {
    final color = onBlue
        // 用户气泡上的前景：浅色模式深字、深色模式白字（foreground 已算好）。
        ? (foreground ??
              (theme.brightness == Brightness.dark
                  ? Colors.white
                  : const Color(0xFF14264A)))
        : (theme.brightness == Brightness.dark ? _iosBlueDark : _iosBlueLight);
    return InkWell(
      onTap: () => setState(() => _showRuntimeContext = !_showRuntimeContext),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showRuntimeContext ? Icons.unfold_less : Icons.unfold_more,
              size: 15,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              _showRuntimeContext ? '收起上下文' : '注入上下文',
              style: theme.textTheme.bodySmall!.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 运行时上下文正文：浅色块 + 小字，超高可滚动。
  Widget _runtimeContextBody(
    ThemeData theme,
    String text, {
    required bool onBlue,
    Color? foreground,
  }) {
    final dark = theme.brightness == Brightness.dark;
    final fg = onBlue
        ? (foreground ?? (dark ? Colors.white : const Color(0xFF14264A)))
        : (dark ? const Color(0xFFD1D1D6) : const Color(0xFF3A3A3C));
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: LiquidGlassLens(
        style: _glassStyle(dark: dark, isUser: onBlue, cornerRadius: 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: theme.textTheme.bodySmall!.copyWith(
                  color: fg,
                  height: 1.5,
                ),
              ),
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
      if (canSpeak && onSpeak != null)
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
      if (onCopy != null)
        _barButton(
          theme: theme,
          icon: Icons.copy_all_outlined,
          tooltip: '复制',
          onTap: () => onCopy?.call(message),
        ),
      if (!isUser && !busy && onRegenerate != null)
        _barButton(
          theme: theme,
          icon: Icons.refresh,
          tooltip: '重新生成',
          onTap: () => onRegenerate?.call(message),
        ),
      if (!busy && onSaveMemory != null)
        _barButton(
          theme: theme,
          icon: Icons.bookmark_add_outlined,
          tooltip: '保存记忆',
          onTap: () => onSaveMemory?.call(message),
        ),
      if (!busy && onSaveSkill != null)
        _barButton(
          theme: theme,
          icon: Icons.rocket_launch_outlined,
          tooltip: '保存技能',
          onTap: () => onSaveSkill?.call(message),
        ),
      if (!busy && onDelete != null)
        _barButton(
          theme: theme,
          icon: Icons.delete_outline,
          tooltip: '删除',
          onTap: () => onDelete?.call(message),
        ),
    ];
    if (actions.isEmpty) return const SizedBox.shrink();

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
        !busy &&
        onSpeak != null;
    final canCopy = onCopy != null;
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
                  if (canCopy)
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
                  if (message.role == 'assistant' &&
                      !busy &&
                      onRegenerate != null)
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
                  if (!busy && onSaveMemory != null)
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
                  if (!busy && onSaveSkill != null)
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
              ),
              if (!busy && onDelete != null) ...[
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

  /// Windows 桌面：在右键位置弹出消息操作菜单（与长按菜单同操作集）。
  void _showActionsDesktop(BuildContext context, Offset globalPosition) {
    final canSpeak =
        message.role == 'assistant' &&
        message.content.trim().isNotEmpty &&
        !busy &&
        onSpeak != null;
    final canCopy = onCopy != null;
    final blue = Theme.of(context).brightness == Brightness.dark
        ? _iosBlueDark
        : _iosBlueLight;
    final items = <DesktopMenuItem>[
      DesktopMenuItem(
        label: '选择文字',
        icon: CupertinoIcons.textformat,
        iconColor: blue,
        onTap: () => _showSelectText(),
      ),
      if (canCopy)
        DesktopMenuItem(
          label: '复制',
          icon: CupertinoIcons.doc_on_doc,
          iconColor: const Color(0xFF8E8E93),
          onTap: () => onCopy?.call(message),
        ),
      if (canSpeak)
        DesktopMenuItem(
          label: speaking ? '停止朗读' : '朗读',
          icon: CupertinoIcons.speaker_2_fill,
          iconColor: const Color(0xFF34C759),
          onTap: () {
            if (speaking) {
              onStopSpeak?.call();
            } else {
              onSpeak?.call(message);
            }
          },
        ),
      if (message.role == 'assistant' && !busy && onRegenerate != null)
        DesktopMenuItem(
          label: '重新生成',
          icon: CupertinoIcons.refresh,
          iconColor: const Color(0xFFFF9500),
          onTap: () => onRegenerate?.call(message),
        ),
      if (!busy && onSaveMemory != null)
        DesktopMenuItem(
          label: '保存记忆',
          icon: CupertinoIcons.bookmark,
          iconColor: const Color(0xFF5856D6),
          onTap: () => onSaveMemory?.call(message),
        ),
      if (!busy && onSaveSkill != null)
        DesktopMenuItem(
          label: '保存技能',
          icon: CupertinoIcons.rocket,
          iconColor: const Color(0xFFAF52DE),
          onTap: () => onSaveSkill?.call(message),
        ),
      if (!busy && onDelete != null)
        DesktopMenuItem(
          label: '删除',
          icon: CupertinoIcons.delete,
          iconColor: CupertinoColors.systemRed,
          onTap: () => onDelete?.call(message),
        ),
    ];
    showDesktopMenu(context, globalPosition: globalPosition, items: items);
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

/// 刚发出的气泡入场：用户从输入区水滴分离，助手从左侧同样水滴入场。
class _BubbleEnter extends StatefulWidget {
  final bool isUser;
  final Widget child;

  const _BubbleEnter({required this.isUser, required this.child});

  @override
  State<_BubbleEnter> createState() => _BubbleEnterState();
}

class _BubbleEnterState extends State<_BubbleEnter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<double> _stretch;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.isUser ? 560 : 640),
    );
    _fade = Tween<double>(begin: widget.isUser ? .55 : .35, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, .4, curve: Curves.easeOut),
      ),
    );
    _scale = Tween<double>(begin: widget.isUser ? .42 : .46, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: widget.isUser
            ? const Interval(0, .72, curve: Curves.easeOutBack)
            : const Interval(0, .78, curve: Curves.easeOutBack),
      ),
    );
    _stretch = Tween<double>(begin: widget.isUser ? 1.38 : 1.32, end: 1)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(.28, 1, curve: Curves.easeOutBack),
          ),
        );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_controller.value);
          final dx = widget.isUser ? 14.0 : -18.0;
          final dy = widget.isUser ? 112.0 : 96.0;
          return Transform.translate(
            offset: Offset(dx * (1 - t), dy * (1 - t)),
            child: Transform(
              alignment: widget.isUser
                  ? Alignment.bottomRight
                  : Alignment.bottomLeft,
              transform: Matrix4.diagonal3Values(
                _scale.value,
                _stretch.value,
                1,
              ),
              child: child,
            ),
          );
        },
        child: widget.child,
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
