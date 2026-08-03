import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../services/image_service.dart';
import '../services/permission_service.dart';
import '../services/tts_service.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  final ShiyiState shiyi;
  final String? sessionId;
  const ChatScreen({super.key, required this.shiyi, this.sessionId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin
    implements BackGestureTarget {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;
  int _lastStreamLen = 0;
  String? _speakingId;

  /// 预测性返回：拖动进度 0~1，1 表示完全缩小悬浮。
  late final AnimationController _dragCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 0,
  );
  bool _dragging = false;
  MacPageRoute? _route;
  double _screenWidth = 0;
  bool _showToolLog = false;

  @override
  void initState() {
    super.initState();
    if (widget.sessionId != null &&
        widget.shiyi.currentSessionId != widget.sessionId) {
      widget.shiyi.selectSession(widget.sessionId!);
    }
    // 标记正在查看的会话：回复完成时若用户不在看，主页才显示未读。
    widget.shiyi.viewingSessionId =
        widget.sessionId ?? widget.shiyi.currentSessionId;
    // 打开聊天页时从 DB 恢复 token 统计与上下文估算，避免显示残留/0 值。
    final statsId = widget.sessionId ?? widget.shiyi.currentSessionId;
    if (statsId != null) {
      widget.shiyi.refreshTokenStats(statsId);
    }
    // 流式文本变化只重建正在输出的气泡；这里负责平滑跟随滚动。
    widget.shiyi.streamText.addListener(_onStreamTextChanged);
    TtsService.instance.speakingId.addListener(_onSpeakingChanged);
    TtsService.instance.lastError.addListener(_onTtsError);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenWidth = MediaQuery.sizeOf(context).width;
    final route = ModalRoute.of(context);
    if (route is MacPageRoute) {
      _route = route;
      route.backGestureTarget = this;
    }
  }

  @override
  void dispose() {
    _route?.backGestureTarget = null;
    _dragCtrl.dispose();
    widget.shiyi.streamText.removeListener(_onStreamTextChanged);
    widget.shiyi.viewingSessionId = null;
    TtsService.instance.speakingId.removeListener(_onSpeakingChanged);
    TtsService.instance.lastError.removeListener(_onTtsError);
    super.dispose();
  }

  void _onSpeakingChanged() {
    if (!mounted) return;
    setState(() => _speakingId = TtsService.instance.speakingId.value);
  }

  void _onTtsError() {
    final msg = TtsService.instance.lastError.value;
    if (!mounted || msg == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('朗读失败：$msg')));
  }

  /// 回到最新消息（reverse 列表里最新消息在 offset 0，即视觉底部）。
  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// 流式文本变化：只在靠近底部时平滑跟随，不打断用户上翻历史。
  void _onStreamTextChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.pixels <= 96) {
        _scrollToLatest();
      }
    });
  }

  /// 构建单条消息气泡；liveContent 非空时渲染流式实时文本。
  Widget _messageItem(ChatMessage m, {String? liveContent}) {
    return MessageBubble(
      message: m,
      liveContent: liveContent,
      busy: widget.shiyi.isBusy,
      speaking: _speakingId == m.id,
      onCopy: _copyMessage,
      onDelete: _confirmDelete,
      onRegenerate: _confirmRegenerate,
      onSpeak: _speakMessage,
      onStopSpeak: _stopSpeak,
      onSaveMemory: (msg) async {
        final messenger = ScaffoldMessenger.of(context);
        await widget.shiyi.addMemoryManual(msg.content);
        messenger.showSnackBar(const SnackBar(content: Text('已保存到长期记忆')));
      },
      onSaveSkill: (msg) {
        _saveSkillDialog(msg.content);
      },
    );
  }

  /// 新消息或流式内容增长时自动跟随到底部；用户上翻历史时不打扰。
  void _maybeAutoScroll(List<ChatMessage> messages) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      // reverse 列表：offset 0 就是最新消息，无需进入时滚动。
      final nearLatest = pos.pixels <= 96;
      final count = messages.length;
      final countChanged = count != _lastCount;
      _lastCount = count;
      var streamLen = 0;
      if (messages.isNotEmpty && messages.last.streaming) {
        streamLen = messages.last.content.length;
      }
      final streamChanged = streamLen != _lastStreamLen;
      _lastStreamLen = streamLen;
      if (!countChanged && !streamChanged) return;
      if (nearLatest) {
        _scrollToLatest();
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty && _pendingImages.isEmpty) return;
    final sb = StringBuffer();
    for (final path in _pendingImages) {
      sb.writeln('![图片]($path)');
    }
    if (text.trim().isNotEmpty) sb.write(text);
    _input.clear();
    setState(() => _pendingImages.clear());
    FocusScope.of(context).unfocus();
    await widget.shiyi.guideSend(sb.toString());
    _scrollToLatest();
  }

  final List<String> _pendingImages = [];

  Future<void> _pickImage({required bool fromCamera}) async {
    try {
      final path = await ImageService.pickAndSave(fromCamera: fromCamera);
      if (path != null && mounted) {
        setState(() => _pendingImages.add(path));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '选择图片失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  void _removeImage(int index) {
    setState(() => _pendingImages.removeAt(index));
  }

  void _pickImageSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(fromCamera: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(fromCamera: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendSuggestion(String text) async {
    _input.text = text;
    await _send();
  }

  Future<void> _speakMessage(ChatMessage msg) async {
    await TtsService.instance.speak(
      msg.id,
      msg.content,
      rate: widget.shiyi.settings.ttsRate,
    );
  }

  void _stopSpeak() {
    TtsService.instance.stop();
  }

  Future<void> _copyMessage(ChatMessage msg) async {
    final text = stripImageMarkers(msg.content);
    final content = text.isEmpty ? msg.content : text;
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }

  Future<void> _confirmDelete(ChatMessage msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条消息？'),
        content: const Text('删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.shiyi.deleteMessage(msg.id);
  }

  Future<void> _confirmRegenerate(ChatMessage msg) async {
    final idx = widget.shiyi.messages.indexWhere((m) => m.id == msg.id);
    final hasAfter = idx >= 0 && idx < widget.shiyi.messages.length - 1;
    if (hasAfter) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重新生成这条回复？'),
          content: const Text('将删除该回复之后的所有消息，再基于此前对话重新生成。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('重新生成'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await widget.shiyi.regenerate(msg.id);
  }

  // ---------- 系统预测性返回（由 MacPageRoute 转发系统手势） ----------
  @override
  void onBackGestureProgress(double progress) {
    if (!mounted) return;
    _dragCtrl.stop();
    _dragCtrl.value = progress.clamp(0.0, 1.0);
  }

  @override
  void onBackGestureCommit() {
    if (!mounted) return;
    _performPop();
  }

  @override
  void onBackGestureCancel() {
    if (!mounted) return;
    _dragCtrl.animateBack(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  // ---------- 预测性返回手势 ----------
  void _onDragStart(DragStartDetails d) {
    // 只响应屏幕左边缘（约 60px 内）开始的拖动。
    if (d.localPosition.dx > 60) return;
    _dragging = true;
    _dragCtrl.stop();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final width = _screenWidth <= 0
        ? MediaQuery.sizeOf(context).width
        : _screenWidth;
    _dragCtrl.value = (d.localPosition.dx / (width * 0.6))
        .clamp(0.0, 1.0)
        .toDouble();
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    // 超过阈值或快速甩动 -> 返回；否则回弹复原。
    if (_dragCtrl.value > 0.45 || (d.primaryVelocity ?? 0) > 600) {
      _performPop();
    } else {
      _dragCtrl.animateBack(
        0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _dragCtrl.animateBack(
      0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  /// 执行返回：先补完缩小悬浮动画，再真正 pop。
  Future<void> _performPop() async {
    // 工具信息流是当前页面上的临时层，优先响应系统返回。
    if (_showToolLog) {
      if (mounted) setState(() => _showToolLog = false);
      return;
    }
    // 直接由路由的淡入淡出完成返回，省掉额外的拖动收尾动画。
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _performPop();
      },
      child: GestureDetector(
        // 屏幕左边缘按住右滑 = 预测性返回：页面淡出，底层预览上一页（省资源）。
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: _onDragCancel,
        child: AnimatedBuilder(
          animation: _dragCtrl,
          builder: (context, child) {
            final t = _dragCtrl.value;
            // 静止状态零开销：直接透传，不套变换/裁剪层。
            if (t <= 0.001) return child!;
            // 淡入淡出代替缩小悬浮：无缩放/裁剪绘制开销。
            return Opacity(opacity: 1.0 - t * 0.45, child: child);
          },
          child: RepaintBoundary(
            child: Stack(
              children: [
                Scaffold(
                  appBar: AppBar(
                    leadingWidth: 104,
                    leading: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 18,
                          ),
                          tooltip: '返回',
                          onPressed: _performPop,
                        ),
                        const _TrafficLights(),
                      ],
                    ),
                    // 右侧对称占位放工具调用信息流胶囊，标题保持居中。
                    actions: [
                      IconButton(
                        tooltip: '压缩上下文',
                        icon: const Icon(Icons.compress_outlined, size: 20),
                        onPressed: () => _compressContext(),
                      ),
                      SizedBox(
                        width: 104,
                        child: ListenableBuilder(
                          listenable: widget.shiyi,
                          builder: (context, _) {
                            final events = widget.shiyi.toolEvents;
                            return Center(
                              child: events.isEmpty
                                  ? _ToolPillIdle(
                                      onTap: () => setState(
                                        () => _showToolLog = !_showToolLog,
                                      ),
                                    )
                                  : _ToolPill(
                                      event: events.last,
                                      onTap: () => setState(
                                        () => _showToolLog = !_showToolLog,
                                      ),
                                    ),
                            );
                          },
                        ),
                      ),
                    ],
                    title: ListenableBuilder(
                      listenable: widget.shiyi,
                      builder: (context, _) {
                        if (widget.shiyi.currentSessionId == null) {
                          return const Text('新会话');
                        }
                        final s = widget.shiyi.sessions.firstWhere(
                          (e) => e.id == widget.shiyi.currentSessionId,
                          orElse: () => Session(
                            id: '',
                            title: '新会话',
                            model: '',
                            createdAt: 0,
                            updatedAt: 0,
                          ),
                        );
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              s.title,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (widget.shiyi.settings.model.isNotEmpty)
                              Text(
                                widget.shiyi.settings.model,
                                style: theme.textTheme.bodySmall!.copyWith(
                                  color: theme.hintColor,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  body: Column(
                    children: [
                      Expanded(
                        child: ListenableBuilder(
                          listenable: widget.shiyi,
                          builder: (context, _) {
                            final messages = widget.shiyi.messages;
                            // 工具调用已集中到右上角信息流胶囊，对话流里不再显示工具消息与纯工具回合。
                            final visible = messages
                                .where(
                                  (m) =>
                                      m.role != 'tool' &&
                                      !(m.role == 'assistant' &&
                                          m.hasToolCalls &&
                                          m.content.trim().isEmpty &&
                                          !m.streaming),
                                )
                                .toList();
                            _maybeAutoScroll(visible);
                            if (messages.isEmpty) {
                              return _Welcome(
                                shiyi: widget.shiyi,
                                onPick: _sendSuggestion,
                              );
                            }
                            if (visible.isEmpty) return const SizedBox.shrink();
                            return ListView.builder(
                              controller: _scroll,
                              reverse: true,
                              padding: const EdgeInsets.all(12),
                              itemCount: visible.length,
                              itemBuilder: (context, i) {
                                // 反转：index 0 是最新消息，显示在底部。
                                final m = visible[visible.length - 1 - i];
                                // 流式消息：只监听自己的实时文本，单独重建。
                                if (m.streaming) {
                                  return KeyedSubtree(
                                    key: ValueKey(m.id),
                                    child: ValueListenableBuilder<String>(
                                      valueListenable: widget.shiyi.streamText,
                                      builder: (context, text, _) =>
                                          _messageItem(m, liveContent: text),
                                    ),
                                  );
                                }
                                // 历史消息：稳定不变，隔离重绘。
                                return KeyedSubtree(
                                  key: ValueKey(m.id),
                                  child: RepaintBoundary(
                                    child: _messageItem(m),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      ListenableBuilder(
                        listenable: widget.shiyi,
                        builder: (context, _) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.shiyi.storagePermissionHint)
                              _FileAccessBanner(
                                onGrant: () async {
                                  final messenger = ScaffoldMessenger.of(
                                    context,
                                  );
                                  final grantedBefore =
                                      await PermissionService.isFullAccessGranted();
                                  if (!grantedBefore) {
                                    await PermissionService.requestFullAccess();
                                  }
                                  final granted =
                                      await PermissionService.isFullAccessGranted();
                                  if (granted) {
                                    widget.shiyi.clearStoragePermissionHint();
                                    messenger.showSnackBar(
                                      const SnackBar(
                                        content: Text('文件访问权限已开启，可以再让拾忆试试'),
                                      ),
                                    );
                                  } else {
                                    messenger.showSnackBar(
                                      const SnackBar(
                                        content: Text('请在系统设置中手动开启「所有文件访问权限」'),
                                      ),
                                    );
                                  }
                                },
                              ),
                            if (widget.shiyi.status != null)
                              Builder(
                                builder: (context) {
                                  final s = widget.shiyi.status!;
                                  final isError = s.startsWith('错误');
                                  final bg = isError
                                      ? theme.colorScheme.errorContainer
                                            .withValues(alpha: .4)
                                      : theme.colorScheme.surfaceContainerHigh
                                            .withValues(alpha: .7);
                                  final fg = isError
                                      ? theme.colorScheme.onErrorContainer
                                      : theme.colorScheme.onSurfaceVariant;
                                  return Container(
                                    width: double.infinity,
                                    color: bg,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    child: Text(
                                      s,
                                      style: theme.textTheme.bodySmall!
                                          .copyWith(color: fg),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      ListenableBuilder(
                        listenable: widget.shiyi,
                        builder: (context, _) =>
                            _TokenStats(shiyi: widget.shiyi),
                      ),
                      ListenableBuilder(
                        listenable: widget.shiyi,
                        builder: (context, _) => _Composer(
                          input: _input,
                          busy: widget.shiyi.isBusy,
                          pendingImages: _pendingImages,
                          onPickImage: _pickImageSheet,
                          onRemoveImage: _removeImage,
                          onSend: _send,
                          onStop: widget.shiyi.stop,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_showToolLog)
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
                    right: 8,
                    width: 280,
                    child: _ToolLogPanel(
                      events: widget.shiyi.toolEvents,
                      onClose: () => setState(() => _showToolLog = false),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _compressContext() async {
    final shiyi = widget.shiyi;
    final sessionId = widget.sessionId ?? shiyi.currentSessionId;
    if (sessionId == null) return;
    final chars = await shiyi.sessionContextChars(sessionId);
    if (!mounted) return;
    final limit = shiyi.settings.contextLimit;
    final pct = limit <= 0 ? 0.0 : (chars / limit * 100).clamp(0, 100);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('压缩上下文'),
        content: Text(
          '当前会话上下文约 ${pct.toStringAsFixed(0)}%'
          '（${(chars / 10000).toStringAsFixed(1)} 万字符 / 上限 ${(limit / 10000).toStringAsFixed(0)} 万字符）。\n'
          '压缩会把早期历史总结成摘要，只保留最近部分完整消息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('压缩'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await shiyi.compressSession(sessionId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(done ? '压缩完成' : '压缩失败（消息太少或 API 未配置）')),
    );
  }

  void _saveSkillDialog(String content) {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final contentCtrl = TextEditingController(text: content);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存为技能'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '技能名称',
                  hintText: '例如：写周报',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(labelText: '描述（可选）'),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: contentCtrl,
                decoration: const InputDecoration(labelText: '技能内容'),
                maxLines: 6,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              try {
                await widget.shiyi.saveSkill(
                  Skill(
                    id: 0,
                    name: name,
                    description: descCtrl.text.trim(),
                    content: contentCtrl.text.trim(),
                    createdAt: DateTime.now().millisecondsSinceEpoch,
                  ),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('技能已保存，可在「技能」页查看')),
                  );
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(
                        '保存失败：${e.toString().replaceFirst('Exception: ', '')}',
                      ),
                    ),
                  );
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// 输入框上方的 token 统计栏：本次会话累计 / 本轮对话 / 剩余上下文百分比。
class _TokenStats extends StatelessWidget {
  final ShiyiState shiyi;
  const _TokenStats({required this.shiyi});

  static String _fmt(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = shiyi.sessionTotalTokens;
    final round = shiyi.lastRoundTokens;
    final limit = shiyi.settings.contextLimit;
    final chars = shiyi.sessionChars;
    final remain = limit <= 0
        ? 100.0
        : ((limit - chars) / limit * 100).clamp(0, 100);
    final remainInt = remain.round();
    final color = remainInt <= 20
        ? theme.colorScheme.error
        : remainInt <= 50
        ? theme.colorScheme.tertiary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Text(
        '会话 ${_fmt(total)} · 本轮 ${_fmt(round)} · 上下文 ${_fmt(chars)}/${_fmt(limit)}（剩 $remainInt%）',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall!.copyWith(color: color, fontSize: 11),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController input;
  final bool busy;
  final List<String> pendingImages;
  final VoidCallback onPickImage;
  final ValueChanged<int> onRemoveImage;
  final VoidCallback onSend;
  final VoidCallback onStop;
  const _Composer({
    required this.input,
    required this.busy,
    required this.pendingImages,
    required this.onPickImage,
    required this.onRemoveImage,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer.withValues(alpha: .92),
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: .4)),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pendingImages.isNotEmpty) _previewRow(theme),
            const SizedBox(height: 6),
            Row(
              children: [
                IconButton(
                  onPressed: onPickImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  tooltip: '发送图片',
                  color: theme.colorScheme.primary,
                ),
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    onSubmitted: (_) => onSend(),
                    decoration: InputDecoration(
                      hintText: '输入消息…',
                      hintStyle: TextStyle(color: theme.hintColor),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHigh
                          .withValues(alpha: .85),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: input,
                  builder: (context, value, _) {
                    final hasInput =
                        value.text.trim().isNotEmpty ||
                        pendingImages.isNotEmpty;
                    if (!busy) {
                      return IconButton.filled(
                        onPressed: onSend,
                        icon: const Icon(Icons.send_rounded),
                        tooltip: '发送',
                      );
                    }
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: onStop,
                          icon: const Icon(Icons.stop_rounded),
                          tooltip: '停止',
                        ),
                        if (hasInput) ...[
                          const SizedBox(width: 4),
                          IconButton.filled(
                            onPressed: onSend,
                            icon: const Icon(Icons.send_rounded),
                            tooltip: '发送并引导',
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewRow(ThemeData theme) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pendingImages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final path = pendingImages[i];
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
                  onTap: () => onRemoveImage(i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final ShiyiState shiyi;
  final ValueChanged<String> onPick;
  const _Welcome({required this.shiyi, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions = [
      '帮我记住：我偏好用 Markdown 写文档',
      '我学到一个技能：用番茄工作法管理时间',
      '帮我搜索记忆里关于「项目」的内容',
    ];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Icon(
          Icons.auto_mode_outlined,
          size: 80,
          color: theme.colorScheme.primary.withValues(alpha: .7),
        ),
        const SizedBox(height: 12),
        Text(
          '你好，我是拾忆\n与你共同成长的智能体',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge!.copyWith(height: 1.3),
        ),
        const SizedBox(height: 8),
        Text(
          '跨会话记忆 · 技能沉淀 · 工具调用',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium!.copyWith(color: theme.hintColor),
        ),
        const SizedBox(height: 28),
        for (final s in suggestions) ...[
          OutlinedButton(
            onPressed: () => onPick(s),
            style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
            child: Text(s),
          ),
        ],
      ],
    );
  }
}

/// macOS 窗口红绿灯装饰（AppBar 左侧）。
class _TrafficLights extends StatelessWidget {
  const _TrafficLights();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MacDot(Color(0xFFFF5F57)),
          SizedBox(width: 5),
          _MacDot(Color(0xFFFEBC2E)),
          SizedBox(width: 5),
          _MacDot(Color(0xFF28C840)),
        ],
      ),
    );
  }
}

class _MacDot extends StatelessWidget {
  final Color color;
  const _MacDot(this.color);
  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 终端访问手机存储被系统拒绝时的提示横幅，点击一键去授权。
class _FileAccessBanner extends StatelessWidget {
  final VoidCallback onGrant;
  const _FileAccessBanner({required this.onGrant});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      color: cs.tertiaryContainer.withValues(alpha: .55),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.folder_off_outlined,
            size: 16,
            color: cs.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '终端访问手机存储被系统拒绝，需要开启「所有文件访问权限」',
              style: theme.textTheme.bodySmall!.copyWith(
                color: cs.onTertiaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: onGrant,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }
}

// ---------- 工具调用信息流（右上角胶囊 + 展开面板） ----------

String _toolLabel(String name) => switch (name) {
  'web_search' => '搜索',
  'web_extract' => '抓取',
  'save_memory' => '记忆',
  'search_memory' => '检索',
  'run_skill' => '技能',
  'run_terminal' => '终端',
  _ => name,
};

IconData _toolIcon(String name) => switch (name) {
  'web_search' => Icons.travel_explore,
  'web_extract' => Icons.web_asset,
  'save_memory' => Icons.bookmark_add_outlined,
  'search_memory' => Icons.manage_search,
  'run_skill' => Icons.bolt,
  _ => Icons.construction,
};

/// 待机状态的工具胶囊：灰色圆点 + 「工具」字样，点击展开信息流面板。
class _ToolPillIdle extends StatelessWidget {
  final VoidCallback onTap;
  const _ToolPillIdle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerHigh.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '工具',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.hintColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右上角胶囊：显示最近一条工具调用状态，点击展开信息流面板。
class _ToolPill extends StatelessWidget {
  final ToolEvent event;
  final VoidCallback onTap;
  const _ToolPill({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerHigh.withValues(alpha: .92),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 92),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!event.done)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  )
                else
                  Icon(
                    event.ok ? Icons.check_circle : Icons.error,
                    size: 14,
                    color: event.ok ? const Color(0xFF28C840) : cs.error,
                  ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    _toolLabel(event.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (event.done && event.durationMs != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    '${(event.durationMs! / 1000).toStringAsFixed(1)}s',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具调用信息流面板：右上角展开，滚动显示本轮全部工具调用。
class _ToolLogPanel extends StatefulWidget {
  final List<ToolEvent> events;
  final VoidCallback onClose;
  const _ToolLogPanel({required this.events, required this.onClose});

  @override
  State<_ToolLogPanel> createState() => _ToolLogPanelState();
}

class _ToolLogPanelState extends State<_ToolLogPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: .3),
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
            child: Row(
              children: [
                Icon(Icons.bolt, size: 15, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  '工具调用',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '收起',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: widget.events.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
                      child: Text(
                        '暂无工具调用',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: _scroll,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      itemCount: widget.events.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      // 倒序显示：最新的一条在最上面。
                      itemBuilder: (context, i) => _ToolLogItem(
                        event: widget.events[widget.events.length - 1 - i],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolLogItem extends StatelessWidget {
  final ToolEvent event;
  const _ToolLogItem({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final okColor = const Color(0xFF28C840);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: !event.done
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  )
                : Icon(
                    event.ok ? Icons.check_circle : Icons.error,
                    size: 15,
                    color: event.ok ? okColor : cs.error,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _toolIcon(event.name),
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _toolLabel(event.name),
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (event.done)
                      Text(
                        event.durationMs == null
                            ? '完成'
                            : '${(event.durationMs! / 1000).toStringAsFixed(1)}s',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      )
                    else
                      Text(
                        '运行中',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.primary,
                        ),
                      ),
                  ],
                ),
                if (event.argsSummary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.argsSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
                if (event.done && event.summary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.summary!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
