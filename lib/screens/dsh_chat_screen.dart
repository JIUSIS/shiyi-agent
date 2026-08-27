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
import '../core/slash_trigger.dart';
import '../services/dsh_api.dart';
import '../services/dsh_chat_cache.dart';
import '../services/dsh_live.dart';
import '../services/dsh_model_sync.dart';
import '../services/dsh_service.dart';
import '../services/file_workspace.dart';
import '../services/image_service.dart';
import '../services/tts_service.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/message_bubble.dart';
import '../widgets/agent_question_panel.dart';
import '../widgets/chat_liquid_glass.dart';
import '../widgets/dsh_stats_bar.dart';
import '../widgets/tool_pill.dart';
import '../widgets/ios_style.dart';
import '../widgets/traffic_lights_button.dart';
import '../widgets/welcome_avatar.dart';

/// 先读取本地会话快照，再开始整页淡入。
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
  try {
    snapshot = await DshChatCache.read(sessionId);
  } catch (_) {}
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
  Timer? _subagentStatusTimer;
  bool _refreshingSubagents = false;
  List<DshSubagentEntry> _subagents = [];
  bool _subagentStatusVisible = false;
  int _subagentFallbackCount = 0;
  final Set<String> _syncedResponseModels = {};
  late String _title = widget.initialTitle;
  late String _model = widget.shiyi?.settings.model.trim() ?? '';
  String _provider = '';
  String _reasoningEffort = '';
  String _lastNonOffEffort = '';
  Map<String, String?> _reasoningCapabilities = const {};
  bool _compacting = false;
  int _contextLimit = kDefaultContextLimit;
  late String _cwd = widget.initialSummary?.cwd ?? '';
  bool _stopping = false;
  bool _ignoreLateRunningStatus = false;
  int _sendGeneration = 0;
  bool _showToolLog = false;
  String? _speakingId;
  late DshSessionSummary? _summary = widget.initialSummary;
  Map<String, dynamic>? _pendingQuestion;
  bool _answerBusy = false;
  final ValueNotifier<String> _streamText = ValueNotifier('');
  final ValueNotifier<String> _streamReasoning = ValueNotifier('');
  final DshLiveTurn _live = DshLiveTurn();
  final List<String> _pendingImages = [];
  final List<String> _pendingFiles = [];

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
  DateTime? _lastSlashTrigger;
  int _pollTicks = 0;
  int _muxGen = 0;
  static const _liveId = 'dsh-live';
  static const _maxHistorySettleDelayStep = 8;

  DshApiClient get _api => DshService.instance.api;

  @override
  void initState() {
    super.initState();
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
    unawaited(_loadContextLimit());
    final snapshot = widget.initialSnapshot;
    if (snapshot?.hasUiData == true) {
      _restoreSnapshot(snapshot!, notify: false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(prefetched: snapshot));
    });
  }

  @override
  void dispose() {
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
    _subagentStatusTimer?.cancel();
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
    final actual = _subagents
        .where((e) => e.kind != 'diagnostic' && e.running)
        .length;
    if (actual > _subagentFallbackCount) return actual;
    return _subagentStatusVisible ? _subagentFallbackCount : actual;
  }

  int get _subagentTotalCount {
    final total = _subagents.where((e) => e.kind != 'diagnostic').length;
    final running = _runningSubagentCount;
    return total > running ? total : running;
  }

  /// 会话是否仍处于“正在思考/运行”状态。
  ///
  /// 只要父会话整轮还没收口（`_running` / `_awaitingFinalReply` / 正在发送），
  /// 或有运行中的子代理，都算活跃——此时「子代理 · 运行中」与消息区「思考中」
  /// 指示都应常驻。它只由真实活动驱动，不包含派生的显示标记，避免自我锁定。
  bool get _isThinkingActive =>
      _running ||
      _sending ||
      _awaitingFinalReply ||
      _subagents.any((e) => e.kind != 'diagnostic' && e.running);

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
    if (prefetched?.hasUiData != true) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      _error = null;
      _waitingService = false;
    }
    // 先显示本地快照，网络/服务慢时消息、模型和统计栏都不白屏。
    final cached = prefetched ?? await DshChatCache.read(widget.sessionId);
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
          _error = null;
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

  Future<void> _selectSessionProfile(SessionModelSelection selection) async {
    if (_compacting || _sending || _running) return;
    final shiyi = widget.shiyi;
    if (shiyi == null) return;
    ApiProfile? profile;
    for (final p in shiyi.apiProfiles) {
      if (p.name == selection.profile) {
        profile = p;
        break;
      }
    }
    final modelId = selection.model.trim();
    if (profile == null || modelId.isEmpty) return;
    final previousModel = _model;
    final previousProvider = _provider;
    final providerId = DshModelSync.providerIdForName(profile.name);
    setState(() {
      _model = modelId;
      _provider = providerId;
      _applyReasoningCapabilities(_model);
    });
    try {
      final selected = await _api.selectModel(
        widget.sessionId,
        providerId,
        modelId,
        reasoningEffort: _thinkingOn ? _reasoningEffort : 'off',
      );
      if (!mounted) return;
      setState(() {
        if (selected.model.isNotEmpty) _model = selected.model;
        if (selected.provider.isNotEmpty) _provider = selected.provider;
        _applyReasoningCapabilities(
          _model,
          selected: selected.reasoningEffort ?? _reasoningEffort,
        );
      });
      _scheduleCacheWrite();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _model = previousModel;
        _provider = previousProvider;
        _applyReasoningCapabilities(previousModel);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换模型失败：$e')));
    }
  }

  Future<void> _loadMeta() async {
    try {
      final models = await _api.sessionModels(widget.sessionId);
      if (mounted) {
        final currentModel = models.current.model;
        final selected = models.current.reasoningEffort ?? '';
        setState(() {
          if (currentModel.isNotEmpty) _model = currentModel;
          _provider = models.current.provider;
          _applyReasoningCapabilities(
            currentModel.isNotEmpty ? currentModel : _model,
            selected: selected,
          );
        });
        _scheduleCacheWrite();
      }
    } catch (_) {
      final fallback = widget.shiyi?.settings.model.trim() ?? '';
      if (mounted && fallback.isNotEmpty) {
        setState(() {
          _model = fallback;
          _applyReasoningCapabilities(fallback);
        });
        _scheduleCacheWrite();
      }
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
      } else if (!me.running && wasRunning && _awaitingFinalReply) {
        _turnEndSeen = true;
        unawaited(_refreshHistory(clearLive: true));
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
      if (_subagentStatusVisible) _finalizeSubagentStatus();
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty && _pendingImages.isEmpty && _pendingFiles.isEmpty) {
      return;
    }
    if (_sending || _running || _awaitingFinalReply) {
      _interruptLocallyForPrompt();
    }
    final sendGeneration = ++_sendGeneration;
    final content = StringBuffer();
    for (final path in _pendingImages) {
      content.writeln('![图片]($path)');
    }
    for (final path in _pendingFiles) {
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
    _ignoreLateRunningStatus = false;
    _live.begin();
    _resetLiveNotifiers();
    setState(() {
      _sending = true;
      _running = true;
      _messages.add(optimistic);
      _ensureLiveBubble(notify: false);
    });
    _scheduleCacheWrite();
    _scrollToBottom();
    _maybePoll();
    try {
      await DshService.instance.withRecover(
        () => _api.prompt(widget.sessionId, prompt),
        recover: true,
      );
      if (!mounted || sendGeneration != _sendGeneration) return;
      setState(() {
        _sending = false;
        _running = true;
      });
      _scrollToBottom();
      _maybePoll();
      _syncSubagentPolling();
      unawaited(_refreshSubagents());
    } catch (e) {
      if (!mounted || sendGeneration != _sendGeneration) return;
      setState(() {
        _sending = false;
        _messages.removeWhere((m) => m.id == optimistic.id);
      });
      _awaitingFinalReply = false;
      _turnEndSeen = false;
      _pendingPromptText = null;
      _clearLiveUi();
      _scheduleCacheWrite();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败：$e')));
    }
  }

  /// 插话时先在本地立刻收口，再异步通知 DSH 取消旧回合，避免等待网络响应。
  void _interruptLocallyForPrompt() {
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
    unawaited(_api.cancel(widget.sessionId).catchError((_) {}));
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
    _finalizeSubagentStatus();
    _clearLiveUi(preserveVisible: true);
    if (mounted) {
      setState(() {
        _stopping = true;
        _sending = false;
        _running = false;
      });
    }
    try {
      await _api.cancel(widget.sessionId).timeout(const Duration(seconds: 2));
      unawaited(_refreshHistory(clearLive: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('停止失败：$e')));
    } finally {
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
    if (!Platform.isWindows) {
      try {
        final selected = await FilePicker.platform.getDirectoryPath();
        final path = selected?.trim() ?? '';
        if (path.isEmpty || !mounted) return;
        await _api.updateSessionCwd(widget.sessionId, path);
        if (!mounted) return;
        setState(() => _cwd = path);
        _scheduleCacheWrite();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('工作目录已切换：$path')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('切换工作目录失败：$e')));
      }
      return;
    }
    if (_cwd.isEmpty) return;
    try {
      await _api.openPath(_cwd);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开：$e')));
    }
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
        } else if (!running && wasRunning && _awaitingFinalReply) {
          _turnEndSeen = true;
          unawaited(_refreshHistory(clearLive: true));
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

    // 停止/插话后，服务端旧回合可能还有迟到事件；新回合开始前全部丢弃，
    // 防止旧输出把本地 UI 再次点亮或串入新消息。
    if (_ignoreLateRunningStatus) {
      if (kind == 'turn/end') _finishPendingTurn();
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
      final data = (ev['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final toolName = (data['name'] ?? data['tool'] ?? '').toString();
      final toolPayload = '$toolName ${data['arguments'] ?? ''}'.toLowerCase();
      if (toolPayload.contains('subagent')) {
        _markSubagentActivity();
      }
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
        _scheduleSubagentHide();
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
    // 父会话由运行转结束，且整轮确实收口（无进行中子代理、无待收口回复）时，
    // 子代理/思考指示才随之收尾消失。
    if (!_isThinkingActive &&
        (_subagentStatusVisible || _subagentFallbackCount > 0)) {
      _finalizeSubagentStatus();
    }
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
    _refreshingSubagents = true;
    try {
      final result = await _api.listSubagents(widget.sessionId);
      if (!mounted) return;
      final running = result.entries
          .where((e) => e.kind != 'diagnostic' && e.running)
          .length;
      setState(() => _subagents = result.entries);
      if (running > 0) {
        // 子代理确实在跑：立即显示并持续刷新。
        _markSubagentActivity(count: running);
      } else if (_subagentStatusVisible) {
        // 子代理刚落盘，但父会话仍在整轮运行中：指示保留直到整个会话结束，
        // 否则 worker 返回后主模型继续分析时“子代理 · 运行中”会提前消失。
        _scheduleSubagentHide();
      }
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

  void _markSubagentActivity({int count = 1}) {
    _subagentStatusTimer?.cancel();
    final next = count < 1 ? 1 : count;
    final changed = !_subagentStatusVisible || _subagentFallbackCount != next;
    _subagentStatusVisible = true;
    if (next > _subagentFallbackCount) _subagentFallbackCount = next;
    if (changed && mounted) setState(() {});
  }

  /// 延迟隐藏“子代理 · 运行中”指示。只要会话整体仍处于思考/运行状态
  /// （父会话整轮未收口，或仍有子代理在跑），即使当前没有运行中的子代理
  /// 也保持指示，直到整轮 turn/end 真正收口才消失。
  void _scheduleSubagentHide() {
    _subagentStatusTimer?.cancel();
    _subagentStatusTimer = Timer(const Duration(milliseconds: 900), () {
      _subagentStatusTimer = null;
      if (!mounted) return;
      // 会话仍活跃：保留指示，等 turn/end / 子代理结束后统一收口。
      if (_isThinkingActive) {
        setState(() {
          _subagentStatusVisible = true;
          if (_subagentFallbackCount < 1) _subagentFallbackCount = 1;
        });
        return;
      }
      final stillRunning = _subagents.any(
        (e) => e.kind != 'diagnostic' && e.running,
      );
      if (stillRunning) return;
      setState(() {
        _subagentStatusVisible = false;
        _subagentFallbackCount = 0;
      });
    });
  }

  /// 整轮 turn/end 收口时调用：此刻整个会话确实结束了，子代理指示才真正消失。
  void _finalizeSubagentStatus() {
    _subagentStatusTimer?.cancel();
    _subagentStatusTimer = null;
    setState(() {
      _subagentStatusVisible = false;
      _subagentFallbackCount = 0;
    });
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
                        if (_runningSubagentCount > 0)
                          SubagentStatusBar(
                            text:
                                '子代理 $_runningSubagentCount/$_subagentTotalCount · 运行中',
                          ),
                        DshStatsBar(summary: _summary),
                        if (_cwd.isNotEmpty) _workspaceBar(theme),
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
                            modelOptions: [
                              for (final p
                                  in widget.shiyi?.apiProfiles ??
                                      const <ApiProfile>[])
                                SessionModelOption(
                                  value: p.name,
                                  label: p.name,
                                  subtitle: p.model,
                                  models:
                                      widget.shiyi?.cachedModelsForProfile(p) ??
                                      const <String>[],
                                ),
                            ],
                            modelValue: _selectedProfileName,
                            modelId: _model,
                            onModelChanged: _compacting || _sending || _running
                                ? null
                                : _selectSessionProfile,
                            modelEnabled:
                                !_compacting && !_sending && !_running,
                            thinkingOptions: _thinkingOptions,
                            thinkingValue: _thinkingOn
                                ? _reasoningEffort
                                : _lastNonOffEffort,
                            onThinkingChanged: _setReasoningEffort,
                            thinkingEnabled:
                                !_compacting && !_sending && !_running,
                            thinkingOn: _thinkingOn,
                            onThinkingToggled: _thinkingOptions.isNotEmpty
                                ? _setThinkingOn
                                : null,
                            onCompress: _compacting || _sending || _running
                                ? null
                                : _compactContext,
                            compressBusy: _compacting,
                            onContextLimit: _compacting || _sending || _running
                                ? null
                                : _editContextLimit,
                            contextLimitLabel: formatContextLimitLabel(
                              _contextLimit,
                            ),
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

  Widget _workspaceBar(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .14 : .05),
              blurRadius: 8,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: LiquidGlassLens(
          style: chatLiquidGlassStyle(context, cornerRadius: 10),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _openWorkspace,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _cwd,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall!.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.open_in_new, size: 13, color: theme.hintColor),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
