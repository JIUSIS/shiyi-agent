import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path/path.dart' as p;

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../core/models.dart';
import '../core/subagent_live.dart';
import '../core/slash_trigger.dart';
import '../services/dsh_api.dart';
import '../services/dsh_chat_cache.dart';
import '../services/dsh_endpoint.dart';
import '../services/dsh_live.dart';
import '../services/dsh_model_sync.dart';
import '../services/dsh_provider_config.dart';
import '../services/dsh_service.dart';
import '../services/dsh_turn_command_queue.dart';
import '../services/file_workspace.dart';
import '../services/image_service.dart';
import '../services/runtime_logger.dart';
import '../services/tts_service.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/message_bubble.dart';
import '../widgets/agent_question_panel.dart';
import '../widgets/chat_liquid_glass.dart';
import '../widgets/subagent_mini_session.dart';
import '../widgets/dsh_directory_picker.dart';
import '../widgets/dsh_stats_bar.dart';
import '../widgets/tool_pill.dart';
import '../widgets/ios_style.dart';
import '../widgets/traffic_lights_button.dart';
import '../widgets/welcome_avatar.dart';

/// 本机 DSH 先读取本地会话快照，再开始整页淡入；局域网 / 公网直接请求
/// 目标 DSH，禁止把手机快照显示成远端当前页面。
///
/// 这样路由动画期间页面内容保持稳定，避免进入后加载态、缓存态和远端历史
/// 连续换帧，形成明显的“两段感”。
Future<void> openDshChat(
  BuildContext context, {
  required String sessionId,
  required String initialTitle,
  String initialInput = '',
  DshSessionSummary? initialSummary,
  ShiyiState? shiyi,
}) async {
  DshChatSnapshot? snapshot;
  if (!DshEndpoint.requiresLivePageData(shiyi?.settings)) {
    try {
      snapshot = await DshChatCache.read(sessionId);
    } catch (_) {}
  }
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MacPageRoute<void>(
      builder: (_) => DshChatScreen(
        sessionId: sessionId,
        initialTitle: initialTitle,
        initialInput: initialInput,
        initialSummary: initialSummary,
        initialSnapshot: snapshot,
        shiyi: shiyi,
      ),
    ),
  );
}

/// DSH 聊天页：拾忆会话页同款壳，数据走 DeepSeek Harness。
class DshChatScreen extends StatefulWidget {
  final String sessionId;
  final String initialTitle;
  final String initialInput;
  final DshSessionSummary? initialSummary;
  final DshChatSnapshot? initialSnapshot;
  final ShiyiState? shiyi;
  const DshChatScreen({
    super.key,
    required this.sessionId,
    required this.initialTitle,
    this.initialInput = '',
    this.initialSummary,
    this.initialSnapshot,
    this.shiyi,
  });

  @override
  State<DshChatScreen> createState() => _DshChatScreenState();
}

