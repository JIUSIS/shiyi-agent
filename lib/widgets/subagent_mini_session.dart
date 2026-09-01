import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../core/models.dart';
import '../core/subagent_live.dart';
import 'chat_liquid_glass.dart';
import 'markdown_text.dart';
import 'smooth_stream_text.dart';
import 'tool_pill.dart';

const Color _iosBlue = Color(0xFF0A84FF);
const Color _iosGreen = Color(0xFF34C759);

double _safeClamp(double value, double min, double max) {
  if (!value.isFinite) {
    if (min.isFinite && min >= 0) return min;
    return 0;
  }
  final lo = min.isFinite ? min : value;
  var hi = max.isFinite ? max : value;
  if (hi < lo) hi = lo;
  if (hi < 0) return 0;
  return value.clamp(lo, hi);
}

/// 拾忆与 DSH 共用的子代理悬浮按钮。
/// 点击后从按钮上沿浮出 mini 会话；多个子代理左右滑动查看。
class SubagentStatusBar extends StatefulWidget {
  final String text;
  final List<SubagentLiveSnapshot> agents;
  final Future<SubagentLiveSnapshot> Function(SubagentLiveSnapshot agent)?
  resolveDetail;
  final ValueChanged<bool>? onOpenChanged;

  const SubagentStatusBar({
    super.key,
    required this.text,
    this.agents = const [],
    this.resolveDetail,
    this.onOpenChanged,
  });

  @override
  State<SubagentStatusBar> createState() => _SubagentStatusBarState();
}

