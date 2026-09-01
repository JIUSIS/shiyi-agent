import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/group_chat.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../core/reasoning_models.dart';
import '../services/group_chat_store.dart';
import '../services/llm_client.dart';
import '../widgets/bagua_icon.dart';
import '../widgets/chat_liquid_glass.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/message_bubble.dart';
import '../widgets/traffic_lights_button.dart';
import 'group_chat_setup_screen.dart';

class GroupChatScreen extends StatefulWidget {
  final ShiyiState shiyi;
  final String roomId;
  const GroupChatScreen({super.key, required this.shiyi, required this.roomId});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _AgentTurnResult {
  final GroupMessage? message;
  final bool failed;

  const _AgentTurnResult({this.message, this.failed = false});
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _followTail = true;
  final _store = GroupChatStore.instance;
  GroupRoom? _room;
  List<GroupMessage> _messages = [];
  bool _loading = true;
  bool _busy = false;
  bool _stop = false;
  Completer<void>? _roundCompleter;
  final Set<LlmClient> _activeClients = {};
  final Set<String> _enteredIds = {};
  int _roundCachedTokens = 0;
  int _roundInputTokens = 0;
  bool _roundCacheKnown = false;
  int _sessionCachedTokens = 0;
  int _sessionInputTokens = 0;
  bool _sessionCacheKnown = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncFollowTail);
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_syncFollowTail);
    _stop = true;
    for (final client in List.of(_activeClients)) {
      client.cancel();
    }
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final room = await _store.getRoom(widget.roomId);
    final messages = await _store.listMessages(widget.roomId);
    if (!mounted) return;
    setState(() {
      _room = room;
      _messages = messages;
      _loading = false;
    });
  }

  Future<void> _editMembers() async {
    final room = _room;
    if (room == null) return;
    final changed = await Navigator.push<bool>(
      context,
      MacPageRoute(
        builder: (_) => GroupChatSetupScreen(shiyi: widget.shiyi, room: room),
      ),
    );
    if (changed == true) await _reload();
  }

  void _insertMention(GroupAgent agent) {
    final token = '@${agent.name} ';
    final text = _input.text;
    if (text.contains('@${agent.name}')) return;
    _input.text = text.isEmpty ? token : '$text$token';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    setState(() {});
  }

  Future<void> _send() async {
    final room = _room;
    if (room == null) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (room.agents.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先去编辑成员，至少加一个 Agent')));
      return;
    }

    if (_busy) {
      // 忙时先打断当前轮，等它退出后再开新轮，避免用户被锁死。
      _stopRun();
      final prev = _roundCompleter;
      if (prev != null) await prev.future;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final user = GroupMessage(
      id: groupChatNewId('gm'),
      roomId: room.id,
      role: 'user',
      content: text,
      createdAt: now,
    );
    _input.clear();
    final completer = Completer<void>();
    _roundCompleter = completer;
    setState(() {
      _messages = [..._messages, user];
      _busy = true;
      _stop = false;
      _roundCachedTokens = 0;
      _roundInputTokens = 0;
      _roundCacheKnown = false;
    });
    try {
      await _store.insertMessage(user);
      _jumpToLatest(force: true);
      final reworkCounts = <String, int>{};
      final queue = [...groupChatInitialTargets(text, room.agents)];
      while (queue.isNotEmpty && !_stop && mounted) {
        final batch = <GroupAgent>[];
        while (batch.length < groupChatMaxParallelAgents && queue.isNotEmpty) {
          final agent = queue.removeAt(0);
          batch.add(agent);
        }
        if (batch.isEmpty) continue;
        final results = await Future.wait([
          for (final agent in batch) _runAgent(agent),
        ]);
        if (_stop || !mounted) break;
        if (results.any((result) => result.failed)) break;
        final followups = groupChatNextFollowupTargets(
          speakers: batch,
          replies: [for (final result in results) result.message],
          agents: room.agents,
        );
        for (final followup in followups) {
          if (followup.isRework) {
            final count = (reworkCounts[followup.handoffKey] ?? 0) + 1;
            reworkCounts[followup.handoffKey] = count;
            if (count > groupChatMaxReworksPerHandoff) continue;
          }
          if (queue.any((item) => item.id == followup.target.id)) continue;
          queue.add(followup.target);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<_AgentTurnResult> _runAgent(GroupAgent agent) async {
    final room = _room;
    if (room == null) return const _AgentTurnResult();
    final profile = groupChatProfileFor(
      agent,
      widget.shiyi.apiProfiles,
      fallback: widget.shiyi.apiProfiles.isEmpty
          ? ApiProfile(
              name: '当前',
              baseUrl: widget.shiyi.settings.baseUrl,
              apiKey: widget.shiyi.settings.apiKey,
              model: widget.shiyi.settings.model,
              apiProtocol: widget.shiyi.settings.apiProtocol,
            )
          : null,
    );
    if (profile == null || profile.baseUrl.trim().isEmpty) {
      if (!mounted) return const _AgentTurnResult(failed: true);
      final message = '${agent.name} 还没有可用的 API 配置';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return _AgentTurnResult(
        failed: true,
        message: await _failedDraft(room, agent, message),
      );
    }
    final model = agent.model.trim().isEmpty ? profile.model : agent.model;
    if (model.trim().isEmpty) {
      if (!mounted) return const _AgentTurnResult(failed: true);
      final message = '${agent.name} 还没有模型 ID';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return _AgentTurnResult(
        failed: true,
        message: await _failedDraft(room, agent, message),
      );
    }
    final draft = GroupMessage(
      id: groupChatNewId('gm'),
      roomId: room.id,
      role: 'agent',
      agentId: agent.id,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      streaming: true,
    );
    setState(() => _messages = [..._messages, draft]);
    _jumpToLatest();
    final settings = widget.shiyi.settings;
    var lastEmit = DateTime.now();
    final client = LlmClient(
      baseUrl: profile.baseUrl,
      apiKey: profile.apiKey,
      model: model,
      protocol: profile.apiProtocol,
      sessionId: room.id,
      temperature: settings.temperature,
      maxTokens: settings.maxOutputTokens,
      tools: const [],
      reasoningEffortOverride: ReasoningModels.defaultEffort(model),
      shouldStop: () => _stop,
      onTurn: (turn) {
        draft.content = turn.text;
        draft.reasoning = turn.reasoning;
        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds < 50) return;
        lastEmit = now;
        if (mounted) setState(() {});
        _jumpToLatest();
      },
    );
    _activeClients.add(client);
    String? failure;
    try {
      await client.send(
        groupChatApiMessages(
          speaker: agent,
          agents: room.agents,
          history: _messages.where((m) => m.id != draft.id).toList(),
        ),
      );
    } on LlmCancelledException {
      // 用户点了停止，保留已经流出来的内容。
    } catch (e) {
      failure = e.toString();
      final text = draft.content.trim();
      draft.content = text.isEmpty ? '回复失败：$failure' : '$text\n\n回复失败：$failure';
    } finally {
      _activeClients.remove(client);
    }
    final cached = client.lastCachedTokens;
    final input = client.lastPromptTokens ?? client.lastInputTokens;
    if (mounted && cached != null && input != null && input > 0) {
      final hit = cached.clamp(0, input).toInt();
      setState(() {
        _roundCachedTokens += hit;
        _roundInputTokens += input;
        _roundCacheKnown = true;
        _sessionCachedTokens += hit;
        _sessionInputTokens += input;
        _sessionCacheKnown = true;
      });
    }
    draft.streaming = false;
    if (failure == null &&
        draft.content.trim().isEmpty &&
        draft.reasoning.trim().isEmpty) {
      failure = '模型返回为空';
      draft.content = '回复失败：$failure';
    }
    if (failure != null && draft.content.trim().isEmpty) {
      draft.content = '回复失败：$failure';
    }
    if (failure == null &&
        draft.content.trim().isEmpty &&
        draft.reasoning.trim().isEmpty) {
      setState(() {
        _messages = [
          for (final item in _messages)
            if (item.id != draft.id) item,
        ];
      });
      return const _AgentTurnResult(failed: true);
    }
    await _store.insertMessage(draft);
    if (mounted) setState(() {});
    _jumpToLatest();
    return _AgentTurnResult(message: draft, failed: failure != null);
  }

  Future<GroupMessage?> _failedDraft(
    GroupRoom room,
    GroupAgent agent,
    String message,
  ) async {
    final draft = GroupMessage(
      id: groupChatNewId('gm'),
      roomId: room.id,
      role: 'agent',
      agentId: agent.id,
      content: message,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _store.insertMessage(draft);
    if (mounted) {
      setState(() => _messages = [..._messages, draft]);
      _jumpToLatest();
    }
    return draft;
  }

  void _stopRun() {
    _stop = true;
    for (final client in List.of(_activeClients)) {
      client.cancel();
    }
  }

  bool _shouldAnimateEnter(GroupMessage message) {
    if (_enteredIds.contains(message.id)) return false;
    var should = false;
    if (message.isUser) {
      final now = DateTime.now().millisecondsSinceEpoch;
      should = message.createdAt > 0 && now - message.createdAt < 2500;
    } else if (message.streaming) {
      should = true;
    }
    if (should) _enteredIds.add(message.id);
    return should;
  }

  void _jumpToLatest({bool force = false}) {
    if (force) _followTail = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (!_followTail) return;
      _scroll.jumpTo(0);
    });
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.pixels <= 32;
  }

  void _syncFollowTail() {
    _followTail = _nearBottom;
  }

  ChatMessage _asChat(GroupMessage message) => ChatMessage(
    id: message.id,
    sessionId: message.roomId,
    role: message.isUser ? 'user' : 'assistant',
    content: message.content,
    reasoning: message.reasoning,
    createdAt: message.createdAt,
    streaming: message.streaming,
  );

  String _speakerName(GroupMessage message, GroupRoom room) {
    if (message.isUser) return '你';
    final agent = groupChatAgentById(message.agentId, room.agents);
    if (agent == null) return 'Agent';
    final role = agent.title.trim();
    if (role.isEmpty) return agent.name;
    return '${agent.name} · $role';
  }

  Color? _speakerColor(GroupMessage message, GroupRoom room) {
    if (message.isUser) return null;
    return groupChatAgentById(message.agentId, room.agents)?.color;
  }

  Future<void> _copyMessage(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.content));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制')));
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final ok = await showIosConfirmDialog(
      context: context,
      title: '删除这条消息？',
      message: '删除后不能恢复。',
      confirmLabel: '删除',
      isDestructiveAction: true,
    );
    if (!ok) return;
    await _store.deleteMessage(message.id);
    if (!mounted) return;
    setState(() {
      _messages = [
        for (final item in _messages)
          if (item.id != message.id) item,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final theme = Theme.of(context);
    final desktop =
        Platform.isWindows && MediaQuery.sizeOf(context).width >= 720;
    return MacBackFade(
      child: CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: Center(
            child: ConstrainedBox(
              constraints: desktop
                  ? const BoxConstraints(maxWidth: 1080)
                  : const BoxConstraints(),
              child: Scaffold(
                backgroundColor: theme.scaffoldBackgroundColor,
                appBar: AppBar(
                  leadingWidth: 72,
                  leading: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Platform.isWindows
                        ? MacActionButton(
                            icon: CupertinoIcons.chevron_left,
                            tooltip: '返回',
                            onTap: () => Navigator.pop(context),
                          )
                        : TrafficLightsButton(
                            busy: _busy,
                            tooltip: '返回',
                            onTap: () => Navigator.pop(context),
                          ),
                  ),
                  centerTitle: true,
                  backgroundColor: theme.scaffoldBackgroundColor,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  clipBehavior: Clip.none,
                  toolbarHeight: 64,
                  title: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        room?.title.isEmpty ?? true ? '群聊' : room!.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (room != null && room.agents.isNotEmpty)
                        Text(
                          '${room.agents.length} 个 Agent',
                          style: theme.textTheme.bodySmall!.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: FrostedSettingsButton(onPressed: _editMembers),
                    ),
                  ],
                ),
                body: _loading || room == null
                    ? const Center(child: CupertinoActivityIndicator())
                    : ChatFloatingComposerScaffold(
                        messages: (context, overlayHeight) {
                          if (_messages.isEmpty) {
                            return Padding(
                              padding: EdgeInsets.only(bottom: overlayHeight),
                              child: const _GroupEmpty(),
                            );
                          }
                          return ScrollConfiguration(
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(overscroll: false),
                            child: ListView.builder(
                              controller: _scroll,
                              reverse: true,
                              clipBehavior: Clip.none,
                              padding: EdgeInsets.fromLTRB(
                                messageListSidePadding,
                                12,
                                messageListSidePadding,
                                overlayHeight + 12,
                              ),
                              itemCount: _messages.length,
                              itemBuilder: (context, index) {
                                final message =
                                    _messages[_messages.length - 1 - index];
                                return MessageBubble(
                                  key: ValueKey(message.id),
                                  message: _asChat(message),
                                  busy: _busy,
                                  animateEnter: _shouldAnimateEnter(message),
                                  speakerName: _speakerName(message, room),
                                  speakerColor: _speakerColor(message, room),
                                  onCopy: _copyMessage,
                                  onDelete: _deleteMessage,
                                );
                              },
                            ),
                          );
                        },
                        overlay: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _mentionsWithStats(room.agents),
                            LiquidGlassChatComposer(
                              input: _input,
                              busy: _busy,
                              allowSendWhileBusy: true,
                              enterToSend: widget.shiyi.settings.enterToSend,
                              pendingImages: const [],
                              pendingFiles: const [],
                              onPickAttachment: () {},
                              onRemoveImage: (_) {},
                              onRemoveFile: (_) {},
                              onSend: _send,
                              onStop: _stopRun,
                              idleHint: '发给对接人，或点名字 @Ta',
                              busyHint: 'Agent 回复中…',
                              showAttachmentButton: false,
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _mentionChips(List<GroupAgent> agents) {
    if (agents.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: ChatComposerChip.height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final agent in agents)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChatComposerChip(
                tooltip: '点名 ${agent.name}',
                color: agent.color,
                onTap: () => _insertMention(agent),
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: agent.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('@${agent.name}'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  Widget _groupStatsChip() {
    final theme = Theme.of(context);
    final cacheText = !_sessionCacheKnown || _sessionInputTokens <= 0
        ? '缓存 --'
        : '缓存 ${(_sessionCachedTokens / _sessionInputTokens * 100).round()}%';
    final roundText = !_roundCacheKnown || _roundInputTokens <= 0
        ? '本轮命中 --'
        : '本轮命中 ${_fmt(_roundCachedTokens)}/未缓存 ${_fmt((_roundInputTokens - _roundCachedTokens).clamp(0, _roundInputTokens))}';
    return ChatStatsChip(
      label: cacheText,
      detail: '$cacheText · $roundText',
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  Widget _mentionsWithStats(List<GroupAgent> agents) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: [
          _groupStatsChip(),
          const SizedBox(width: 8),
          Expanded(child: _mentionChips(agents)),
        ],
      ),
    );
  }
}

class _GroupEmpty extends StatelessWidget {
  const _GroupEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BaguaIcon(size: 56, color: CupertinoColors.systemGrey3),
            const SizedBox(height: 12),
            const Text(
              '还没有消息',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              '发给对接人，或点上面的名字 @Ta',
              textAlign: TextAlign.center,
              style: TextStyle(color: CupertinoColors.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