class _DshChatScreenState extends State<DshChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  bool _loading = true;
  String? _error;
  bool _waitingService = false;
  Timer? _loadRetryTimer;
  bool _sending = false;
  late bool _running = widget.initialSummary?.running ?? false;
  Timer? _pollTimer;
  Timer? _subagentPollTimer;
  bool _refreshingSubagents = false;
  List<DshSubagentEntry> _subagents = [];
  int _subagentRefreshGeneration = 0;
  final Set<String> _syncedResponseModels = {};
  late String _title = widget.initialTitle;
  late String _model = widget.shiyi?.settings.model.trim() ?? '';
  String _provider = '';
  String _selectedRelayProfileId = '';
  DshRelayLease? _activeRelayLease;
  List<SessionModelOption> _dshModelOptions = const [];
  List<PermissionPresetOption> _permissionOptions = const [];
  String _permissionDefault = '';

  /// 当前会话生效的权限预设（permission/preset 事件折叠）；空 = 未显式
  /// 选过，显示创建时的组合默认（用服务器 defaultPreset 估计）。
  String _sessionPermission = '';
  late bool _selectedModelTargetDsh;
  String _reasoningEffort = '';
  String _lastNonOffEffort = '';
  Map<String, String?> _reasoningCapabilities = const {};
  bool _compacting = false;
  int _contextLimit = kDefaultContextLimit;
  late String _cwd = widget.initialSummary?.cwd ?? '';
  bool _stopping = false;
  bool _ignoreLateRunningStatus = false;
  int _sendGeneration = 0;
  DateTime? _lastSendAt;
  bool _showToolLog = false;
  bool _subagentPeekOpen = false;
  final Map<String, SubagentLiveSnapshot> _subagentDetails = {};
  String? _speakingId;
  late DshSessionSummary? _summary = widget.initialSummary;
  Map<String, dynamic>? _pendingQuestion;
  bool _answerBusy = false;
  final ValueNotifier<String> _streamText = ValueNotifier('');
  final ValueNotifier<String> _streamReasoning = ValueNotifier('');
  final DshLiveTurn _live = DshLiveTurn();
  final List<String> _pendingImages = [];
  final List<String> _pendingFiles = [];

  List<SessionModelOption> get _sessionModelOptions {
    final shiyi = widget.shiyi;
    // 本机与局域网统一：拾忆 API 走「手机临时中转」租约（本机经回环）；
    // 公网拨不进手机，拾忆 API 走直接注入。
    final remoteInject =
        shiyi != null && DshEndpoint.modeOf(shiyi.settings) == 'remote';
    final hasShiyi = shiyi != null;
    final local = [
      for (final p in shiyi?.apiProfiles ?? const <ApiProfile>[])
        SessionModelOption(
          value: hasShiyi ? 'relay:${p.profileId}' : p.name,
          label: remoteInject ? '拾忆 API · ${p.name}' : '手机临时中转 · ${p.name}',
          subtitle: p.model,
          models: shiyi?.cachedModelsForProfile(p) ?? const <String>[],
          targetDsh: hasShiyi,
          targetProvider: shiyi != null
              ? (remoteInject
                    ? shiyi.relayProviderForProfile(p)
                    : shiyi.relayProviderForProfile(
                        p,
                        sessionId: widget.sessionId,
                      ))
              : '',
          shiyiRelay: hasShiyi,
        ),
    ];
    return [
      ...local,
      for (final option in _dshModelOptions)
        SessionModelOption(
          value: 'dsh:${option.value}',
          label: '当前 DSH · ${option.label}',
          subtitle: option.subtitle,
          models: option.models,
          targetDsh: true,
          targetProvider: option.targetProvider.trim().isEmpty
              ? option.value
              : option.targetProvider,
        ),
    ];
  }

  bool get _usesTargetDshApi => widget.shiyi == null;

  bool get _usesLivePageData =>
      DshEndpoint.requiresLivePageData(widget.shiyi?.settings);

  /// 当前会话已加载的 DSH 技能。发送下一条消息时会一起注入调用指令，
  /// 与拾忆会话的“已加载技能”保持同一交互模型。
  final List<DshSkillInfo> _selectedSkills = [];
  final Map<String, ToolEvent> _timedToolEvents = {};
  StreamSubscription<Map<String, dynamic>>? _muxSub;
  StreamSubscription<Map<String, dynamic>>? _hostSub;
  Timer? _muxRetry;
  Timer? _cacheTimer;
  Timer? _historySettleTimer;
  int _historySettleAttempts = 0;
  Future<void> _cacheWriteTail = Future<void>.value();
  bool _muxUp = false;
  DateTime _lastStreamEmit = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastStreamLen = 0;
  bool _autoScrollScheduled = false;
  final Set<String> _enteredMessageIds = {};
  final Set<String> _enteredUserTexts = {};
  final Map<String, String> _userEnterKeys = {};
  bool _awaitingFinalReply = false;
  bool _turnEndSeen = false;
  bool _suppressDuplicateSubagentTurn = false;
  String? _pendingPromptText;
  final DshTurnCommandQueue _turnCommands = DshTurnCommandQueue();
  DateTime? _lastSlashTrigger;
  int _pollTicks = 0;
  int _muxGen = 0;
  static const _liveId = 'dsh-live';
  static const _maxHistorySettleDelayStep = 8;

  DshApiClient get _api => DshService.instance.api;

  @override
  void initState() {
    super.initState();
    final settings = widget.shiyi?.settings;
    _selectedModelTargetDsh =
        _usesTargetDshApi ||
        (settings != null && DshEndpoint.modeOf(settings) == 'remote');
    WidgetsBinding.instance.addObserver(this);
    DshService.instance.status.addListener(_onDshStatus);
    _streamText.addListener(_onStreamTextChanged);
    TtsService.instance.speakingId.addListener(_onSpeakingChanged);
    TtsService.instance.lastError.addListener(_onTtsError);
    _input.addListener(_onInputChanged);
    if (widget.initialInput.isNotEmpty) {
      _input.text = widget.initialInput;
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    }
    if (_model.isNotEmpty) {
      _applyReasoningCapabilities(_model);
    }
    unawaited(_loadPermissionPresets());
    unawaited(_loadContextLimit());
    final snapshot = widget.initialSnapshot;
    if (!_usesLivePageData && snapshot?.hasUiData == true) {
      _restoreSnapshot(snapshot!, notify: false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(prefetched: snapshot));
    });
  }

  @override
  void dispose() {
    final relayLease = _activeRelayLease;
    if (relayLease != null) {
      widget.shiyi?.monitorDshRelayLease(relayLease);
    }
    _cacheTimer?.cancel();
    _queueCacheWrite();
    WidgetsBinding.instance.removeObserver(this);
    DshService.instance.status.removeListener(_onDshStatus);
    _streamText.removeListener(_onStreamTextChanged);
    TtsService.instance.speakingId.removeListener(_onSpeakingChanged);
    TtsService.instance.lastError.removeListener(_onTtsError);
    _input.removeListener(_onInputChanged);
    _pollTimer?.cancel();
    _subagentPollTimer?.cancel();
    _loadRetryTimer?.cancel();
    _historySettleTimer?.cancel();
    _muxGen = 0;
    _muxRetry?.cancel();
    unawaited(_muxSub?.cancel());
    unawaited(_hostSub?.cancel());
    _streamText.dispose();
    _streamReasoning.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onDshStatus() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeMetrics() {
    // 键盘弹起时把最新消息顶到输入框上方可见区。
    if (!mounted || !_scroll.hasClients) return;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    if (bottom > 0) _scrollToBottom(animated: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cacheTimer?.cancel();
      _queueCacheWrite();
    }
  }

  DshChatSnapshot _cacheSnapshot() => DshChatSnapshot(
    messages: DshChatCache.materializeMessages(
      sessionId: widget.sessionId,
      messages: _messages,
      liveText: _live.text,
      liveReasoning: _live.reasoning,
      liveToolCalls: _live.toolCalls,
    ),
    title: _title,
    model: _model,
    cwd: _cwd,
    running: _running,
    summary: _summary,
  );

  void _scheduleCacheWrite() {
    _cacheTimer?.cancel();
    _cacheTimer = Timer(const Duration(milliseconds: 250), () {
      _cacheTimer = null;
      _queueCacheWrite();
    });
  }

  void _queueCacheWrite() {
    if (_usesLivePageData) return;
    final snapshot = _cacheSnapshot();
    _cacheWriteTail = _cacheWriteTail
        .then((_) => DshChatCache.write(widget.sessionId, snapshot))
        .catchError((_) {});
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

  Future<void> _speakMessage(ChatMessage msg) async {
    await TtsService.instance.speak(
      msg.id,
      msg.content,
      rate: widget.shiyi?.settings.ttsRate ?? 1.0,
    );
  }

  void _stopSpeak() {
    TtsService.instance.stop();
  }

  bool get _lightsBusy {
    final st = DshService.instance.status.value;
    return _sending ||
        _running ||
        st == DshStatus.installing ||
        st == DshStatus.updating ||
        st == DshStatus.starting ||
        st == DshStatus.stopping ||
        st == DshStatus.uninstalling;
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
                  m.runtimeContext.trim().isEmpty &&
                  m.reasoning.trim().isEmpty &&
                  m.subagentSummary.trim().isEmpty),
        )
        .toList();
  }

  List<ToolEvent> get _toolEvents {
    final out = <ToolEvent>[];
    for (final m in _messages) {
      for (final t in m.toolCalls) {
        final key = _toolEventKey(t.id, t.name, t.arguments);
        if (_timedToolEvents.containsKey(key)) continue;
        out.add(
          ToolEvent(
            name: t.name,
            argsSummary: t.arguments,
            startedAt: m.createdAt == 0
                ? DateTime.now().millisecondsSinceEpoch
                : m.createdAt,
            done: true,
            ok: true,
          ),
        );
      }
    }
    out.addAll(_timedToolEvents.values);
    out.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return out;
  }

  static String _toolEventKey(String id, String name, String arguments) =>
      id.trim().isNotEmpty ? 'id:${id.trim()}' : '$name\n$arguments';

  void _recordToolCall(Map<String, dynamic> event) {
    final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final id = data['callId']?.toString() ?? '';
    final name = (data['name'] ?? data['tool'] ?? '').toString();
    final arguments = data['arguments']?.toString() ?? '';
    final key = _toolEventKey(id, name, arguments);
    if (_timedToolEvents.containsKey(key)) return;
    _timedToolEvents[key] = ToolEvent(
      name: name,
      argsSummary: arguments,
      startedAt:
          (event['time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
    if (mounted) setState(() {});
  }

  void _recordToolResult(Map<String, dynamic> event) {
    final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final message = (data['message'] as Map?)?.cast<String, dynamic>();
    final source = (message?['source'] as Map?)?.cast<String, dynamic>();
    final id = (source?['callId'] ?? data['callId'] ?? '').toString();
    if (id.isEmpty) return;
    final key = 'id:$id';
    final item = _timedToolEvents[key];
    if (item == null || item.done) return;
    item
      ..done = true
      ..ok = data['error'] == null
      ..finishedAt =
          (event['time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
    if (mounted) setState(() {});
  }

  void _finishOpenToolEvents({bool ok = true}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final item in _timedToolEvents.values) {
      if (item.done) continue;
      item
        ..done = true
        ..ok = ok
        ..finishedAt = now;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  int get _runningSubagentCount {
    return _subagents.where((e) => e.kind != 'diagnostic' && e.running).length;
  }

  int get _subagentTotalCount {
    return _subagents.where((e) => e.kind != 'diagnostic').length;
  }

  String get _subagentBarText {
    final n = _runningSubagentCount;
    final total = _subagentTotalCount;
    if (n > 0) {
      return '子代理 ' + n.toString() + '/' + total.toString() + ' · 运行中';
    }
    if (total > 0) return '子代理 ' + total.toString() + ' · 已完成';
    return '子代理';
  }

  String _dshSubagentTitle(DshSubagentEntry e) {
    final title = e.title;
    if (title != null && title.isNotEmpty) return title;
    final shortId = e.sessionId.split('-').first;
    return shortId.isEmpty ? '子代理' : '子代理 ' + shortId;
  }

  String _dshSubagentSubtitle(DshSubagentEntry e) {
    final parts = <String>[
      e.mode == 'continuable' ? '可继续对话' : '一次性',
      e.running ? '运行中' : '已完成',
    ];
    if (e.turnCount > 0) {
      parts.insert(0, e.turnCount.toString() + ' 轮');
    }
    return parts.join(' · ');
  }

  List<SubagentLiveSnapshot> _subagentSnapshots() {
    final out = <SubagentLiveSnapshot>[];
    for (final e in _subagents) {
      if (e.kind == 'diagnostic') continue;
      final cached = _subagentDetails[e.sessionId];
      final base =
          cached ??
          SubagentLiveSnapshot(
            id: e.sessionId,
            title: _dshSubagentTitle(e),
            subtitle: _dshSubagentSubtitle(e),
            running: e.running,
          );
      out.add(
        base.copyWith(
          title: _dshSubagentTitle(e),
          subtitle: _dshSubagentSubtitle(e),
          running: e.running,
        ),
      );
    }
    return out;
  }

  Future<SubagentLiveSnapshot> _resolveDshSubagent(
    SubagentLiveSnapshot agent,
  ) async {
    DshSubagentEntry? entry;
    for (final e in _subagents) {
      if (e.sessionId == agent.id) {
        entry = e;
        break;
      }
    }
    final mode = (entry == null || entry.mode.isEmpty)
        ? 'one-shot'
        : entry.mode;
    try {
      final bundle = await _api.subagentHistoryBundle(
        widget.sessionId,
        agent.id,
        mode: mode,
      );
      final next = agent.copyWith(
        title: entry == null ? agent.title : _dshSubagentTitle(entry),
        subtitle: entry == null ? agent.subtitle : _dshSubagentSubtitle(entry),
        running: (entry?.running ?? agent.running) || bundle.live.open,
        messages: bundle.messages,
        liveContent: bundle.live.text,
        liveReasoning: bundle.live.reasoning,
      );
      _subagentDetails[agent.id] = next;
      return next;
    } catch (_) {
      return agent;
    }
  }

  /// 会话是否仍处于“正在思考/运行”状态。
  ///
  /// 只要父会话整轮还没收口（`_running` / `_awaitingFinalReply` / 正在发送），
  /// 都算活跃。子代理是否还在跑跟父会话思考占位分开：主 agent 等待
  /// 子代理返回时可以停，但子代理按钮仍在。
  bool get _isThinkingActive => _running || _sending || _awaitingFinalReply;

  void _restoreSnapshot(DshChatSnapshot cached, {required bool notify}) {
    void restore() {
      _messages = List<ChatMessage>.of(cached.messages);
      if (cached.title.isNotEmpty) _title = cached.title;
      if (cached.model.isNotEmpty) {
        _model = cached.model;
        _applyReasoningCapabilities(cached.model);
      }
      if (cached.cwd.isNotEmpty) _cwd = cached.cwd;
      _running = cached.running;
      _summary = cached.summary ?? _summary;
      _loading = false;
      _waitingService = false;
    }

    if (notify && mounted) {
      setState(restore);
    } else {
      restore();
    }
    if (!cached.running) return;
    _awaitingFinalReply = true;
    _pendingPromptText = _latestUserText(_messages);
    final cachedLive = _messages
        .where((m) => m.id == dshCachedLiveMessageId)
        .firstOrNull;
    _live.begin();
    if (cachedLive != null) {
      _live.text = cachedLive.content;
      _live.reasoning = cachedLive.reasoning;
      _live.toolCalls.addAll(cachedLive.toolCalls);
    }
    _ensureLiveBubble(notify: false);
    if (_live.hasVisible) _publishLive(force: true);
  }

  void _startSnapshotRefresh({required bool deferForEntrance}) {
    void start() {
      if (!mounted) return;
      _scrollToBottom(animated: false);
      // 缓存首帧显示后静默刷新，RPC 再慢也不阻塞界面。
      unawaited(_refreshHistory(clearLive: false));
      _maybePoll();
      unawaited(_loadMeta());
      unawaited(_refreshSubagents());
      unawaited(_connectDownlink());
    }

    if (deferForEntrance) {
      Future<void>.delayed(const Duration(milliseconds: 320), start);
    } else {
      start();
    }
  }

  Future<void> _load({DshChatSnapshot? prefetched}) async {
    final usablePrefetched = _usesLivePageData ? null : prefetched;
    if (usablePrefetched?.hasUiData != true) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      _error = null;
      _waitingService = false;
    }
    // 只有本机 DSH 使用快照首帧；局域网 / 公网始终等待目标 DSH 返回。
    final cached = _usesLivePageData
        ? null
        : usablePrefetched ?? await DshChatCache.read(widget.sessionId);
    final hasCache = cached?.hasUiData == true;
    if (mounted && hasCache) {
      _restoreSnapshot(cached!, notify: true);
      _startSnapshotRefresh(deferForEntrance: prefetched != null);
      return;
    }
    try {
      final bundle = await DshService.instance.withRecover(
        () => _api.historyBundle(widget.sessionId),
        recover: false,
      );
      if (!mounted) return;
      setState(() {
        _messages = _mergeHistory(
          bundle.messages,
          live: bundle.live,
          preserveLocalProgress: _shouldPreserveLocalProgress(bundle),
        );
        _loading = false;
        _waitingService = false;
      });
      _rememberResponseModels(bundle);
      if (_running || bundle.live.open) {
        _awaitingFinalReply = true;
        _pendingPromptText = _latestUserText(_messages);
        if (!bundle.live.open) _live.begin();
        _adoptHistoryReasoning(bundle.messages);
      }
      _adoptLive(bundle.live, force: true);
      _scheduleCacheWrite();
      _scrollToBottom(animated: false);
      // 列表首次布局可能晚于本帧，二次兜底确保进会话就在最后一条。
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (mounted) _scrollToBottom(animated: false);
      });
      unawaited(_loadMeta());
      unawaited(_refreshSubagents());
      unawaited(_connectDownlink());
      _maybePoll();
    } catch (e) {
      if (!mounted) return;
      if (!hasCache) {
        final reason = await DshService.instance.unavailableReason();
        if (!mounted) return;
        if (reason != null && reason != 'DSH 未安装') {
          // 服务未就绪（安装/启动/API 初始化中）：不拿「不可达」错误页逼
          // 用户手点重试，改成自动等待，服务就绪后自动加载。
          setState(() {
            _loading = false;
            _error = null;
            _waitingService = true;
          });
          _scheduleLoadRetry();
          return;
        }
        setState(() {
          _loading = false;
          _error = '$e';
          _waitingService = false;
        });
      } else {
        setState(() {
          _loading = false;
          _error = '$e';
          _waitingService = false;
        });
      }
    }
  }

  /// 服务未就绪时自动重查，就绪后重新加载会话历史。
  void _scheduleLoadRetry() {
    _loadRetryTimer?.cancel();
    _loadRetryTimer = Timer(const Duration(seconds: 3), () async {
      _loadRetryTimer = null;
      if (!mounted) return;
      final reason = await DshService.instance.unavailableReason();
      if (!mounted) return;
      if (reason == null) {
        await _load();
      } else if (reason == 'DSH 未安装') {
        setState(() {
          _waitingService = false;
          _error = reason;
        });
      } else {
        _scheduleLoadRetry();
      }
    });
  }

  List<ThinkingIntensityOption> get _thinkingOptions =>
      buildReasoningOptions(_reasoningCapabilities);

  void _applyReasoningCapabilities(String model, {String? selected}) {
    final capabilities =
        DshModelSync.reasoningEffortsForModel(model) ?? const {};
    _reasoningCapabilities = capabilities;
    if (selected != null) {
      _reasoningEffort = capabilities.containsKey(selected)
          ? selected
          : capabilities.containsKey('')
          ? ''
          : '';
    } else if (_reasoningEffort.isNotEmpty &&
        !capabilities.containsKey(_reasoningEffort) &&
        _reasoningEffort != 'off') {
      _reasoningEffort = capabilities.containsKey('') ? '' : '';
    }
    if (_reasoningEffort != 'off') {
      _lastNonOffEffort = _reasoningEffort;
    }
  }

  bool get _thinkingOn => _reasoningEffort != 'off';

  Future<void> _setReasoningEffort(String value) async {
    if (_compacting ||
        _sending ||
        _running ||
        _provider.isEmpty ||
        _model.isEmpty) {
      return;
    }
    final previous = _reasoningEffort;
    final previousLast = _lastNonOffEffort;
    setState(() {
      _reasoningEffort = value;
      if (value != 'off') _lastNonOffEffort = value;
    });
    if (_selectedRelayProfileId.isNotEmpty) {
      await _persistRelaySelection();
      return;
    }
    try {
      final selected = await _api.selectModel(
        widget.sessionId,
        _provider,
        _model,
        reasoningEffort: value,
      );
      if (!mounted) return;
      final next = selected.reasoningEffort ?? '';
      setState(() {
        _reasoningEffort = next;
        if (next != 'off') _lastNonOffEffort = next;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _reasoningEffort = previous;
          _lastNonOffEffort = previousLast;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('思考强度更新失败：$e')));
      }
    }
  }

  Future<void> _setThinkingOn(bool on) async {
    if (on == _thinkingOn) return;
    await _setReasoningEffort(on ? _lastNonOffEffort : 'off');
  }

  String get _selectedProfileName {
    if (_selectedRelayProfileId.isNotEmpty) {
      return 'relay:$_selectedRelayProfileId';
    }
    final targetProvider = _provider.trim();
    if (_selectedModelTargetDsh) {
      for (final option in _sessionModelOptions) {
        if (option.targetDsh &&
            (option.targetProvider == targetProvider ||
                option.value == 'dsh:$targetProvider')) {
          return option.value;
        }
      }
    }
    if (_usesTargetDshApi) return _provider.trim();
    final shiyi = widget.shiyi;
    final profiles = shiyi?.apiProfiles ?? const <ApiProfile>[];
    final provider = _provider.trim();
    if (provider.isNotEmpty) {
      for (final p in profiles) {
        if (DshModelSync.providerIdForName(p.name) == provider) return p.name;
      }
    }
    final model = _model.trim();
    for (final p in profiles) {
      if (p.model.trim() == model) return p.name;
    }
    if (shiyi != null && model.isNotEmpty) {
      for (final p in profiles) {
        if (shiyi.cachedModelsForProfile(p).contains(model)) return p.name;
      }
    }
    return model;
  }

  /// 公网每条消息前重申模型选择——局域网由中转租约每回合自愈，公网在
  /// 这里补齐同样的保证：下一条消息一定落在所选配置上。
  /// 拾忆 API：轻量 selectModel 失败（provider 被远端删了等）→ 幂等重注入；
  /// 原生模型：selectModel 失败仅记审计。任何失败都不阻塞发送。
  Future<void> _reaffirmRemoteSelection() async {
    final shiyi = widget.shiyi;
    if (shiyi == null || DshEndpoint.modeOf(shiyi.settings) != 'remote') return;
    final provider = _provider.trim();
    final model = _model.trim();
    if (provider.isEmpty || model.isEmpty) return;
    try {
      await _api
          .selectModel(widget.sessionId, provider, model)
          .timeout(const Duration(seconds: 6));
      return;
    } catch (e) {
      unawaited(
        RuntimeLogger.instance.warn(
          'DSH',
          'session_model.reaffirm_failed',
          sessionId: widget.sessionId,
          data: {'provider': provider, 'model': model, 'error': '$e'},
        ),
      );
      if (_selectedRelayProfileId.isEmpty) return;
    }
    final profile = _selectedRelayProfile();
    if (profile == null) return;
    try {
      await shiyi
          .injectShiyiProfileForRemote(
            profile: profile,
            sessionId: widget.sessionId,
            model: model,
          )
          .timeout(const Duration(seconds: 12));
      unawaited(
        RuntimeLogger.instance.info(
          'DSH',
          'session_model.reinjected',
          sessionId: widget.sessionId,
          data: {'provider': provider, 'model': model},
        ),
      );
    } catch (e) {
      unawaited(
        RuntimeLogger.instance.warn(
          'DSH',
          'session_model.reinject_failed',
          sessionId: widget.sessionId,
          result: 'failed',
          data: {'provider': provider, 'error': '$e'},
        ),
      );
    }
  }

  /// 切换模型时的 selectModel：思考档位以目标 provider 的服务端声明为准
  /// （静态思考目录只是客户端猜测）。被"不支持该档位"拒绝时降级为不带
  /// 档位重试一次（服务端用该模型默认档位），避免档位参数毁掉整个切换。
  /// 返回 (选择结果, 是否发生了降级)。
  Future<(DshModelSelection, bool)> _selectModelWithEffortFallback(
    String provider,
    String model,
    String effort,
  ) async {
    try {
      return (
        await _api.selectModel(
          widget.sessionId,
          provider,
          model,
          reasoningEffort: effort,
        ),
        false,
      );
    } on DshApiException catch (e) {
      if (!DshApiClient.isReasoningEffortRejection(e.message)) rethrow;
      final retried = await _api.selectModel(widget.sessionId, provider, model);
      return (retried, true);
    }
  }

  Future<void> _selectSessionProfile(SessionModelSelection selection) async {
    if (_compacting || _sending || _running) return;
    final shiyi = widget.shiyi;
    if (selection.shiyiRelay) {
      if (shiyi == null) return;
      final remoteInject = DshEndpoint.modeOf(shiyi.settings) == 'remote';
      ApiProfile? profile;
      for (final item in shiyi.apiProfiles) {
        if (shiyi.relayProviderForProfile(item, sessionId: widget.sessionId) ==
                selection.profile ||
            shiyi.relayProviderForProfile(item) == selection.profile) {
          profile = item;
          break;
        }
      }
      final modelId = selection.model.trim();
      final selectedProfile = profile;
      if (selectedProfile == null || modelId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('拾忆中转配置不存在或模型为空')));
        }
        return;
      }
      setState(() {
        _model = modelId;
        _provider = remoteInject
            ? shiyi.relayProviderForProfile(selectedProfile)
            : shiyi.relayProviderForProfile(
                selectedProfile,
                sessionId: widget.sessionId,
              );
        _selectedRelayProfileId = selectedProfile.profileId;
        _selectedModelTargetDsh = true;
        _applyReasoningCapabilities(_model);
      });
      await DshChatCache.writeRelaySelection(
        DshEndpoint.scopeKeyOf(shiyi.settings),
        widget.sessionId,
        DshRelaySelection(
          profileId: selectedProfile.profileId,
          model: modelId,
          reasoningEffort: _reasoningEffort,
        ),
      );
      _scheduleCacheWrite();
      if (remoteInject) {
        // 公网：真实配置直接写入目标 DSH（持久，可在模型数据页手动删除）。
        try {
          final provider = await shiyi.injectShiyiProfileForRemote(
            profile: selectedProfile,
            sessionId: widget.sessionId,
            model: modelId,
          );
          if (!mounted) return;
          setState(() => _provider = provider);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('拾忆 API 直接注入失败：$e')));
        }
      }
      return;
    }
    if (selection.targetDsh) {
      await _releaseActiveRelayLease();
      await _clearRelaySelection();
      final previousModel = _model;
      final previousProvider = _provider;
      final previousTarget = _selectedModelTargetDsh;
      setState(() {
        _model = selection.model;
        _provider = selection.profile;
        _selectedModelTargetDsh = true;
        _applyReasoningCapabilities(_model);
      });
      try {
        final (selected, effortDropped) = await _selectModelWithEffortFallback(
          selection.profile,
          selection.model,
          _thinkingOn ? _reasoningEffort : 'off',
        );
        if (!mounted) return;
        final serverEffort = selected.reasoningEffort?.trim() ?? '';
        setState(() {
          if (selected.model.isNotEmpty) _model = selected.model;
          if (selected.provider.isNotEmpty) _provider = selected.provider;
          _applyReasoningCapabilities(
            _model,
            selected: selected.reasoningEffort ?? _reasoningEffort,
          );
          // 降级重试成功：以服务端实际档位为准；未回传则视为该模型
          // 不适用档位（off），_lastNonOffEffort 保留供下次开启。
          if (serverEffort.isNotEmpty) {
            _reasoningEffort = serverEffort;
          } else if (effortDropped) {
            _reasoningEffort = 'off';
          }
          if (_reasoningEffort != 'off') _lastNonOffEffort = _reasoningEffort;
        });
        _scheduleCacheWrite();
        // 公网：回读服务端真值——200 不代表远端会话真的换了模型，
        // 以 current 为准采纳；不一致时明示远端实际状态。
        if (widget.shiyi != null &&
            DshEndpoint.modeOf(widget.shiyi!.settings) == 'remote') {
          try {
            final verify = await _api.sessionModels(widget.sessionId);
            final vp = verify.current.provider.trim();
            final vm = verify.current.model.trim();
            if (!mounted) return;
            if (vp.isNotEmpty &&
                (vp != _provider.trim() ||
                    (vm.isNotEmpty && vm != _model.trim()))) {
              setState(() {
                _provider = vp;
                if (vm.isNotEmpty) _model = vm;
                _applyReasoningCapabilities(_model);
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('远端实际模型：$vp / ${vm.isEmpty ? '?' : vm}'),
                ),
              );
            }
          } catch (_) {}
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _model = previousModel;
          _provider = previousProvider;
          _selectedModelTargetDsh = previousTarget;
          _applyReasoningCapabilities(previousModel);
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('切换 DSH 模型失败：$e')));
      }
      return;
    }
    // 走到这里说明没有拾忆配置可选（shiyi 为空）：模型选择器里只有
    // 「当前 DSH」项，已在上面 targetDsh 分支处理。
  }

  ApiProfile? _selectedRelayProfile() {
    final id = _selectedRelayProfileId.trim();
    if (id.isEmpty) return null;
    return widget.shiyi?.apiProfiles
        .where((item) => item.profileId == id)
        .firstOrNull;
  }

  /// Restore the session-scoped relay identity before the first prompt.
  ///
  /// The local DSH keeps its page snapshot, but its relay provider is deleted
  /// after each turn. The selector can therefore still show the cached model
  /// while the state needed to acquire the next lease has not been restored.
  Future<ApiProfile?> _restoreRelaySelectionForSend() async {
    final shiyi = widget.shiyi;
    if (shiyi == null || DshEndpoint.modeOf(shiyi.settings) == 'remote') {
      return null;
    }
    var profile = _selectedRelayProfile();
    var selection = await DshChatCache.readRelaySelection(
      DshEndpoint.scopeKeyOf(shiyi.settings),
      widget.sessionId,
    );
    if (profile == null && selection != null) {
      profile = shiyi.apiProfiles
          .where((item) => item.profileId == selection!.profileId)
          .firstOrNull;
    }
    // Migrate sessions created before the session-scoped cache existed. Prefer
    // the explicit global profile, then the model match used by the old UI.
    if (profile == null) {
      final boundId = shiyi.settings.apiProfileId.trim();
      profile = shiyi.apiProfiles
          .where((item) => item.profileId == boundId)
          .firstOrNull;
    }
    if (profile == null && _model.trim().isNotEmpty) {
      profile = shiyi.apiProfiles.where((item) {
        if (item.model.trim() == _model.trim()) return true;
        return shiyi.cachedModelsForProfile(item).contains(_model.trim());
      }).firstOrNull;
    }
    if (profile == null || profile.apiKey.trim().isEmpty) return null;
    final model =
        (selection?.model.trim().isNotEmpty == true ? selection!.model : _model)
            .trim();
    if (model.isEmpty) return null;
    final effort = selection?.reasoningEffort ?? _reasoningEffort;
    if (!mounted) return profile;
    setState(() {
      _selectedRelayProfileId = profile!.profileId;
      _model = model;
      _provider = shiyi.relayProviderForProfile(
        profile,
        sessionId: widget.sessionId,
      );
      _selectedModelTargetDsh = true;
    });
    selection = DshRelaySelection(
      profileId: profile.profileId,
      model: model,
      reasoningEffort: effort,
    );
    await DshChatCache.writeRelaySelection(
      DshEndpoint.scopeKeyOf(shiyi.settings),
      widget.sessionId,
      selection,
    );
    return profile;
  }

  Future<void> _persistRelaySelection() async {
    final shiyi = widget.shiyi;
    final profile = _selectedRelayProfile();
    if (shiyi == null || profile == null || _model.trim().isEmpty) return;
    await DshChatCache.writeRelaySelection(
      DshEndpoint.scopeKeyOf(shiyi.settings),
      widget.sessionId,
      DshRelaySelection(
        profileId: profile.profileId,
        model: _model.trim(),
        reasoningEffort: _reasoningEffort,
      ),
    );
  }

  Future<void> _clearRelaySelection() async {
    final shiyi = widget.shiyi;
    if (shiyi == null) return;
    _selectedRelayProfileId = '';
    await DshChatCache.clearRelaySelection(
      DshEndpoint.scopeKeyOf(shiyi.settings),
      widget.sessionId,
    );
  }

  Future<void> _releaseActiveRelayLease() async {
    final lease = _activeRelayLease;
    if (lease == null) return;
    _activeRelayLease = null;
    final shiyi = widget.shiyi;
    if (shiyi == null) return;
    try {
      await shiyi.releaseDshRelayLease(lease);
    } catch (error, stack) {
      unawaited(
        RuntimeLogger.instance.warn(
          'Relay',
          'lease.release_failed',
          sessionId: widget.sessionId,
          result: 'failed',
          data: {
            'provider': lease.provider,
            'error': '$error',
            'stack': '$stack',
          },
        ),
      );
    }
  }

  /// 读目标 DSH 的权限预设表（permissionPresets 服务）。未挂服务的旧版
  /// DSH 拿不到 permission 命名空间，按钮保持隐藏。
  Future<void> _loadPermissionPresets() async {
    try {
      final presets = await _api.describePermissionPresets();
      if (!mounted) return;
      setState(() {
        _permissionOptions = presets == null
            ? const []
            : [
                for (final option in presets.options)
                  PermissionPresetOption(
                    value: option.key,
                    label: option.label,
                  ),
              ];
        _permissionDefault = presets?.defaultPreset ?? '';
      });
    } catch (_) {
      // 探测失败不打断会话页；按钮隐藏。
    }
  }

  /// 实时切换当前会话的权限预设（DSH `/permission <preset>` 命令，与
  /// 官方输入框弹层同一条链路，立即生效并写入会话事件）。
  Future<void> _setDefaultPermission(String preset) async {
    if (preset == _sessionPermission) return;
    final previous = _sessionPermission;
    final label = _permissionOptions
        .where((option) => option.value == preset)
        .map((option) => option.label)
        .firstOrNull;
    setState(() => _sessionPermission = preset);
    try {
      await _api.executeSessionCommand(widget.sessionId, '/permission $preset');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('权限预设：${label ?? preset}（当前会话已生效）')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sessionPermission = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('权限切换失败：$e')));
    }
  }

  Future<void> _loadMeta() async {
    DshRelaySelection? savedRelay;
    ApiProfile? savedRelayProfile;
    final shiyi = widget.shiyi;
    // 本机与局域网统一（#307）：中转选择按 scope 缓存恢复，本机不例外。
    // 漏掉本机会导致冷启动后抽屉显示已选中、发消息却没走租约，
    // 打在上一个回合残留的（已被释放删除的）relay provider 上直接失败。
    if (shiyi != null && DshEndpoint.modeOf(shiyi.settings) != 'remote') {
      savedRelay = await DshChatCache.readRelaySelection(
        DshEndpoint.scopeKeyOf(shiyi.settings),
        widget.sessionId,
      );
      if (savedRelay != null) {
        savedRelayProfile = shiyi.apiProfiles
            .where((item) => item.profileId == savedRelay!.profileId)
            .firstOrNull;
      }
    }
    DshModelSelection? current;
    var groups = <DshModelGroup>[];
    try {
      final sessionModels = await _api.sessionModels(widget.sessionId);
      current = sessionModels.current;
      groups = sessionModels.groups;
    } catch (_) {}
    try {
      groups = _mergeDshModelGroups(groups, await _api.llmModels());
    } catch (_) {
      // 旧版 DSH 没有 llm.models 时保留 session.models。
    }
    try {
      groups = _mergeDshModelGroups(
        groups,
        dshModelGroupsFromProviders(await _api.llmProviders()),
      );
    } catch (_) {
      // 旧版 DSH 没有 llm.providers 时不影响会话模型列表。
    }
    // 公网直注入是持久的：本地缓存的「拾忆 API」选择必须镜像远端实况。
    // 目标主机上 provider 已被删除（模型数据页或服务器侧）时，自动清掉
    // 本地选择，不允许出现“本地有远端没有”的状态。
    final remoteInject =
        shiyi != null && DshEndpoint.modeOf(shiyi.settings) == 'remote';
    if (remoteInject && savedRelayProfile != null) {
      final injectedProvider = shiyi.relayProviderForProfile(savedRelayProfile);
      final existsOnRemote = groups.any(
        (group) => group.id.trim() == injectedProvider,
      );
      if (!existsOnRemote) {
        await _clearRelaySelection();
        savedRelay = null;
        savedRelayProfile = null;
      }
    }
    if (mounted) {
      final currentModel = current?.model.trim() ?? '';
      final selected = current?.reasoningEffort ?? '';
      final fallback = widget.shiyi?.settings.model.trim() ?? '';
      setState(() {
        if (savedRelayProfile != null && savedRelay != null && shiyi != null) {
          _selectedRelayProfileId = savedRelay.profileId;
          _model = savedRelay.model;
          _provider = remoteInject
              ? shiyi.relayProviderForProfile(savedRelayProfile)
              : shiyi.relayProviderForProfile(
                  savedRelayProfile,
                  sessionId: widget.sessionId,
                );
          _selectedModelTargetDsh = true;
        } else if (currentModel.isNotEmpty) {
          _model = currentModel;
        } else if (_model.trim().isEmpty && fallback.isNotEmpty) {
          _model = fallback;
        }
        if (current != null && current.provider.trim().isNotEmpty) {
          if (savedRelayProfile == null) {
            _provider = current.provider;
            final matchesLocal =
                (widget.shiyi?.apiProfiles ?? const <ApiProfile>[]).any(
                  (profile) =>
                      DshModelSync.providerIdForName(profile.name) == _provider,
                );
            _selectedModelTargetDsh = _usesTargetDshApi || !matchesLocal;
          }
        }
        _dshModelOptions = [
          for (final group in groups)
            if (group.id.trim().isNotEmpty &&
                group.models.any((model) => model.id.trim().isNotEmpty) &&
                !DshModelSync.isRelayProvider(group.id) &&
                // vision-toolkit-* 是 DSH 为视觉调用生成的镜像分组，
                // 模型与本体重复，模型抽屉不展示（局域网抽屉重复的来源）。
                !group.id.trim().startsWith('vision-toolkit-'))
              SessionModelOption(
                value: group.id,
                label: group.name.trim().isEmpty ? group.id : group.name,
                subtitle: group.models.isEmpty
                    ? ''
                    : group.models.first.id.trim(),
                models: [
                  for (final model in group.models)
                    if (model.id.trim().isNotEmpty) model.id,
                ],
                targetDsh: true,
                targetProvider: group.id,
              ),
        ];
        _applyReasoningCapabilities(
          savedRelayProfile != null
              ? _model
              : (currentModel.isNotEmpty ? currentModel : _model),
          selected: savedRelay?.reasoningEffort ?? selected,
        );
      });
      _scheduleCacheWrite();
    }
    try {
      final list = await _api.listSessions();
      final me = list.where((s) => s.sessionId == widget.sessionId).firstOrNull;
      if (!mounted || me == null) return;
      final wasRunning = _running;
      setState(() {
        _running = me.running;
        if (me.title != null && me.title!.isNotEmpty) _title = me.title!;
        if (me.cwd != null && me.cwd!.isNotEmpty) _cwd = me.cwd!;
        _summary = me;
      });
      if (me.running && !_awaitingFinalReply) {
        _awaitingFinalReply = true;
        _pendingPromptText = _latestUserText(_messages);
        _live.begin();
        _resetLiveNotifiers();
        _ensureLiveBubble();
      } else if (!me.running && (wasRunning || _awaitingFinalReply)) {
        // 与 mux running=false 同一口径：主 agent 可能只是在等子代理。
        _sending = false;
        _awaitingFinalReply = false;
        _turnEndSeen = true;
        _pendingPromptText = null;
        _clearLiveUi(preserveVisible: true);
        _syncSubagentPolling();
        unawaited(_refreshSubagents());
        unawaited(_refreshHistory(clearLive: true));
        return;
      }
      _scheduleCacheWrite();
      _syncSubagentPolling();
      unawaited(_refreshSubagents());
    } catch (_) {}
  }

  void _maybePoll() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      _pollTicks++;
      final wantFast = _running && !_muxUp;
      if (!wantFast && _pollTicks % 5 != 0) return;
      try {
        // mux 连上不代表每一条 reasoning-delta 都已经送达；旧版 2.0
        // 由 history/stream 双路共同喂给 streamReasoning。运行中的回合继续
        // 走 history 兜底，非活动状态才只刷新元数据。
        if (_muxUp && _live.open && !_awaitingFinalReply && !_running) {
          await _refreshMeta();
          return;
        }
        if (wantFast) {
          final results = await Future.wait([
            _api.historyBundle(widget.sessionId),
            _api.listSessions(),
          ]);
          if (!mounted) return;
          final bundle = results[0] as DshHistoryBundle;
          final list = results[1] as List<DshSessionSummary>;
          final historyConfirmsLive = _historyConfirmsLive(bundle.messages);
          _rememberResponseModels(bundle);
          _adoptHistoryReasoning(bundle.messages);
          _applySessionMeta(list);
          final finalizesTurn = _historyFinalizesPendingTurn(bundle);
          _replaceMessages(
            _mergeHistory(
              bundle.messages,
              live: bundle.live,
              preserveLocalProgress:
                  !finalizesTurn &&
                  (_shouldPreserveLocalProgress(bundle) ||
                      !historyConfirmsLive),
            ),
          );
          if (finalizesTurn) {
            _finishPendingTurn();
          } else {
            _adoptLive(
              bundle.live,
              allowClose:
                  !_awaitingFinalReply &&
                  !bundle.live.open &&
                  historyConfirmsLive,
            );
          }
          if (bundle.live.open || bundle.live.hasVisible) {
            _scrollToBottom();
          }
          return;
        }
        final results = await Future.wait([
          _api.historyBundle(widget.sessionId),
          _api.listSessions(),
        ]);
        if (!mounted) return;
        final bundle = results[0] as DshHistoryBundle;
        final list = results[1] as List<DshSessionSummary>;
        final historyConfirmsLive = _historyConfirmsLive(bundle.messages);
        _rememberResponseModels(bundle);
        _adoptHistoryReasoning(bundle.messages);
        final prevLast = _messages.isEmpty ? null : _messages.last;
        final nextLast = bundle.messages.isEmpty ? null : bundle.messages.last;
        final changed =
            bundle.messages.length != _messages.length ||
            nextLast?.content != prevLast?.content;
        _applySessionMeta(list);
        final finalizesTurn = _historyFinalizesPendingTurn(bundle);
        _replaceMessages(
          _mergeHistory(
            bundle.messages,
            live: bundle.live,
            preserveLocalProgress:
                !finalizesTurn &&
                (_shouldPreserveLocalProgress(bundle) || !historyConfirmsLive),
          ),
        );
        if (finalizesTurn) {
          _finishPendingTurn();
        } else {
          _adoptLive(
            bundle.live,
            force: true,
            allowClose:
                !_awaitingFinalReply &&
                !bundle.live.open &&
                historyConfirmsLive,
          );
        }
        if (changed) _scrollToBottom();
        if (!_running && !changed && !bundle.live.open) {
          final last = _messages.isEmpty ? null : _messages.last;
          final done =
              last == null ||
              last.role == 'user' ||
              (last.role == 'assistant' && last.content.isNotEmpty);
          if (done) _stopPoll();
        }
      } catch (e) {
        // 不自动拉起服务：轮询失败等用户手动启动。
      }
    });
  }

  void _stopPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (mounted) {
      setState(() => _running = false);
      _syncSubagentPolling();
    }
  }

  void _removeOptimisticMessage(ChatMessage optimistic) {
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => m.id == optimistic.id);
    });
  }

  void _abortCurrentSend(
    ChatMessage optimistic,
    String text,
    List<String> images,
    List<String> files,
  ) {
    if (!mounted) return;
    setState(() {
      _sending = false;
      _running = false;
      _awaitingFinalReply = false;
      _turnEndSeen = false;
      _pendingPromptText = null;
      _messages.removeWhere((m) => m.id == optimistic.id);
      // 发送期间用户若已输入下一条，不覆盖新草稿。
      if (_input.text.trim().isEmpty &&
          _pendingImages.isEmpty &&
          _pendingFiles.isEmpty) {
        _input.text = text;
        _input.selection = TextSelection.collapsed(offset: text.length);
        _pendingImages.addAll(images);
        _pendingFiles.addAll(files);
      }
    });
    _clearLiveUi();
    _scheduleCacheWrite();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final images = List<String>.of(_pendingImages);
    final files = List<String>.of(_pendingFiles);
    if (text.isEmpty && images.isEmpty && files.isEmpty) return;
    final now = DateTime.now();
    final lastSendAt = _lastSendAt;
    if (lastSendAt != null &&
        now.difference(lastSendAt) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastSendAt = now;
    final interrupting = _sending || _running || _awaitingFinalReply;
    // A replacement prompt starts a new DSH turn. Any subagent.list result
    // from the previous turn must not repaint this turn's status.
    ++_subagentRefreshGeneration;
    final sendGeneration = ++_sendGeneration;
    final content = StringBuffer();
    for (final path in images) {
      content.writeln('![图片]($path)');
    }
    for (final path in files) {
      content.writeln('【附件：${p.basename(path)}】');
      content.writeln('路径：$path');
    }
    if (_selectedSkills.isNotEmpty) {
      for (final skill in _selectedSkills) {
        content.writeln('/${skill.name}');
      }
    }
    if (text.isNotEmpty) content.write(text);
    final prompt = content.toString().trim();
    // 先让输入区/附件立即让位并显示乐观消息：租约和取消都不能让界面
    // 看起来“点了没反应”，同帧第二个发送入口也会因空输入直接退出。
    _input.clear();
    _pendingImages.clear();
    _pendingFiles.clear();
    final optimistic = ChatMessage(
      id: 'dsh-opt-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: widget.sessionId,
      role: 'user',
      content: prompt,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (prompt.isNotEmpty) _userEnterKeys[prompt] = optimistic.id;
    _awaitingFinalReply = true;
    _turnEndSeen = false;
    _pendingPromptText = prompt;
    _live.begin();
    _resetLiveNotifiers();
    setState(() {
      _sending = true;
      _running = true;
      _messages.add(optimistic);
      _ensureLiveBubble(notify: false);
    });
    _scrollToBottom();
    if (interrupting) {
      // 旧的回合仍在跑：输入区和乐观消息已让位，这里再等串行队列取消。
      await _interruptLocallyForPrompt();
      if (!mounted || sendGeneration != _sendGeneration) {
        _removeOptimisticMessage(optimistic);
        return;
      }
      _awaitingFinalReply = true;
      _turnEndSeen = false;
      _pendingPromptText = prompt;
      _live.begin();
      _resetLiveNotifiers();
      setState(() {
        _sending = true;
        _running = true;
        _ensureLiveBubble(notify: false);
      });
    }
    // Do this immediately before acquiring the lease. On a cold local start
    // the drawer may be painted from a snapshot before _loadMeta completes.
    await _restoreRelaySelectionForSend();
    if (!mounted || sendGeneration != _sendGeneration) {
      _removeOptimisticMessage(optimistic);
      return;
    }
    if (_selectedRelayProfileId.isNotEmpty) {
      final shiyi = widget.shiyi;
      final profile = _selectedRelayProfile();
      if (shiyi == null || profile == null) {
        _abortCurrentSend(optimistic, text, images, files);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('选中的手机 API 配置已不存在')));
        return;
      }
      if (DshEndpoint.modeOf(shiyi.settings) != 'remote') {
        // 局域网：手机安全中转，随回合租约随用随删。
        // 公网：配置已在选择时直接注入远端（持久），无需租约。
        setState(() => _sending = true);
        try {
          final lease = await shiyi.acquireDshRelayLease(
            profile: profile,
            sessionId: widget.sessionId,
            model: _model,
          );
          if (!mounted || sendGeneration != _sendGeneration) {
            await shiyi.releaseDshRelayLease(lease);
            _removeOptimisticMessage(optimistic);
            return;
          }
          _activeRelayLease = lease;
          _provider = lease.provider;
        } catch (e) {
          if (mounted && sendGeneration == _sendGeneration) {
            _abortCurrentSend(optimistic, text, images, files);
          } else {
            _removeOptimisticMessage(optimistic);
          }
          if (mounted && sendGeneration == _sendGeneration) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('手机临时中转失败：$e')));
          }
          return;
        }
      }
    }
    _scheduleCacheWrite();
    _scrollToBottom();
    _maybePoll();
    await _reaffirmRemoteSelection();
    Future<void> sendPrompt() => DshService.instance.withRecover(
      () => _turnCommands.enqueue(() => _api.prompt(widget.sessionId, prompt)),
      recover: true,
    );
    void markAccepted() {
      _ignoreLateRunningStatus = false;
      if (!mounted || sendGeneration != _sendGeneration) return;
      setState(() {
        _sending = false;
        _running = true;
      });
      _scrollToBottom();
      _maybePoll();
      _syncSubagentPolling();
      unawaited(_refreshSubagents());
    }

    try {
      await sendPrompt();
      markAccepted();
    } catch (e) {
      await _releaseActiveRelayLease();
      // 会话的服务端选择可能指向已被删除/失效的 provider（例如清理过的
      // 旧注入路由）：重新获取一次中转租约（重新注入 + selectModel）后
      // 重试一次发送，用户无需手动重新选择。
      final retryable =
          _selectedRelayProfileId.isNotEmpty &&
          widget.shiyi != null &&
          (e.toString().contains('no adapter serves provider') ||
              e.toString().contains('model-unavailable'));
      var recovered = false;
      if (retryable && mounted && sendGeneration == _sendGeneration) {
        try {
          final profile = _selectedRelayProfile();
          final shiyi = widget.shiyi;
          if (profile != null && shiyi != null) {
            final lease = await shiyi.acquireDshRelayLease(
              profile: profile,
              sessionId: widget.sessionId,
              model: _model,
            );
            if (!mounted || sendGeneration != _sendGeneration) {
              await shiyi.releaseDshRelayLease(lease);
              _removeOptimisticMessage(optimistic);
              return;
            }
            _activeRelayLease = lease;
            _provider = lease.provider;
            await sendPrompt();
            recovered = true;
            markAccepted();
          }
        } catch (_) {
          recovered = false;
        }
      }
      if (recovered) {
        _scheduleCacheWrite();
        return;
      }
      if (!mounted || sendGeneration != _sendGeneration) {
        _removeOptimisticMessage(optimistic);
        return;
      }
      _abortCurrentSend(optimistic, text, images, files);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败：$e')));
      // 公网直注入：发送失败时重校验远端实况——provider 已在远端被删的话，
      // 本地选择自动清掉（跟随远端），下次发送不再打在失效 provider 上。
      if (_selectedRelayProfileId.isNotEmpty &&
          widget.shiyi != null &&
          DshEndpoint.modeOf(widget.shiyi!.settings) == 'remote') {
        unawaited(_loadMeta());
      }
    }
  }

  /// 插话时先在本地立刻收口，再等待串行队列完成 DSH 旧回合取消。
  Future<void> _interruptLocallyForPrompt() async {
    _resetSubagentStatusForNewTurn();
    _ignoreLateRunningStatus = true;
    _sending = false;
    _running = false;
    _awaitingFinalReply = false;
    _turnEndSeen = false;
    _pendingPromptText = null;
    _stopPoll();
    _syncSubagentPolling();
    _finalizeSubagentStatus();
    _clearLiveUi(preserveVisible: true);
    if (mounted) setState(() {});
    try {
      await _turnCommands.enqueue(
        () => _api.cancel(widget.sessionId).timeout(const Duration(seconds: 2)),
      );
    } catch (_) {
      // Keep the local UI responsive; the subsequent prompt still gets the
      // next serialized slot and DSH can report a transport failure normally.
    } finally {
      await _releaseActiveRelayLease();
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    ++_sendGeneration;
    _ignoreLateRunningStatus = true;
    _sending = false;
    _running = false;
    _awaitingFinalReply = false;
    _turnEndSeen = false;
    _pendingPromptText = null;
    _stopPoll();
    _syncSubagentPolling();
    _clearLiveUi(preserveVisible: true);
    if (mounted) {
      setState(() {
        _stopping = true;
        _sending = false;
        _running = false;
      });
    }
    try {
      await _turnCommands.enqueue(
        () => _api.cancel(widget.sessionId).timeout(const Duration(seconds: 2)),
      );
      unawaited(_refreshHistory(clearLive: true));
      unawaited(_refreshSubagents());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('停止失败：$e')));
    } finally {
      await _releaseActiveRelayLease();
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _loadContextLimit() async {
    final global = widget.shiyi?.settings.contextLimit ?? kDefaultContextLimit;
    final limit = await DshChatCache.effectiveContextLimitFor(
      widget.sessionId,
      global,
    );
    if (!mounted) return;
    setState(() => _contextLimit = limit);
  }

  Future<void> _editContextLimit() async {
    if (_compacting || _sending || _running) return;
    final next = await showSessionContextLimitDialog(
      context: context,
      currentLimit: _contextLimit,
    );
    if (next == null || !mounted) return;
    await DshChatCache.writeContextLimit(widget.sessionId, next);
    if (!mounted) return;
    setState(() => _contextLimit = next);
  }

  Future<void> _compactContext() async {
    if (_compacting || _sending || _running) return;
    final confirmed = await showIosConfirmDialog(
      context: context,
      title: '压缩上下文？',
      message: '较早的对话会变成摘要，完整记录仍保留。',
      confirmLabel: '压缩',
    );
    if (!confirmed || !mounted) return;
    setState(() => _compacting = true);
    try {
      final execution = await _api.compactSession(widget.sessionId);
      if (!execution.ok) {
        throw DshApiException(execution.error ?? 'DSH 压缩命令失败');
      }
      _cacheTimer?.cancel();
      _cacheTimer = null;
      await _cacheWriteTail;
      await DshChatCache.clear(widget.sessionId);
      await _refreshHistory(
        clearLive: true,
        authoritative: true,
        throwOnError: true,
      );
      await _refreshMeta();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('上下文已压缩')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('压缩失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _compacting = false);
    }
  }

  Future<void> _pickImage({required bool fromCamera}) async {
    try {
      if (fromCamera) {
        final path = await ImageService.pickAndSave(fromCamera: true);
        if (path != null && mounted) {
          setState(() => _pendingImages.add(path));
        }
      } else {
        final paths = await ImageService.pickMultipleAndSave();
        if (paths.isNotEmpty && mounted) {
          setState(() => _pendingImages.addAll(paths));
        }
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

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      for (final file in result.files) {
        final source = file.path;
        if (source == null || !mounted) continue;
        final copied = await FileWorkspace.copyToAttachments(
          source,
          workspacePath: _cwd,
        );
        if (copied == null || !mounted) continue;
        setState(() => _pendingFiles.add(copied));
        added++;
      }
      if (added == 0 && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文件复制到工作目录失败')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '选择文件失败：${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  void _pickAttachment() {
    showIosFadeModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: CupertinoActionSheet(
          title: const Text('添加附件'),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(_pickImage(fromCamera: false));
              },
              child: const Text('从相册选择'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(_pickImage(fromCamera: true));
              },
              child: Text(Platform.isWindows ? '从相机（降级相册）' : '拍照'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(_pickFile());
              },
              child: const Text('发送文件'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ),
      ),
    );
  }

  void _onInputChanged() {
    if (!isSkillSlashTrigger(_input.text)) return;
    final now = DateTime.now();
    if (_lastSlashTrigger != null &&
        now.difference(_lastSlashTrigger!).inMilliseconds < 600) {
      return;
    }
    _lastSlashTrigger = now;
    unawaited(_pickSkillSheet());
  }

  /// 选择技能后移除触发选择器用的末尾斜杠，保留用户已经输入的正文。
  void _stripSlash() {
    final next = stripSkillSlashTrigger(_input.text);
    if (next == _input.text) return;
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  Future<void> _pickSkillSheet() async {
    try {
      final cwd = (_cwd.isNotEmpty ? _cwd : _summary?.cwd)?.trim() ?? '';
      await _api.createSession(
        cwd: cwd.isEmpty ? null : cwd,
        sessionId: widget.sessionId,
      );
      final skills = await _api.listSkills(sessionId: widget.sessionId);
      if (!mounted) return;
      if (skills.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前会话没有可用技能')));
        return;
      }
      final picked = await showIosFadeSheet<Set<String>>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) {
          final selected = _selectedSkills.map((s) => s.name).toSet();
          return StatefulBuilder(
            builder: (ctx, setSheetState) => SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '加载技能',
                                style: Theme.of(ctx).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '可多选，发送时会一起调用',
                                style: Theme.of(ctx).textTheme.bodySmall
                                    ?.copyWith(color: Theme.of(ctx).hintColor),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, selected),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                      itemCount: skills.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 2),
                      itemBuilder: (_, index) {
                        final skill = skills[index];
                        final checked = selected.contains(skill.name);
                        return ListTile(
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          tileColor: checked
                              ? Theme.of(
                                  ctx,
                                ).colorScheme.primary.withValues(alpha: .10)
                              : null,
                          leading: Icon(
                            CupertinoIcons.bolt_fill,
                            size: 18,
                            color: checked
                                ? Theme.of(ctx).colorScheme.primary
                                : Theme.of(ctx).hintColor,
                          ),
                          title: Text('/${skill.name}'),
                          subtitle: skill.description.isEmpty
                              ? null
                              : Text(
                                  skill.description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: Icon(
                            checked
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.circle,
                            color: checked
                                ? Theme.of(ctx).colorScheme.primary
                                : Theme.of(ctx).hintColor,
                          ),
                          onTap: () {
                            if (checked) {
                              selected.remove(skill.name);
                            } else {
                              selected.add(skill.name);
                            }
                            setSheetState(() {});
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (picked == null || !mounted) return;
      final byName = {for (final skill in skills) skill.name: skill};
      setState(() {
        _selectedSkills
          ..clear()
          ..addAll(
            picked.map((name) => byName[name]).whereType<DshSkillInfo>(),
          );
      });
      _stripSlash();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('技能加载失败：$e')));
    }
  }

  Future<void> _openWorkspace() async {
    // DSH 的 cwd 属于 DSH 主机（本机、局域网或公网电脑）。这里必须用
    // host API 选择目录并写回 session cwd，不能打开手机本地文件选择器。
    try {
      final selected = await pickDshHostDirectory(
        context,
        api: _api,
        initialPath: _cwd.trim(),
      );
      final path = selected?.trim() ?? '';
      if (path.isEmpty || !mounted || path == _cwd.trim()) return;
      await _api.updateSessionCwd(widget.sessionId, path);
      if (!mounted) return;
      setState(() {
        _cwd = path;
        _summary = _summary?.withCwd(path);
      });
      _scheduleCacheWrite();
      unawaited(_loadMeta());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('会话工作目录已切换：$path')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换会话工作目录失败：$e')));
    }
  }

  /// 合并 session.models、llm.models 和带有效模型目录的 llm.providers，
  /// 避免远端模型缺失，同时不把纯凭据槽显示成模型组。
  static List<DshModelGroup> _mergeDshModelGroups(
    List<DshModelGroup> first,
    List<DshModelGroup> second,
  ) {
    final byId = <String, DshModelGroup>{};
    for (final group in [...first, ...second]) {
      final id = group.id.trim();
      if (id.isEmpty) continue;
      final previous = byId[id];
      if (previous == null) {
        byId[id] = group;
        continue;
      }
      final models = <String, DshModelInfo>{
        for (final model in previous.models)
          if (model.id.trim().isNotEmpty) model.id: model,
        for (final model in group.models)
          if (model.id.trim().isNotEmpty) model.id: model,
      };
      byId[id] = DshModelGroup(
        id: id,
        name: group.name.trim().isNotEmpty ? group.name : previous.name,
        models: models.values.toList(),
      );
    }
    return byId.values.toList();
  }

  Future<void> _connectDownlink() async {
    final gen = ++_muxGen;
    _muxRetry?.cancel();
    await _muxSub?.cancel();
    await _hostSub?.cancel();
    _muxSub = null;
    _hostSub = null;
    try {
      _muxSub = _api.watchMux().listen(
        (frame) {
          if (gen == _muxGen) _onDownlinkFrame(frame);
        },
        onError: (_) {
          if (gen == _muxGen) _onMuxLost();
        },
        onDone: () {
          if (gen == _muxGen) _onMuxLost();
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (gen == _muxGen) _onMuxLost();
    }
    try {
      _hostSub = _api.watchHost().listen(
        (frame) {
          if (gen == _muxGen) _onDownlinkFrame(frame);
        },
        onError: (_) {},
        cancelOnError: true,
      );
    } catch (_) {}
  }

  void _onMuxLost() {
    if (!mounted) return;
    _muxUp = false;
    _muxRetry?.cancel();
    _muxRetry = Timer(const Duration(seconds: 2), () {
      if (mounted && _muxGen != 0) unawaited(_connectDownlink());
    });
  }

  void _onDownlinkFrame(Map<String, dynamic> frame) {
    final type = frame['type']?.toString() ?? '';
    final sid = frame['sessionId']?.toString() ?? '';
    if (sid.isNotEmpty && sid != widget.sessionId) return;

    if (type == 'session/subscribed') {
      _muxUp = true;
      final last = (frame['lastSeq'] as num?)?.toInt() ?? -1;
      if (last > _live.lastSeq) {
        unawaited(_refreshHistory(clearLive: false));
      }
      return;
    }
    if (type == 'stream/error') {
      _muxUp = false;
      return;
    }
    if (type == 'host/session-status') {
      final running = frame['running'] == true;
      if (mounted && running != _running) {
        final wasRunning = _running;
        setState(() => _running = running);
        if (running && !_awaitingFinalReply) {
          _awaitingFinalReply = true;
          _pendingPromptText = _latestUserText(_messages);
          _live.begin();
          _resetLiveNotifiers();
          _ensureLiveBubble();
        } else if (!running && (wasRunning || _awaitingFinalReply)) {
          // 主 agent 等子代理返回时也会 running=false，不能当成停止。
          // 只收思考面板，子代理跟 subagent.list 走，并允许稍后恢复。
          _sending = false;
          _awaitingFinalReply = false;
          _turnEndSeen = true;
          _pendingPromptText = null;
          _clearLiveUi(preserveVisible: true);
          _syncSubagentPolling();
          unawaited(_refreshSubagents());
          unawaited(_refreshHistory(clearLive: true));
          return;
        }
        _syncSubagentPolling();
        unawaited(_refreshSubagents());
        if (running) _maybePoll();
      }
      return;
    }
    if (type == 'question/requested') {
      final rpcId = frame['rpcId']?.toString() ?? '';
      if (rpcId.isEmpty || !mounted) return;
      setState(() {
        _pendingQuestion = {
          'rpcId': rpcId,
          'sessionId': sid.isEmpty ? widget.sessionId : sid,
          'questions': (frame['questions'] as List?) ?? const [],
        };
      });
      return;
    }
    if (type == 'question/resolved') {
      final cur = _pendingQuestion;
      final qRpcId = frame['questionRpcId']?.toString() ?? '';
      if (cur != null && (qRpcId.isEmpty || cur['rpcId'] == qRpcId)) {
        if (mounted) setState(() => _pendingQuestion = null);
      }
      return;
    }
    if (type != 'session/event') return;

    final ev = (frame['event'] as Map?)?.cast<String, dynamic>();
    if (ev == null) return;
    final kind = ev['type']?.toString() ?? '';

    // 权限预设切换（本端或官方 Web UI 等其他客户端）实时反映到按钮。
    if (kind == 'permission/preset') {
      final preset = (((ev['data'] as Map?)?['preset']) ?? '').toString();
      if (preset.isNotEmpty && mounted && preset != _sessionPermission) {
        setState(() => _sessionPermission = preset);
      }
      return;
    }

    // 停止/插话后，服务端旧回合可能还有迟到事件；新回合开始前全部丢弃，
    // 防止旧输出把本地 UI 再次点亮或串入新消息。
    if (_ignoreLateRunningStatus) {
      return;
    }

    if (kind == 'user/message' && _isDuplicateSubagentReport(ev)) {
      // DSH may replay a report already delivered through inbox/spliced. The
      // following auto turn is only an acknowledgement of that same report.
      _suppressDuplicateSubagentTurn = true;
      _finishPendingTurn();
      if (mounted) setState(() => _running = false);
      _syncSubagentPolling();
      unawaited(_refreshHistory(clearLive: true));
      return;
    }
    if (_suppressDuplicateSubagentTurn) {
      if (kind == 'assistant/message') {
        _suppressDuplicateSubagentTurn = false;
        unawaited(_refreshHistory(clearLive: true));
      } else if (kind == 'turn/end') {
        _suppressDuplicateSubagentTurn = false;
      }
      return;
    }

    final changed =
        kind == 'turn/end' ||
            (kind == 'assistant/message' && !_awaitingFinalReply)
        ? false
        : _live.ingest(ev);
    if (kind == 'assistant/chunk') {
      if (!mounted) return;
      if (!_running) {
        setState(() => _running = true);
        _syncSubagentPolling();
      }
      if (changed) {
        _ensureLiveBubble();
        _publishLive();
      }
      return;
    }
    if (kind == 'tool/call') {
      _recordToolCall(ev);
      if (_live.open && changed) {
        _ensureLiveBubble();
        _syncLiveTools();
      } else {
        unawaited(_refreshHistory(clearLive: false));
      }
      return;
    }
    if (kind == 'tool/result') {
      _recordToolResult(ev);
      unawaited(_refreshHistory(clearLive: false));
      return;
    }
    if (kind == 'assistant/message') {
      _finishOpenToolEvents();
      if (_awaitingFinalReply) {
        if (!_live.open) _live.continueTurn();
        _ensureLiveBubble();
        _publishLive(force: true);
      }
      unawaited(_refreshHistory(clearLive: false));
      return;
    }
    if (kind == 'turn/end' ||
        kind == 'user/message' ||
        kind == 'agent/inbox/spliced') {
      if (kind == 'turn/end' && mounted) {
        _finishOpenToolEvents(ok: false);
        _turnEndSeen = true;
        setState(() => _running = false);
        _syncSubagentPolling();
        unawaited(_refreshSubagents());
      }
      unawaited(_refreshHistory(clearLive: kind == 'turn/end'));
    }
  }

  bool _isDuplicateSubagentReport(Map<String, dynamic> ev) {
    final data = (ev['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final source = (data['source'] as Map?)?.cast<String, dynamic>();
    if (source?['kind']?.toString() != 'subagent-report') return false;
    final id = data['id']?.toString().trim() ?? '';
    if (id.isEmpty) return false;
    return _messages.any((message) => message.id == 'dsh-$id');
  }

  Future<void> _refreshHistory({
    required bool clearLive,
    bool authoritative = false,
    bool throwOnError = false,
  }) async {
    try {
      final bundle = await _api.historyBundle(widget.sessionId);
      if (!mounted) return;
      if (bundle.permissionPreset != null &&
          bundle.permissionPreset != _sessionPermission) {
        setState(() => _sessionPermission = bundle.permissionPreset!);
      }
      _rememberResponseModels(bundle);
      _adoptHistoryReasoning(bundle.messages);
      final current = DshChatCache.materializeMessages(
        sessionId: widget.sessionId,
        messages: _messages,
        liveText: _live.text,
        liveReasoning: _live.reasoning,
        liveToolCalls: _live.toolCalls,
      );
      final historyConfirmsLive = !dshHistoryRegressed(
        current: current,
        incoming: bundle.messages,
      );
      final finalizesTurn = _historyFinalizesPendingTurn(bundle);
      final preserveLocalProgress =
          !authoritative &&
          !finalizesTurn &&
          (_shouldPreserveLocalProgress(bundle) || !historyConfirmsLive);
      _replaceMessages(
        _mergeHistory(
          bundle.messages,
          live: bundle.live,
          preserveLocalProgress: preserveLocalProgress,
        ),
      );
      if (finalizesTurn) {
        _finishPendingTurn();
      } else {
        _adoptLive(
          bundle.live,
          force: true,
          allowClose:
              !_awaitingFinalReply && !bundle.live.open && historyConfirmsLive,
        );
        if (clearLive && _awaitingFinalReply) {
          _historySettleAttempts++;
          final step = _historySettleAttempts
              .clamp(1, _maxHistorySettleDelayStep)
              .toInt();
          _historySettleTimer?.cancel();
          _historySettleTimer = Timer(Duration(milliseconds: 250 * step), () {
            _historySettleTimer = null;
            if (mounted) unawaited(_refreshHistory(clearLive: true));
          });
        }
      }
      _scheduleCacheWrite();
      _scrollToBottom();
    } catch (e) {
      // 不自动拉起服务：刷新失败等用户手动启动。手动压缩需要把失败
      // 交给调用方，避免在权威历史尚未重载时误报成功。
      if (throwOnError) rethrow;
    }
  }

  Future<void> _refreshMeta() async {
    try {
      final list = await _api.listSessions();
      if (!mounted) return;
      _applySessionMeta(list);
    } catch (_) {}
  }

  void _applySessionMeta(List<DshSessionSummary> list) {
    final me = list.where((s) => s.sessionId == widget.sessionId).firstOrNull;
    final running = me?.running ?? false;
    setState(() {
      _running = running;
      if (me != null && (me.title?.isNotEmpty ?? false)) {
        _title = me.title!;
      }
      if (me?.cwd != null && me!.cwd!.isNotEmpty) _cwd = me.cwd!;
      _summary = me;
    });
    _scheduleCacheWrite();
    _syncSubagentPolling();
  }

  void _rememberResponseModels(DshHistoryBundle bundle) {
    final shiyi = widget.shiyi;
    if (shiyi == null || bundle.responseModels.isEmpty) return;
    final fresh = bundle.responseModels.difference(_syncedResponseModels);
    if (fresh.isEmpty) return;
    _syncedResponseModels.addAll(fresh);
    unawaited(
      DshModelSync.rememberResponseModels(
        shiyi.settings,
        fresh,
        api: _api,
        scopeKey: DshService.instance.currentScopeKey,
      ),
    );
  }

  Future<void> _refreshSubagents() async {
    if (_refreshingSubagents) return;
    final refreshGeneration = _subagentRefreshGeneration;
    _refreshingSubagents = true;
    try {
      final result = await _api.listSubagents(widget.sessionId);
      if (!mounted || refreshGeneration != _subagentRefreshGeneration) return;
      setState(() {
        _subagents = result.entries;
      });
      _syncSubagentPolling();
    } catch (_) {
      // 父会话尚未就绪或服务切换时保留上次状态，下一轮再取。
    } finally {
      _refreshingSubagents = false;
    }
  }

  void _syncSubagentPolling() {
    if (!mounted) return;
    final shouldPoll = _running || _subagents.any((e) => e.running);
    if (shouldPoll) {
      _subagentPollTimer ??= Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) {
        unawaited(_refreshSubagents());
      });
      return;
    }
    _subagentPollTimer?.cancel();
    _subagentPollTimer = null;
  }

  void _finalizeSubagentStatus() {
    _subagentRefreshGeneration++;
    _subagents = [];
    if (mounted) setState(() {});
  }

  /// 让旧回合的子代理投影和异步刷新结果彻底失效。
  void _resetSubagentStatusForNewTurn() {
    _subagentRefreshGeneration++;
    _subagents = [];
    if (mounted) setState(() {});
  }

  List<ChatMessage> _mergeHistory(
    List<ChatMessage> incoming, {
    DshLiveTurn? live,
    required bool preserveLocalProgress,
  }) {
    final current = DshChatCache.materializeMessages(
      sessionId: widget.sessionId,
      messages: _messages,
      liveText: _live.text,
      liveReasoning: _live.reasoning,
      liveToolCalls: _live.toolCalls,
    );
    return dshMergeHistoryPreservingProgress(
      current: current,
      incoming: incoming,
      preserveLocalProgress: preserveLocalProgress,
      incomingLiveVisible:
          live?.hasVisible == true || _live.open || _live.hasVisible,
    );
  }

  bool _shouldPreserveLocalProgress(DshHistoryBundle bundle) =>
      _awaitingFinalReply ||
      _running ||
      bundle.live.open ||
      bundle.live.hasVisible;

  String? _latestUserText(List<ChatMessage> messages) {
    for (final message in messages.reversed) {
      if (message.role == 'user' && message.content.trim().isNotEmpty) {
        return message.content.trim();
      }
    }
    return null;
  }

  bool _historyFinalizesPendingTurn(DshHistoryBundle bundle) {
    if (!_awaitingFinalReply || !(_turnEndSeen || bundle.turnEnded)) {
      return false;
    }
    final prompt = _pendingPromptText?.trim() ?? '';
    var userIndex = -1;
    for (var i = bundle.messages.length - 1; i >= 0; i--) {
      final message = bundle.messages[i];
      if (message.role != 'user') continue;
      if (prompt.isEmpty || message.content.trim() == prompt) {
        userIndex = i;
        break;
      }
    }
    if (userIndex < 0) return false;
    for (var i = userIndex + 1; i < bundle.messages.length; i++) {
      final message = bundle.messages[i];
      if (message.role == 'assistant' &&
          (message.content.trim().isNotEmpty ||
              message.reasoning.trim().isNotEmpty ||
              message.toolCalls.isNotEmpty)) {
        return true;
      }
    }
    return false;
  }

  void _finishPendingTurn() {
    _awaitingFinalReply = false;
    _turnEndSeen = false;
    _pendingPromptText = null;
    _historySettleTimer?.cancel();
    _historySettleTimer = null;
    _historySettleAttempts = 0;
    _clearLiveUi();
    unawaited(_releaseActiveRelayLease());
  }

  bool _historyConfirmsLive(List<ChatMessage> incoming) {
    final hasLocalLive =
        _live.open ||
        _live.hasVisible ||
        _messages.any((m) => m.streaming || m.id == dshCachedLiveMessageId);
    if (!hasLocalLive) return true;
    final current = DshChatCache.materializeMessages(
      sessionId: widget.sessionId,
      messages: _messages,
      liveText: _live.text,
      liveReasoning: _live.reasoning,
      liveToolCalls: _live.toolCalls,
    );
    return !dshHistoryRegressed(current: current, incoming: incoming);
  }

  bool _sameMessages(List<ChatMessage> a, List<ChatMessage> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.role != y.role ||
          x.content != y.content ||
          x.reasoning != y.reasoning ||
          x.subagentSummary != y.subagentSummary ||
          x.streaming != y.streaming ||
          x.runtimeContext != y.runtimeContext ||
          x.toolCalls.length != y.toolCalls.length) {
        return false;
      }
    }
    return true;
  }

  String _itemKey(ChatMessage m) {
    if (m.role == 'user') {
      final alias = _userEnterKeys[m.content.trim()];
      if (alias != null) return alias;
    }
    if (m.streaming || m.id == _liveId || m.id == dshCachedLiveMessageId) {
      return _liveId;
    }
    return m.id;
  }

  void _replaceMessages(List<ChatMessage> next) {
    if (!mounted || _sameMessages(_messages, next)) return;
    setState(() => _messages = next);
    _scheduleCacheWrite();
  }

  void _adoptLive(
    DshLiveTurn live, {
    bool force = false,
    bool allowClose = false,
  }) {
    _live.mergeProgressFrom(live, allowClose: allowClose);
    if (_live.open) {
      _ensureLiveBubble(notify: false);
      if (_live.hasVisible) _publishLive(force: force);
      if (mounted) setState(() {});
    } else if (!_live.open && allowClose) {
      _clearLiveUi();
    }
  }

  void _ensureLiveBubble({bool notify = true}) {
    final existingIndex = _messages.lastIndexWhere(
      (m) => m.streaming && m.role == 'assistant',
    );
    if (existingIndex >= 0) {
      final existing = _messages[existingIndex];
      if (_live.toolCalls.isNotEmpty) {
        existing.toolCalls = List.of(_live.toolCalls);
      }
      _messages.removeWhere(
        (m) =>
            m.id == dshCachedLiveMessageId ||
            (m.streaming && !identical(m, existing)),
      );
      if (_messages.isEmpty || !identical(_messages.last, existing)) {
        _messages.remove(existing);
        _messages.add(existing);
      }
      if (notify && mounted) setState(() {});
      return;
    }
    _messages.removeWhere((m) => m.id == dshCachedLiveMessageId);
    _messages.add(
      ChatMessage(
        id: _liveId,
        sessionId: widget.sessionId,
        role: 'assistant',
        content: '',
        streaming: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        toolCalls: List.of(_live.toolCalls),
      ),
    );
    if (notify && mounted) setState(() {});
  }

  void _syncLiveTools() {
    final i = _messages.lastIndexWhere((m) => m.streaming);
    if (i < 0) return;
    _messages[i].toolCalls = List.of(_live.toolCalls);
    if (mounted) setState(() {});
    _scheduleCacheWrite();
  }

  void _clearLiveUi({bool preserveVisible = false}) {
    if (preserveVisible) {
      _messages = DshChatCache.materializeMessages(
        sessionId: widget.sessionId,
        messages: _messages,
        liveText: _live.text,
        liveReasoning: _live.reasoning,
        liveToolCalls: _live.toolCalls,
      );
    } else {
      _messages.removeWhere(
        (m) => m.streaming || m.id == _liveId || m.id == dshCachedLiveMessageId,
      );
    }
    _enteredMessageIds.remove(_liveId);
    _live.reset();
    _resetLiveNotifiers(keepVisible: preserveVisible);
    if (mounted) setState(() {});
    _scheduleCacheWrite();
  }

  void _resetLiveNotifiers({bool keepVisible = false}) {
    if (!keepVisible) {
      _streamText.value = '';
      _streamReasoning.value = '';
    }
    _lastStreamLen = 0;
  }

  void _publishLive({bool force = false}) {
    final total = _live.text.length + _live.reasoning.length;
    final now = DateTime.now();
    // 对齐 2.0：reasoning 每个回调立即推送；只有正文布局走节流。
    // 否则连续的小 reasoning-delta 会一直停在“思考中”空面板里。
    _streamReasoning.value = _live.reasoning;
    if (!force &&
        _lastStreamLen > 0 &&
        now.difference(_lastStreamEmit).inMilliseconds < 80 &&
        total - _lastStreamLen < 200) {
      return;
    }
    _lastStreamEmit = now;
    _lastStreamLen = total;
    _streamText.value = _live.text;
    _scheduleCacheWrite();
  }

  /// WebSocket 丢掉某段 reasoning 时，直接从 DSH 已落盘的 assistant/message
  /// 补回当前回合的最新思考。旧版拾忆由 LlmClient.onTurn 直接做同一件事。
  void _adoptHistoryReasoning(List<ChatMessage> messages) {
    if (!_awaitingFinalReply || messages.isEmpty) return;
    final prompt = _pendingPromptText?.trim() ?? '';
    var userIndex = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role != 'user') continue;
      if (prompt.isEmpty || message.content.trim() == prompt) {
        userIndex = i;
        break;
      }
    }
    if (userIndex < 0) {
      userIndex = messages.lastIndexWhere((m) => m.role == 'user');
    }
    if (userIndex < 0) return;

    String latest = '';
    for (var i = userIndex + 1; i < messages.length; i++) {
      final message = messages[i];
      if (message.role == 'assistant' && message.reasoning.trim().isNotEmpty) {
        latest = message.reasoning;
      }
    }
    if (latest.isEmpty || latest.length <= _live.reasoning.length) return;
    _live.reasoning = latest;
    _live.open = true;
    _ensureLiveBubble(notify: false);
    _publishLive(force: true);
  }

  void _onStreamTextChanged() {
    if (_autoScrollScheduled) return;
    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.pixels <= 96) {
        _scroll.jumpTo(0);
      }
    });
  }

  /// reverse 列表里最新消息在 offset 0，即视觉底部。
  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (animated) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  void _copy(ChatMessage msg) {
    Clipboard.setData(ClipboardData(text: msg.content));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制')));
  }

  Future<void> _submitQuestionAnswers(
    List<Map<String, dynamic>> answers,
  ) async {
    final q = _pendingQuestion;
    if (q == null || _answerBusy) return;
    setState(() => _answerBusy = true);
    try {
      await _api.answerQuestion(
        q['rpcId']?.toString() ?? '',
        q['sessionId']?.toString() ?? widget.sessionId,
        answers,
      );
      if (!mounted) return;
      setState(() {
        _pendingQuestion = null;
        _answerBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _answerBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('回答失败：$e')));
    }
  }

  Future<void> _cancelQuestion() async {
    final q = _pendingQuestion;
    if (q == null || _answerBusy) return;
    setState(() => _answerBusy = true);
    try {
      await _api.cancelQuestion(q['rpcId']?.toString() ?? '');
      if (!mounted) return;
      setState(() {
        _pendingQuestion = null;
        _answerBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _answerBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('取消提问失败：$e')));
    }
  }

  Future<void> _saveMemory(ChatMessage msg) async {
    final shiyi = widget.shiyi;
    if (shiyi == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await shiyi.addMemoryManual(msg.content);
    messenger.showSnackBar(const SnackBar(content: Text('已保存到长期记忆')));
  }

  void _saveSkill(ChatMessage msg) {
    final shiyi = widget.shiyi;
    if (shiyi == null) return;
    _saveSkillDialog(shiyi, msg.content);
  }

  void _saveSkillDialog(ShiyiState shiyi, String content) {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final contentCtrl = TextEditingController(text: content);
    showIosFadeDialog<void>(
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
                await shiyi.saveSkill(
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

  void _pop() {
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop =
        Platform.isWindows && MediaQuery.sizeOf(context).width >= 720;
    final events = _toolEvents;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _pop();
      },
      child: Stack(
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
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Platform.isWindows
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
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      SizedBox(
                        width: 116,
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
                          _title.isEmpty ? '新会话' : _title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (_model.isNotEmpty)
                          Text(
                            _model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall!.copyWith(
                              color: theme.hintColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  body: ChatFloatingComposerScaffold(
                    messages: (context, overlayHeight) =>
                        _buildMessages(overlayHeight),
                    overlay: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_selectedSkills.isNotEmpty)
                          _DshLoadedSkillChips(
                            skills: _selectedSkills,
                            onRemove: (skill) => setState(
                              () => _selectedSkills.removeWhere(
                                (item) => item.name == skill.name,
                              ),
                            ),
                          ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, .35),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                          child: _pendingQuestion == null
                              ? const SizedBox.shrink(
                                  key: ValueKey('dsh-no-question'),
                                )
                              : AgentQuestionPanel(
                                  key: ValueKey(
                                    'dsh-question-${_pendingQuestion!['rpcId']}',
                                  ),
                                  title: 'DS Harness 向你提问',
                                  questions:
                                      ((_pendingQuestion!['questions']
                                                  as List?) ??
                                              const [])
                                          .map(
                                            (e) => (e as Map)
                                                .cast<String, dynamic>(),
                                          )
                                          .toList(),
                                  busy: _answerBusy,
                                  showCustomAnswers: true,
                                  showSubmitActions: true,
                                  onSubmit: _submitQuestionAnswers,
                                  onCancel: _cancelQuestion,
                                ),
                        ),
                        if (_pendingQuestion == null) _composerFloatChips(),
                        if (_pendingQuestion == null)
                          LiquidGlassChatComposer(
                            input: _input,
                            busy: _sending || _running,
                            allowSendWhileBusy: true,
                            enterToSend:
                                widget.shiyi?.settings.enterToSend ?? true,
                            pendingImages: _pendingImages,
                            pendingFiles: _pendingFiles,
                            onPickAttachment: _pickAttachment,
                            onRemoveImage: (index) =>
                                setState(() => _pendingImages.removeAt(index)),
                            onRemoveFile: (index) =>
                                setState(() => _pendingFiles.removeAt(index)),
                            onSend: _send,
                            onStop: _stopping ? () {} : _stop,
                            modelOptions: _sessionModelOptions,
                            modelValue: _selectedProfileName,
                            modelId: _model,
                            onModelChanged: _selectSessionProfile,
                            modelEnabled: true,
                            onModelOpening: () => unawaited(_loadMeta()),
                            thinkingOptions: _thinkingOptions,
                            thinkingValue: _thinkingOn
                                ? _reasoningEffort
                                : _lastNonOffEffort,
                            onThinkingChanged: _setReasoningEffort,
                            thinkingEnabled: true,
                            thinkingOn: _thinkingOn,
                            onThinkingToggled: _thinkingOptions.isNotEmpty
                                ? _setThinkingOn
                                : null,
                            permissionOptions: _permissionOptions,
                            permissionValue: _sessionPermission.isNotEmpty
                                ? _sessionPermission
                                : _permissionDefault,
                            onPermissionChanged: _setDefaultPermission,
                            permissionEnabled: _permissionOptions.isNotEmpty,
                            onCompress: _compactContext,
                            compressBusy: _compacting,
                            onContextLimit: _editContextLimit,
                            contextLimitLabel: formatContextLimitLabel(
                              _contextLimit,
                            ),
                            onWorkspacePressed: _openWorkspace,
                            workspaceTooltip: _cwd.isEmpty ? '项目目录' : _cwd,
                          ),
                      ],
                    ),
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
      ),
    );
  }

  bool _shouldAnimateEnter(ChatMessage message) {
    if (_enteredMessageIds.contains(message.id)) return false;
    if (message.id == '$_liveId-thinking') return false;
    var should = false;
    if (message.role == 'user') {
      final key = message.content.trim();
      if (key.isNotEmpty && _enteredUserTexts.contains(key)) return false;
      final now = DateTime.now().millisecondsSinceEpoch;
      final fresh = message.createdAt > 0 && now - message.createdAt < 2500;
      if (!fresh && !message.id.startsWith('dsh-opt-')) return false;
      should = true;
      if (key.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _enteredUserTexts.add(key);
        });
      }
    } else if (message.role == 'assistant' && message.streaming) {
      should = true;
    }
    if (!should) return false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enteredMessageIds.add(message.id);
    });
    return true;
  }

  /// 会话仍活跃但无真实流式气泡时的“思考中”占位（常驻指示）。
  Widget _thinkingPlaceholder() {
    return KeyedSubtree(
      key: const ValueKey('dsh-thinking-placeholder'),
      child: ValueListenableBuilder<String>(
        valueListenable: _streamReasoning,
        builder: (context, reasoning, _) {
          final live = reasoning.isNotEmpty ? reasoning : _live.reasoning;
          return MessageBubble(
            message: ChatMessage(
              id: '$_liveId-thinking',
              sessionId: widget.sessionId,
              role: 'assistant',
              content: '',
              streaming: true,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
            liveReasoning: live.isEmpty ? null : live,
            busy: true,
            onCopy: _copy,
            onSpeak: _speakMessage,
            onStopSpeak: _stopSpeak,
          );
        },
      ),
    );
  }

  Widget _composerFloatChips() {
    final showSubagent = _subagentTotalCount > 0 || _subagentPeekOpen;
    final showStats = DshStatsBar.hasContent(_summary);
    if (!showSubagent && !showStats) return const SizedBox.shrink();
    return ChatComposerFloatChips(
      stats: showStats ? DshStatsBar(summary: _summary) : null,
      subagent: showSubagent
          ? SubagentStatusBar(
              key: const ValueKey('composer-subagent-bar'),
              text: _subagentBarText,
              agents: _subagentSnapshots(),
              resolveDetail: _resolveDshSubagent,
              onOpenChanged: (open) {
                if (mounted) {
                  setState(() => _subagentPeekOpen = open);
                }
              },
            )
          : null,
    );
  }

  Widget _buildMessages(double overlayHeight) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_waitingService) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(radius: 12),
            SizedBox(height: 12),
            Text(
              'DSH 启动中…',
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
          ],
        ),
      );
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
                '无法读取会话历史',
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
      return _DshWelcome(
        bottomInset: overlayHeight,
        onPick: (s) {
          _input.text = s;
          _send();
        },
      );
    }
    // reverse 列表：index 0 = 最新消息（offset 0 即视觉底部），
    // 进会话默认直接看到最新，不依赖加载完成后跳转定位。
    final items = visible.reversed.toList();
    final hasStreaming = items.any((m) => m.streaming);
    // 会话仍活跃（整轮未完 / 子代理在跑）但没有真实流式气泡时，
    // 在底部补一条“思考中”占位，保证指示常驻；有真实流就不画，避免重复。
    final thinkingNeeded = _isThinkingActive && !hasStreaming;
    final itemCount = items.length + (thinkingNeeded ? 1 : 0);
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
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
        itemCount: itemCount,
        itemBuilder: (context, i) {
          if (thinkingNeeded && i == 0) {
            // 视觉底部第一条 = 常驻“思考中”占位。
            return _thinkingPlaceholder();
          }
          final mi = thinkingNeeded ? i - 1 : i;
          final m = items[mi];
          return KeyedSubtree(
            key: ValueKey(_itemKey(m)),
            child: RepaintBoundary(
              child: ValueListenableBuilder<String>(
                valueListenable: _streamReasoning,
                builder: (context, reasoning, _) =>
                    ValueListenableBuilder<String>(
                      valueListenable: _streamText,
                      builder: (context, text, _) => MessageBubble(
                        message: m,
                        liveContent: m.streaming && text.isNotEmpty
                            ? text
                            : null,
                        liveReasoning: m.streaming && reasoning.isNotEmpty
                            ? reasoning
                            : null,
                        busy: m.streaming,
                        animateEnter: _shouldAnimateEnter(m),
                        onCopy: _copy,
                        speaking: _speakingId == m.id,
                        onSpeak: _speakMessage,
                        onStopSpeak: _stopSpeak,
                        onSaveMemory: widget.shiyi == null ? null : _saveMemory,
                        onSaveSkill: widget.shiyi == null ? null : _saveSkill,
                      ),
                    ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DshWelcome extends StatelessWidget {
  final ValueChanged<String> onPick;
  final double bottomInset;
  const _DshWelcome({required this.onPick, this.bottomInset = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const suggestions = ['看看当前工作区有哪些文件', '帮我总结一下这个目录在做什么', 'hi'];
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomInset),
      children: [
        const SizedBox(height: 40),
        const Center(child: WelcomeAvatar(size: 240)),
        const SizedBox(height: 12),
        Text(
          '你好，我是拾忆\nDeepSeek Harness 智能体',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge!.copyWith(height: 1.3),
        ),
        const SizedBox(height: 8),
        Text(
          '工作区文件 · 工具调用 · 子代理',
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

/// DSH 当前会话已加载技能，放在缓存/统计栏上方，和拾忆的技能胶囊保持一致。
class _DshLoadedSkillChips extends StatelessWidget {
  final List<DshSkillInfo> skills;
  final ValueChanged<DshSkillInfo> onRemove;
  const _DshLoadedSkillChips({required this.skills, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 5),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 5,
          children: [
            for (final skill in skills)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: LiquidGlassLens(
                  style: chatLiquidGlassStyle(
                    context,
                    cornerRadius: 10,
                    tint: theme.brightness == Brightness.dark
                        ? const Color(0x303A3A3C)
                        : const Color(0x40FFFFFF),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.bolt_fill,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            skill.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => onRemove(skill),
                          borderRadius: BorderRadius.circular(8),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.close, size: 15),
                          ),
                        ),
                      ],
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