class _SubagentStatusBarState extends State<SubagentStatusBar>
    with SingleTickerProviderStateMixin {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _layerLink = LayerLink();
  late final AnimationController _anim;
  late final Animation<double> _reveal;
  List<SubagentLiveSnapshot> _pinned = const [];
  final Map<String, SubagentLiveSnapshot> _resolved = {};
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 140),
    );
    _reveal = CurvedAnimation(
      parent: _anim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  List<SubagentLiveSnapshot> get _sourceAgents {
    if (widget.agents.isNotEmpty) return widget.agents;
    if (widget.text.trim().isEmpty) return const [];
    return <SubagentLiveSnapshot>[
      SubagentLiveSnapshot(id: 'status', title: '子代理', subtitle: widget.text),
    ];
  }

  List<SubagentLiveSnapshot> get _agentsForPopup {
    final latest = {for (final item in _sourceAgents) item.id: item};
    if (_pinned.isEmpty) return _sourceAgents;
    final out = <SubagentLiveSnapshot>[];
    final seen = <String>{};
    for (final item in _pinned) {
      seen.add(item.id);
      final fresh = latest[item.id];
      var next = fresh ?? item.copyWith(running: false);
      final resolved = _resolved[item.id];
      if (resolved != null) {
        next = next.copyWith(
          messages: resolved.messages,
          liveContent: resolved.liveContent,
          liveReasoning: resolved.liveReasoning,
          prompt: resolved.prompt.isEmpty ? next.prompt : resolved.prompt,
        );
      }
      out.add(next);
    }
    for (final item in _sourceAgents) {
      if (seen.add(item.id)) {
        out.add(_resolved[item.id] ?? item);
      }
    }
    return out;
  }

  String get _chipLabel {
    final agents = _sourceAgents;
    final running = agents.where((item) => item.running).length;
    if (running > 1) return '子代理 $running';
    if (agents.length > 1 && running == 0) {
      return '子代理 ${agents.length}';
    }
    return '子代理';
  }

  String get _chipTooltip {
    final text = widget.text.trim();
    return text.isEmpty ? _chipLabel : text;
  }

  bool get _anyRunning => _sourceAgents.any((item) => item.running);

  void _togglePopup() {
    if (_portal.isShowing) {
      unawaited(_hide());
    } else {
      _show();
    }
  }

  void _show() {
    if (_portal.isShowing) return;
    _pinned = List<SubagentLiveSnapshot>.of(_sourceAgents);
    _resolved.clear();
    HapticFeedback.selectionClick();
    _portal.show();
    _anim.forward(from: 0);
    widget.onOpenChanged?.call(true);
    if (mounted) setState(() {});
  }

  Future<void> _hide() async {
    if (!_portal.isShowing) return;
    if (_closing) return;
    _closing = true;
    if (_anim.value > 0) {
      try {
        await _anim.reverse();
      } catch (_) {}
    }
    if (!mounted) return;
    _portal.hide();
    _pinned = const [];
    _resolved.clear();
    _closing = false;
    widget.onOpenChanged?.call(false);
    if (mounted) setState(() {});
  }

  Future<void> _loadDetail(SubagentLiveSnapshot agent) async {
    final resolve = widget.resolveDetail;
    if (resolve == null) return;
    try {
      final next = await resolve(agent);
      if (!mounted || !_portal.isShowing) return;
      _resolved[agent.id] = next;
      setState(() {});
    } catch (_) {}
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    return _SubagentMiniOverlay(
      link: _layerLink,
      agents: _agentsForPopup,
      reveal: _reveal,
      resolveDetail: widget.resolveDetail == null ? null : _loadDetail,
      onDismiss: _hide,
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _anyRunning;
    return PopScope(
      canPop: !_portal.isShowing,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) unawaited(_hide());
      },
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildOverlay,
        child: CompositedTransformTarget(
          link: _layerLink,
          child: ChatComposerChip(
            tooltip: _chipTooltip,
            chipKey: const ValueKey('subagent-live-chip'),
            onTap: _togglePopup,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: running ? _iosGreen : theme.disabledColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(_chipLabel),
              if (running) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CupertinoActivityIndicator(radius: 5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SubagentMiniOverlay extends StatefulWidget {
  final LayerLink link;
  final List<SubagentLiveSnapshot> agents;
  final Animation<double> reveal;
  final Future<void> Function(SubagentLiveSnapshot agent)? resolveDetail;
  final VoidCallback onDismiss;

  const _SubagentMiniOverlay({
    required this.link,
    required this.agents,
    required this.reveal,
    required this.onDismiss,
    this.resolveDetail,
  });

  @override
  State<_SubagentMiniOverlay> createState() => _SubagentMiniOverlayState();
}

class _SubagentMiniOverlayState extends State<_SubagentMiniOverlay> {
  late final PageController _page;
  Timer? _detailPoll;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = _initialIndex(widget.agents);
    _page = PageController(initialPage: _index);
    _startDetailPoll();
    final first = _currentAgent;
    if (first != null) {
      unawaited(_resolve(first));
    }
  }

  int _initialIndex(List<SubagentLiveSnapshot> agents) {
    final running = agents.indexWhere((item) => item.running);
    if (running >= 0) return running;
    return 0;
  }

  SubagentLiveSnapshot? get _currentAgent {
    if (widget.agents.isEmpty) return null;
    final i = _index.clamp(0, widget.agents.length - 1);
    return widget.agents[i];
  }

  @override
  void didUpdateWidget(covariant _SubagentMiniOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.agents.isEmpty) return;
    if (_index >= widget.agents.length) {
      _index = widget.agents.length - 1;
      if (_page.hasClients) {
        _page.jumpToPage(_index);
      }
    }
  }

  void _startDetailPoll() {
    _stopDetailPoll();
    if (widget.resolveDetail == null) return;
    _detailPoll = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final agent = _currentAgent;
      if (agent == null) return;
      unawaited(_resolve(agent));
    });
  }

  void _stopDetailPoll() {
    _detailPoll?.cancel();
    _detailPoll = null;
  }

  Future<void> _resolve(SubagentLiveSnapshot agent) async {
    final resolve = widget.resolveDetail;
    if (resolve == null) return;
    await resolve(agent);
  }

  @override
  void dispose() {
    _stopDetailPoll();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final mq = MediaQuery.of(context);
    final availW = mq.size.width - 24;
    final minW = availW < 168 ? (availW < 0 ? 0.0 : availW) : 168.0;
    final panelWidth = _safeClamp(280, minW, availW);
    final availH = mq.size.height * 0.38;
    final minH = availH < 168 ? (availH < 0 ? 0.0 : availH) : 168.0;
    final panelHeight = _safeClamp(248, minH, availH);
    final agents = widget.agents;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(0, -6),
          child: SizeTransition(
            sizeFactor: widget.reveal,
            alignment: Alignment.bottomLeft,
            child: Material(
              color: Colors.transparent,
              elevation: 12,
              shadowColor: Colors.black.withValues(alpha: dark ? .36 : .14),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: LiquidGlassLens(
                style: chatLiquidGlassStyle(context, cornerRadius: 14),
                child: SizedBox(
                  width: panelWidth,
                  height: panelHeight,
                  child: agents.isEmpty
                      ? const Center(child: Text('暂无子代理'))
                      : Column(
                          children: [
                            _header(context),
                            Expanded(
                              child: PageView.builder(
                                key: const ValueKey('subagent-mini-session'),
                                controller: _page,
                                itemCount: agents.length,
                                onPageChanged: (index) {
                                  setState(() => _index = index);
                                  unawaited(_resolve(agents[index]));
                                },
                                itemBuilder: (context, index) {
                                  return _MiniSessionPage(agent: agents[index]);
                                },
                              ),
                            ),
                            if (agents.length > 1)
                              _dots(context, agents.length),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final agent = _currentAgent;
    final title = agent == null || agent.title.isEmpty ? '子代理' : agent.title;
    final subtitle = agent == null
        ? ''
        : (agent.subtitle.isEmpty
              ? (agent.running ? '运行中' : '已完成')
              : agent.subtitle);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              height: 22 / 17,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                height: 18 / 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _dots(BuildContext context, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: i == _index ? 6 : 5,
              height: i == _index ? 6 : 5,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: i == _index ? _iosBlue : Theme.of(context).disabledColor,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }
}

class _MiniSessionPage extends StatefulWidget {
  final SubagentLiveSnapshot agent;

  const _MiniSessionPage({required this.agent});

  @override
  State<_MiniSessionPage> createState() => _MiniSessionPageState();
}

class _MiniSessionPageState extends State<_MiniSessionPage>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();
  bool _followTail = true;

  @override
  bool get wantKeepAlive => true;

  bool _nearBottom([double threshold = 8]) {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions || !pos.maxScrollExtent.isFinite) {
      return true;
    }
    return pos.maxScrollExtent - pos.pixels <= threshold;
  }

  void _stickToBottomIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_followTail || !_scroll.hasClients) return;
      final pos = _scroll.position;
      if (!pos.hasContentDimensions) return;
      final extent = pos.maxScrollExtent;
      if (!extent.isFinite) return;
      if ((pos.pixels - extent).abs() > 1) {
        _scroll.jumpTo(extent);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _MiniSessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_followTail) _stickToBottomIfNeeded();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<ChatMessage> _messagesFor(SubagentLiveSnapshot agent) {
    final out = List<ChatMessage>.of(agent.messages);
    if (agent.prompt.isNotEmpty &&
        !out.any(
          (m) => m.role == 'user' && m.content.trim() == agent.prompt.trim(),
        )) {
      out.insert(
        0,
        ChatMessage(
          id: '${agent.id}-prompt',
          sessionId: agent.id,
          role: 'user',
          content: agent.prompt,
          createdAt: 0,
        ),
      );
    }
    final hasLive =
        agent.liveContent.isNotEmpty || agent.liveReasoning.isNotEmpty;
    if (!hasLive) return out;
    final last = out.isEmpty ? null : out.last;
    if (last != null && last.streaming) return out;
    out.add(
      ChatMessage(
        id: '${agent.id}-live',
        sessionId: agent.id,
        role: 'assistant',
        content: agent.liveContent,
        reasoning: agent.liveReasoning,
        streaming: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return out;
  }

  bool _hideEmptyToolBubble(ChatMessage m) {
    return m.role == 'assistant' &&
        !m.streaming &&
        m.content.trim().isEmpty &&
        m.reasoning.trim().isEmpty &&
        m.hasToolCalls;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final agent = widget.agent;
    final messages = _messagesFor(agent);
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Text(
            agent.running ? '子代理正在启动…' : '暂无消息',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    _stickToBottomIfNeeded();
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification && n.dragDetails != null) {
          if ((n.scrollDelta ?? 0) < 0) {
            _followTail = false;
          } else if (_nearBottom()) {
            _followTail = true;
          }
        } else if (n is ScrollEndNotification) {
          _followTail = _nearBottom();
        }
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('subagent-mini-session-scroll'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final m = messages[index];
          final live = m.streaming;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_hideEmptyToolBubble(m))
                  _MiniBubble(
                    message: m,
                    liveContent: live ? agent.liveContent : null,
                    liveReasoning: live ? agent.liveReasoning : null,
                    busy: live,
                  ),
                if (m.hasToolCalls) _toolChips(context, m.toolCalls),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _toolChips(BuildContext context, List<ToolCall> calls) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final call in calls)
            ChatComposerChip(
              tooltip: toolEventLabel(call.name),
              children: [
                const Icon(CupertinoIcons.wrench),
                const SizedBox(width: 6),
                Text(toolEventLabel(call.name)),
              ],
            ),
        ],
      ),
    );
  }
}

class _MiniBubble extends StatelessWidget {
  final ChatMessage message;
  final String? liveContent;
  final String? liveReasoning;
  final bool busy;

  const _MiniBubble({
    required this.message,
    this.liveContent,
    this.liveReasoning,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final isUser = message.role == 'user';
    final content =
        ((liveContent != null && liveContent!.isNotEmpty)
                ? liveContent!
                : message.content)
            .trim();
    final reasoning =
        ((liveReasoning != null && liveReasoning!.isNotEmpty)
                ? liveReasoning!
                : message.reasoning)
            .trim();
    if (content.isEmpty && reasoning.isEmpty) return const SizedBox.shrink();
    final bg = isUser
        ? _iosBlue.withValues(alpha: dark ? 0.42 : 0.16)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.78);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (reasoning.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: content.isEmpty ? 0 : 4),
                    child: SmoothStreamText(
                      reasoning,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        height: 16 / 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (content.isNotEmpty)
                  AdaptiveMarkdownText(
                    content,
                    isStreaming: busy,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      height: 20 / 14,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
