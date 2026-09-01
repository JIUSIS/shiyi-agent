import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../services/dsh_api.dart';
import '../services/dsh_live.dart';
import '../services/dsh_service.dart';
import '../widgets/dsh_stats_bar.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_pill.dart';
import '../widgets/traffic_lights_button.dart';

const _iosBlue = Color(0xFF0A84FF);
const _iosRed = Color(0xFFFF3B30);

/// 子代理页（subagent.list / history / prompt / interrupt）。
/// 展示由父会话派生的子代理；运行中自动刷新，点击查看拾忆同款会话壳，
/// continuable 子代理可继续对话、可中断。
class DshSubagentsScreen extends StatefulWidget {
  final String parentSessionId;
  const DshSubagentsScreen({super.key, required this.parentSessionId});

  @override
  State<DshSubagentsScreen> createState() => _DshSubagentsScreenState();
}

class _DshSubagentsScreenState extends State<DshSubagentsScreen> {
  List<DshSubagentEntry> _entries = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  DshApiClient get _api => DshService.instance.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _refreshTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _api.listSubagents(widget.parentSessionId);
      if (!mounted) return;
      setState(() {
        _entries = r.entries;
        _loading = false;
      });
      _syncRefresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _syncRefresh() {
    _refreshTimer?.cancel();
    if (!_entries.any((e) => e.running)) return;
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    try {
      final r = await _api.listSubagents(widget.parentSessionId);
      if (!mounted) return;
      setState(() => _entries = r.entries);
      if (!_entries.any((e) => e.running)) {
        _refreshTimer?.cancel();
        _refreshTimer = null;
      }
    } catch (_) {}
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _pop() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: iosGroupedBackground(context),
      appBar: AppBar(
        leadingWidth: 104,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: MacActionButton(
              icon: CupertinoIcons.chevron_left,
              tooltip: '返回',
              onTap: _pop,
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
          '子代理',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: MacActionButton(
              icon: CupertinoIcons.refresh,
              tooltip: '刷新',
              onTap: _load,
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            CupertinoButton.filled(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(
        child: Text(
          '尚无子代理\n（agent 调用 subagent 工具后显示）',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        CupertinoListSection.insetGrouped(
          margin: iosSectionMargin,
          decoration: iosSectionDecoration(context),
          children: [
            for (final e in _entries)
              CupertinoListTile(
                key: ValueKey(e.sessionId),
                leading: Icon(
                  e.kind == 'diagnostic'
                      ? CupertinoIcons.exclamationmark_triangle
                      : CupertinoIcons.rectangle_stack_person_crop,
                  color: e.kind == 'diagnostic'
                      ? CupertinoColors.systemRed
                      : CupertinoColors.systemOrange,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        _entryTitle(e),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (e.running) ...[
                      const SizedBox(width: 8),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: CupertinoColors.systemGreen,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  _entrySubtitle(e),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _entryTrailing(e),
                onTap: e.kind == 'diagnostic' ? null : () => _openDetail(e),
              ),
          ],
        ),
      ],
    );
  }

  String _entryTitle(DshSubagentEntry e) {
    if (e.kind == 'diagnostic') return '子代理诊断';
    final title = e.title;
    if (title != null && title.isNotEmpty) return title;
    return '子代理 ${e.sessionId.split('-').first}';
  }

  String _entrySubtitle(DshSubagentEntry e) {
    if (e.kind == 'diagnostic') {
      return '无法读取 · ${e.reason ?? '未知原因'}';
    }
    final parts = <String>[
      e.mode == 'continuable' ? '可继续对话' : '一次性',
      e.running ? '运行中' : '已完成',
    ];
    if (e.turnCount > 0) parts.insert(0, '${e.turnCount} 轮');
    if (e.hasChildren) parts.add('含下级子代理');
    return parts.join(' · ');
  }

  Widget _entryTrailing(DshSubagentEntry e) {
    if (e.kind == 'diagnostic') {
      return const Icon(
        CupertinoIcons.exclamationmark_circle,
        size: 18,
        color: CupertinoColors.systemRed,
      );
    }
    if (e.running && e.mode == 'continuable') {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => _interrupt(e),
        child: const Icon(
          CupertinoIcons.stop_circle_fill,
          color: CupertinoColors.systemRed,
        ),
      );
    }
    if (e.running) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return const Icon(
      CupertinoIcons.chevron_right,
      size: 16,
      color: CupertinoColors.systemGrey,
    );
  }

  Future<void> _interrupt(DshSubagentEntry e) async {
    try {
      await _api.subagentInterrupt(widget.parentSessionId, e.sessionId);
      _toast('已请求中断');
      unawaited(_refresh());
    } catch (err) {
      _toast('中断失败：$err');
    }
  }

  void _openDetail(DshSubagentEntry e) {
    Navigator.push(
      context,
      MacPageRoute(
        builder: (_) => _SubagentDetailScreen(
          parentSessionId: widget.parentSessionId,
          childSessionId: e.sessionId,
          title: _entryTitle(e),
          mode: e.mode,
          initiallyRunning: e.running,
        ),
      ),
    );
  }
}

/// 子代理会话详情：拾忆会话页同款壳 + subagent.history 轮询流式。
class _SubagentDetailScreen extends StatefulWidget {
  final String parentSessionId;
  final String childSessionId;
  final String title;
  final String mode;
  final bool initiallyRunning;
  const _SubagentDetailScreen({
    required this.parentSessionId,
    required this.childSessionId,
    required this.title,
    required this.mode,
    required this.initiallyRunning,
  });

  @override
  State<_SubagentDetailScreen> createState() => _SubagentDetailScreenState();
}

class _SubagentDetailScreenState extends State<_SubagentDetailScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  bool _loading = true;
  String? _error;
  bool _sending = false;
  bool _running = false;
  bool _stopping = false;
  bool _showToolLog = false;
  Timer? _pollTimer;
  DshSessionSummary? _summary;
  final ValueNotifier<String> _streamText = ValueNotifier('');
  final ValueNotifier<String> _streamReasoning = ValueNotifier('');
  final DshLiveTurn _live = DshLiveTurn();
  bool _followTail = true;
  bool _autoScrollScheduled = false;
  static const _liveId = 'sub-live';

  DshApiClient get _api => DshService.instance.api;
  bool get _continuable => widget.mode == 'continuable';
  bool get _lightsBusy => _sending || _running || _stopping;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _streamText.addListener(_onStreamTextChanged);
    _running = widget.initiallyRunning;
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamText.removeListener(_onStreamTextChanged);
    _pollTimer?.cancel();
    _streamText.dispose();
    _streamReasoning.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 键盘弹起时把最新消息顶到输入框上方可见区。
    if (!mounted || !_scroll.hasClients) return;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    if (bottom > 0) _scrollToBottom(animated: false, force: true);
  }

  List<ChatMessage> get _visible {
    return _messages
        .where(
          (m) =>
              m.role != 'tool' &&
              !(m.role == 'assistant' &&
                  !m.streaming &&
                  m.hasToolCalls &&
                  m.content.trim().isEmpty &&
                  m.runtimeContext.trim().isEmpty),
        )
        .toList();
  }

  List<ToolEvent> get _toolEvents {
    final out = <ToolEvent>[];
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      final last = i == _messages.length - 1;
      for (final t in m.toolCalls) {
        out.add(
          ToolEvent(
            name: t.name,
            argsSummary: t.arguments,
            startedAt: m.createdAt == 0
                ? DateTime.now().millisecondsSinceEpoch
                : m.createdAt,
            done: !(_running && last),
            ok: true,
          ),
        );
      }
    }
    return out;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bundle = await _api.subagentHistoryBundle(
        widget.parentSessionId,
        widget.childSessionId,
        mode: widget.mode,
      );
      if (!mounted) return;
      setState(() {
        _messages = bundle.messages;
        _summary = bundle.summary;
        _loading = false;
      });
      _adoptLive(bundle.live, force: true);
      _scrollToBottom(animated: false);
      // 列表首次布局可能晚于本帧，二次兜底确保进详情就在最后一条。
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (mounted) _scrollToBottom(animated: false);
      });
      unawaited(_refreshRunning());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _refreshRunning() async {
    try {
      final r = await _api.listSubagents(widget.parentSessionId);
      if (!mounted) return;
      final me = r.entries
          .where((e) => e.sessionId == widget.childSessionId)
          .firstOrNull;
      final running = me?.running ?? false;
      setState(() => _running = running);
      if (running) {
        _maybePoll();
      } else {
        _stopPoll();
      }
    } catch (_) {}
  }

  void _maybePoll() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      try {
        final results = await Future.wait<Object?>([
          _api.subagentHistoryBundle(
            widget.parentSessionId,
            widget.childSessionId,
            mode: widget.mode,
          ),
          _api.listSubagents(widget.parentSessionId),
        ]);
        if (!mounted) return;
        final bundle = results[0] as DshSubagentHistoryBundle;
        final list =
            (results[1]
                    as ({List<DshSubagentEntry> entries, bool parentAvailable}))
                .entries;
        final me = list
            .where((e) => e.sessionId == widget.childSessionId)
            .firstOrNull;
        final running = me?.running ?? false;
        final messageCountChanged = bundle.messages.length != _messages.length;
        final liveWasOpen = _live.open && _live.hasVisible;
        setState(() {
          _messages = bundle.messages;
          _summary = bundle.summary;
          _running = running;
        });
        _adoptLive(bundle.live, force: true);
        final liveStarted =
            !liveWasOpen && bundle.live.open && bundle.live.hasVisible;
        if (messageCountChanged || liveStarted) {
          _scrollToBottom();
        }
        if (!running && !bundle.live.open && !_sending) {
          _stopPoll();
        }
      } catch (_) {}
    });
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || !_continuable) return;
    _input.clear();
    setState(() => _sending = true);
    try {
      await _api.subagentPrompt(
        widget.parentSessionId,
        widget.childSessionId,
        text,
      );
      if (!mounted) return;
      setState(() {
        _messages.add(
          ChatMessage(
            id: 'sub-opt-${DateTime.now().millisecondsSinceEpoch}',
            sessionId: widget.childSessionId,
            role: 'assistant',
            content: '<子代理提示词注入>\n$text',
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        _sending = false;
        _running = true;
      });
      _live.begin();
      _ensureLiveBubble();
      _scrollToBottom();
      _maybePoll();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败：$e')));
    }
  }

  Future<void> _stop() async {
    if (_stopping || !_continuable) return;
    setState(() => _stopping = true);
    try {
      await _api.subagentInterrupt(
        widget.parentSessionId,
        widget.childSessionId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() => _running = false);
      _clearLiveUi();
      _stopPoll();
      final bundle = await _api.subagentHistoryBundle(
        widget.parentSessionId,
        widget.childSessionId,
        mode: widget.mode,
      );
      if (!mounted) return;
      setState(() {
        _messages = bundle.messages;
        _summary = bundle.summary;
      });
      _adoptLive(bundle.live, force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('停止失败：$e')));
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty || !mounted) return;
    final paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    final extra = paths.join('\n');
    final cur = _input.text;
    _input.text = cur.isEmpty ? extra : '$cur\n$extra';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _adoptLive(DshLiveTurn live, {bool force = false}) {
    _live.replaceWith(live);
    if (_live.open && _live.hasVisible) {
      _ensureLiveBubble(notify: false);
      _publishLive(force: force);
      if (mounted) setState(() {});
    } else if (!_live.open) {
      _clearLiveUi();
    }
  }

  void _ensureLiveBubble({bool notify = true}) {
    final last = _messages.isEmpty ? null : _messages.last;
    if (last != null && last.streaming && last.role == 'assistant') {
      if (_live.toolCalls.isNotEmpty) {
        last.toolCalls = List.of(_live.toolCalls);
      }
      return;
    }
    _messages.add(
      ChatMessage(
        id: _liveId,
        sessionId: widget.childSessionId,
        role: 'assistant',
        content: '',
        streaming: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        toolCalls: List.of(_live.toolCalls),
      ),
    );
    if (notify && mounted) setState(() {});
  }

  void _clearLiveUi() {
    _live.reset();
    _streamText.value = '';
    _streamReasoning.value = '';
    _messages.removeWhere((m) => m.streaming || m.id == _liveId);
    if (mounted) setState(() {});
  }

  void _publishLive({bool force = false}) {
    _streamReasoning.value = _live.reasoning;
    _streamText.value = _live.text;
  }

  void _onStreamTextChanged() {
    if (!_followTail) return;
    if (_autoScrollScheduled) return;
    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      if (_nearBottom) {
        _scroll.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions || !pos.maxScrollExtent.isFinite) return true;
    return pos.maxScrollExtent - pos.pixels <= 96;
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null)) {
      _followTail = _nearBottom;
    }
    return false;
  }

  void _scrollToBottom({bool animated = true, bool force = false}) {
    if (!force && !_followTail) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animated) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  void _copy(ChatMessage msg) {
    Clipboard.setData(ClipboardData(text: msg.content));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制')));
  }

  void _pop() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop =
        Platform.isWindows && MediaQuery.sizeOf(context).width >= 720;
    final events = _toolEvents;
    return Stack(
      children: [
        ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: Center(
            child: ConstrainedBox(
              constraints: desktop
                  ? const BoxConstraints(maxWidth: 1080)
                  : const BoxConstraints(),
              child: Scaffold(
                backgroundColor: theme.scaffoldBackgroundColor,
                appBar: AppBar(
                  leadingWidth: 104,
                  leading: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Platform.isWindows
                          ? MacActionButton(
                              icon: CupertinoIcons.chevron_left,
                              tooltip: '返回',
                              onTap: _pop,
                            )
                          : TrafficLightsButton(
                              busy: _lightsBusy,
                              tooltip: '返回',
                              onTap: _pop,
                            ),
                    ),
                  ),
                  actions: [
                    SizedBox(
                      width: 104,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Center(
                          child: events.isEmpty
                              ? ToolPillIdle(
                                  onTap: () => setState(
                                    () => _showToolLog = !_showToolLog,
                                  ),
                                )
                              : ToolPill(
                                  event: events.last,
                                  index: events.length,
                                  total: events.length,
                                  onTap: () => setState(
                                    () => _showToolLog = !_showToolLog,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                  toolbarHeight: 64,
                  centerTitle: true,
                  backgroundColor: theme.scaffoldBackgroundColor,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  clipBehavior: Clip.none,
                  title: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.title.isEmpty ? '子代理' : widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _statusLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall!.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                body: Column(
                  children: [
                    Expanded(child: _buildMessages()),
                    DshStatsBar(summary: _summary),
                    if (_continuable)
                      _SubagentComposer(
                        input: _input,
                        busy: _sending || _running,
                        onPickAttachment: _pickAttachment,
                        onSend: _send,
                        onStop: _stopping ? () {} : _stop,
                      )
                    else
                      _SubagentStatusFooter(running: _running),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_showToolLog)
          Positioned(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
            right: 8,
            width: 280,
            child: ToolLogPanel(
              events: events,
              onClose: () => setState(() => _showToolLog = false),
            ),
          ),
      ],
    );
  }

  String get _statusLine {
    final mode = _continuable ? '可继续对话' : '一次性';
    return '$mode · ${_running ? '运行中' : '已完成'}';
  }

  Widget _buildMessages() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.exclamationmark_triangle,
                size: 40,
                color: CupertinoColors.systemRed,
              ),
              const SizedBox(height: 12),
              const Text(
                '无法读取子代理历史',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
              const SizedBox(height: 14),
              CupertinoButton.filled(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final visible = _visible;
    if (_messages.isEmpty || visible.isEmpty) {
      return _SubagentEmpty(
        continuable: _continuable,
        onPick: (s) {
          _input.text = s;
          _send();
        },
      );
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(
            messageListSidePadding,
            12,
            messageListSidePadding,
            12,
          ),
          itemCount: visible.length,
          itemBuilder: (context, i) {
            final m = visible[i];
            if (m.streaming) {
              return KeyedSubtree(
                key: ValueKey(m.id),
                child: ValueListenableBuilder<String>(
                  valueListenable: _streamReasoning,
                  builder: (context, reasoning, _) =>
                      ValueListenableBuilder<String>(
                        valueListenable: _streamText,
                        builder: (context, text, _) => MessageBubble(
                          message: m,
                          liveContent: text.isEmpty ? null : text,
                          liveReasoning: reasoning.isEmpty ? null : reasoning,
                          busy: true,
                          smoothHeightAnimation: false,
                          onCopy: _copy,
                        ),
                      ),
                ),
              );
            }
            return KeyedSubtree(
              key: ValueKey(m.id),
              child: RepaintBoundary(
                child: MessageBubble(message: m, busy: false, onCopy: _copy),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SubagentEmpty extends StatelessWidget {
  final bool continuable;
  final ValueChanged<String> onPick;
  const _SubagentEmpty({required this.continuable, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: .10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              CupertinoIcons.rectangle_stack_person_crop,
              size: 34,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          continuable ? '子代理等待指令' : '子代理会话暂无消息',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge!.copyWith(height: 1.3),
        ),
        const SizedBox(height: 8),
        Text(
          continuable ? '历史与运行状态会实时同步' : '运行完成后可回到会话查看结果',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium!.copyWith(color: theme.hintColor),
        ),
        if (continuable) ...[
          const SizedBox(height: 28),
          for (final s in const ['继续分析刚才的结果', '把结论整理成清单', '基于当前会话上下文继续'])
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

/// 子代理输入框：拾忆会话页同款壳，busy 时切换为停止按钮。
class _SubagentComposer extends StatelessWidget {
  final TextEditingController input;
  final bool busy;
  final VoidCallback onPickAttachment;
  final VoidCallback onSend;
  final VoidCallback onStop;
  const _SubagentComposer({
    required this.input,
    required this.busy,
    required this.onPickAttachment,
    required this.onSend,
    required this.onStop,
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
      final text = input.text;
      final sel = input.selection;
      final start = sel.isValid ? sel.start : text.length;
      final end = sel.isValid ? sel.end : text.length;
      input.text = text.replaceRange(start, end, '\n');
      input.selection = TextSelection.collapsed(offset: start + 1);
      return true;
    }
    onSend();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: dark ? const Color(0xCC1C1C1E) : const Color(0xD9F2F2F7),
        border: Border(
          top: BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: .12)
                : Colors.black.withValues(alpha: .08),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
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
                tooltip: '添加文件路径',
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
                      ? const Color(0xFF2C2C2E)
                      : const Color(0xFFE5E5EA),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Focus(
                  onKeyEvent: (node, event) => _handleKey(event)
                      ? KeyEventResult.handled
                      : KeyEventResult.ignored,
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 16,
                      height: 1.25,
                    ),
                    decoration: InputDecoration(
                      hintText: busy ? '子代理运行中…' : '给子代理下指令…',
                      hintStyle: TextStyle(color: theme.hintColor),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
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
                final hasInput = value.text.trim().isNotEmpty;
                if (busy) {
                  return IconButton(
                    onPressed: onStop,
                    tooltip: '停止',
                    icon: const Icon(
                      CupertinoIcons.stop_circle_fill,
                      size: 32,
                      color: _iosRed,
                    ),
                  );
                }
                return IconButton(
                  onPressed: hasInput ? onSend : null,
                  icon: Icon(
                    hasInput
                        ? CupertinoIcons.arrow_up_circle_fill
                        : CupertinoIcons.arrow_up_circle,
                    size: 32,
                    color: hasInput
                        ? _iosBlue
                        : dark
                        ? const Color(0xFF48484A)
                        : const Color(0xFFC7C7CC),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 一次性子代理的只读状态脚栏：不提供继续对话，只显示运行/完成。
class _SubagentStatusFooter extends StatelessWidget {
  final bool running;
  const _SubagentStatusFooter({required this.running});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: dark ? const Color(0xCC1C1C1E) : const Color(0xD9F2F2F7),
        border: Border(
          top: BorderSide(
            color: dark
                ? Colors.white.withValues(alpha: .12)
                : Colors.black.withValues(alpha: .08),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (running)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                CupertinoIcons.checkmark_circle_fill,
                size: 17,
                color: Color(0xFF28C840),
              ),
            const SizedBox(width: 8),
            Text(
              running ? '一次性子代理运行中' : '一次性子代理已完成',
              style: theme.textTheme.labelMedium!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
