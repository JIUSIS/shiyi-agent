import 'dart:async';
import 'dart:convert';
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
import '../core/poll_visibility.dart';
import '../core/subagent_live.dart';
import '../core/at_trigger.dart';
import '../core/slash_trigger.dart';
import '../services/dsh_api.dart';
import '../services/dsh_chat_cache.dart';
import '../services/dsh_endpoint.dart';
import '../services/dsh_history_window.dart';
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
import '../widgets/animated_message_list.dart';
import '../widgets/agent_question_panel.dart';
import '../widgets/chat_liquid_glass.dart';
import '../widgets/subagent_mini_session.dart';
import '../widgets/dsh_directory_picker.dart';
import '../widgets/dsh_stats_bar.dart';
import '../widgets/tool_pill.dart';
import '../widgets/ios_style.dart';
import '../widgets/traffic_lights_button.dart';
import '../widgets/welcome_avatar.dart';

/// DSH 子代理列表按“连接 + 父会话”记忆，避免页面重建或重进时按钮消失。
final Map<String, List<DshSubagentEntry>> _dshSubagentMemory = {};

String _dshSubagentMemoryKey(String sessionId) =>
    '${DshService.instance.currentScopeKey}\n$sessionId';

void _rememberDshSubagents(String key, List<DshSubagentEntry> entries) {
  if (entries.isEmpty) return;
  _dshSubagentMemory[key] = List<DshSubagentEntry>.of(entries);
}

void _forgetDshSubagents(String key) {
  _dshSubagentMemory.remove(key);
}

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
/// mux 下行流重连退避。
///
/// 局域网 8080 是套在真网关前的转发层，普通 HTTP 能过、**WebSocket 升级后
/// 静默**（真机实测：升级成功但 6 秒无任何帧，见 docs/fix-log.md #391）。
/// 这种情况下每 2 秒重连等于持续烧手机/网络，按失败次数退避、封顶 60 秒；
/// 一旦真连上（收到 `session/subscribed`）计数归零，恢复灵敏。
Duration dshMuxRetryDelay(int failures) {
  if (failures <= 1) return const Duration(seconds: 2);
  if (failures == 2) return const Duration(seconds: 5);
  if (failures == 3) return const Duration(seconds: 15);
  return const Duration(seconds: 60);
}

/// 会话页轮询节流（真机发热复盘 #390/#393/#397）。
///
/// - **mux 正常**（有实时下行）：保持原节奏 —— 空闲 2s；
/// - **mux 不可用**（局域网 8080 转发层不做 WS 隧道，见 #392）：这条链路上
///   *没有任何实时流*，全量历史轮询只有在「输出确实在增长」时才值得跑：
///   增长中 800ms、回合在跑但没变化 4.8s、空闲 12s。
///   真机实测：按旧的 800ms 常速跑，后台 + 充电时电池 43.6°C，强停后 60 秒
///   降到 41.1°C。
({bool fetch, bool withList}) dshChatPollTick({
  required int ticks,
  required bool running,
  required bool muxUp,
  bool growing = false,
  bool unreachable = false,
}) {
  final withListTick = ticks % 5 == 0;
  if (muxUp) {
    // 有实时下行时轮询只是兜底：维持原来的 2s 一拍。
    return (fetch: withListTick, withList: withListTick);
  }
  var every = growing
      ? 2 // 800ms：正在出字
      : running
      ? 12 // 4.8s：回合在跑但历史没动
      : 30; // 12s：空闲
  // 目标不可达（Connection refused 等）：再放慢 5 倍 —— 打不通的请求
  // 纯属发热/耗电，真机实测「电脑 DSH 没开」时 40 秒打了 51 次（#401）。
  if (unreachable) every = every * 5;
  final due = ticks % every == 0;
  return (fetch: due, withList: due && withListTick);
}

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
  bool _historyRefreshPending = false;
  bool _sending = false;
  late bool _running = widget.initialSummary?.running ?? false;
  Timer? _pollTimer;
  Timer? _subagentPollTimer;
  bool _refreshingSubagents = false;
  List<DshSubagentEntry> _subagents = [];

  /// 主轮询最近一次 `session/list` 的结果（子代理派生直接复用，省 RPC）。
  List<DshSessionSummary> _sessionsSnapshot = const [];
  DateTime? _sessionsSnapshotAt;

  /// 目标不可达（Connection refused 等）：放慢轮询，别对着打不通的地址猛打。
  bool _pollUnreachable = false;

  static bool _isUnreachableError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('unreachable') ||
        text.contains('connection refused') ||
        text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('connection closed');
  }
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

  /// 后台任务（官方 `job/list`）：输入框上方芯片 + 面板可结束。
  List<DshJobInfo> _jobs = const [];

  /// 消息反馈（官方 `messageFeedback/list`）：messageId → positive/negative。
  Map<String, String> _feedback = const {};

  /// 目标机终端（官方 `terminal/*`）：本机模式专用。
  final ValueNotifier<String> _termOutput = ValueNotifier<String>('');
  final TextEditingController _termInput = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _termSub;
  String _termId = '';
  String? _termAttachmentId;

  static String _stripAnsi(String value) =>
      value.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');

  /// 打开目标机终端（`terminal/*`）。
  ///
  /// **只在本机模式给入口**：`terminal/follow` 是 stream，局域网 8080 转发层
  /// 不做 WS 隧道（#392）→ 局域网收不到任何输出。
  Future<void> _openTerminalPanel() async {
    final settings = widget.shiyi?.settings;
    if (settings == null || !DshEndpoint.isLocal(settings)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目标机终端只在「本机」模式可用（局域网收不到终端流）')),
      );
      return;
    }
    _termOutput.value = '正在连接目标机终端…';
    unawaited(_ensureTerminal());
    await showIosFadeSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                child: Row(
                  children: [
                    Text(
                      '目标机终端',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _termId.isEmpty ? '' : _termId,
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ValueListenableBuilder<String>(
                valueListenable: _termOutput,
                builder: (_, text, _) => Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 320),
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      text.isEmpty ? '（已连接，输入命令回车）' : text,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _termInput,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '输入命令后回车',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: _sendTerminalLine,
                      ),
                    ),
                    const SizedBox(width: 8),
                    CupertinoButton.filled(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      onPressed: () => _sendTerminalLine(_termInput.text),
                      child: const Text('发送'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 复用已有终端，没有就 create，然后订阅 `terminal/follow`。
  Future<void> _ensureTerminal() async {
    try {
      final existing = await _api.listTerminals(widget.sessionId);
      var id = '';
      for (final terminal in existing) {
        final shell = (terminal['shell'] as Map?)?.cast<String, dynamic>();
        if (shell?['state'] == 'running') {
          id = (terminal['id'] ?? '').toString();
          _termAttachmentId = terminal['attachmentId']?.toString();
          break;
        }
      }
      if (id.isEmpty) {
        final created = await _api.createTerminal(
          widget.sessionId,
          request: {if (_cwd.trim().isNotEmpty) 'cwd': _cwd.trim()},
        );
        id = (created['id'] ?? '').toString();
        _termAttachmentId = created['attachmentId']?.toString();
      }
      if (id.isEmpty) throw StateError('没有拿到终端 id');
      _termId = id;
      await _termSub?.cancel();
      _termSub = _api
          .watchTerminal(widget.sessionId, id, attachmentId: _termAttachmentId)
          .listen(
            (frame) {
              final type = frame['type']?.toString() ?? '';
              if (type == 'snapshot') {
                _termOutput.value = _stripAnsi(
                  (frame['screen'] ?? '').toString(),
                );
                final info = (frame['info'] as Map?)?.cast<String, dynamic>();
                final attachment = info?['attachmentId']?.toString();
                if ((attachment ?? '').isNotEmpty) {
                  _termAttachmentId = attachment;
                }
              } else if (type == 'output') {
                _termOutput.value =
                    '${_termOutput.value}${_stripAnsi((frame['data'] ?? '').toString())}';
              }
            },
            onError: (_) {},
            onDone: () {},
            cancelOnError: true,
          );
    } catch (e) {
      _termOutput.value = '终端启动失败：$e';
    }
  }

  void _sendTerminalLine(String line) {
    final data = line.trimRight();
    if (data.isEmpty || _termId.isEmpty) return;
    _termInput.clear();
    unawaited(
      _api.writeTerminal(
        widget.sessionId,
        _termId,
        '$data\n',
        attachmentId: _termAttachmentId,
      ),
    );
  }

  /// 从 App 侧消息 id 还原服务端 messageId。
  ///
  /// 历史解析把服务端 id 保留成 `dsh-<服务端id>`；服务端没给 id 时退化成
  /// `dsh-<seq>`（纯数字），那种不能拿去反馈。
  String? _dshMessageId(String id) {
    final raw = id.startsWith('dsh-') ? id.substring(4) : id;
    if (raw.isEmpty) return null;
    if (int.tryParse(raw) != null) return null;
    return raw;
  }

  Future<void> _refreshFeedback() async {
    try {
      final items = await _api.listMessageFeedback(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _feedback = {
          for (final item in items)
            if ((item['messageId'] ?? '').toString().isNotEmpty)
              item['messageId'].toString(): (item['rating'] ?? '').toString(),
        };
      });
    } catch (_) {
      // 旧版没有 messageFeedback/*：按钮只是不亮。
    }
  }

  Future<void> _sendFeedback(ChatMessage message, String rating) async {
    final messageId = _dshMessageId(message.id);
    if (messageId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条消息没有服务端 id，无法反馈')),
      );
      return;
    }
    // 再点一次同一个评分 = 取消（官方 list/delete 支持）。
    final next = _feedback[messageId] == rating ? null : rating;
    try {
      if (next == null) {
        await _api.deleteMessageFeedback(widget.sessionId, messageId);
      } else {
        await _api.putMessageFeedback(
          widget.sessionId,
          messageId,
          rating: next,
        );
      }
      if (!mounted) return;
      setState(() {
        final updated = Map<String, String>.of(_feedback);
        if (next == null) {
          updated.remove(messageId);
        } else {
          updated[messageId] = next;
        }
        _feedback = updated;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(next == null ? '已取消反馈' : '已记录反馈')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('反馈失败：$e')));
    }
  }
  final Map<String, ToolEvent> _timedToolEvents = {};
  StreamSubscription<Map<String, dynamic>>? _muxSub;
  StreamSubscription<Map<String, dynamic>>? _hostSub;
  StreamSubscription<Map<String, dynamic>>? _controlSub;
  Timer? _muxRetry;
  Timer? _cacheTimer;
  Timer? _historySettleTimer;
  int _historySettleAttempts = 0;
  int _historyReadGeneration = 0;
  Future<void> _cacheWriteTail = Future<void>.value();
  bool _muxUp = false;

  /// 连续失败的 mux 连接次数（成功收到 `session/subscribed` 归零），
  /// 用来做重连退避：局域网 8080 前面那层转发不能隧道 WebSocket，升级后
  /// 一直静默，每 2 秒无限重连等于持续烧手机（见 docs/fix-log.md #391）。
  int _muxFailures = 0;

  /// 首帧看门狗：升级成功但 8 秒内没拿到 `session/subscribed` 就当死连接。
  Timer? _muxWatchdog;
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
  DateTime? _lastAtTrigger;
  int _pollTicks = 0;

  /// 「历史还在增长」的衰减计数（0=没动静）。LAN 上没有 mux 时用它决定轮询
  /// 节奏：只有真的在出字才跑 800ms，否则退到 4.8s / 12s（发热复盘 #397）。
  int _growTicks = 0;
  int _lastGrowthSeq = -1;
  int _muxGen = 0;
  static const _liveId = 'dsh-live';
  static const _maxHistorySettleDelayStep = 8;

  /// 上翻加载的更早历史，渲染时始终排在 [_messages] 之前。
  ///
  /// 与 [_messages] 分开放：尾部窗口每拍都会被历史合并重写，混在一起会让
  /// 已翻出来的老消息被合并逻辑反复重排。
  List<ChatMessage> _olderMessages = const [];

  /// 还能不能继续向更早翻（官方 `session/page` 的 `hasMore`）。
  bool _hasMoreOlder = false;

  /// 正在补更早的一页。
  bool _loadingOlder = false;

  /// 尾页窗口的尾部游标（官方 `throughSeq`）：同一轮翻页必须沿用它，
  /// 否则每次都会用新游标重新定位窗口。
  int? _historyThroughSeq;

  /// 已加载消息里最老的事件 seq，上翻时作为 `beforeSeq`（开区间上界）。
  int? _oldestLoadedSeq;

  /// 用户上翻读历史时暂停尾部刷新：读历史时每拍重排列表既卡又把视线
  /// 拽回底部，回到最新位置后自动恢复。
  bool _tailRefreshPaused = false;

  DshApiClient get _api => DshService.instance.api;

  @override
  void initState() {
    super.initState();
    final settings = widget.shiyi?.settings;
    _selectedModelTargetDsh =
        _usesTargetDshApi ||
        (settings != null && DshEndpoint.modeOf(settings) == 'remote');
    WidgetsBinding.instance.addObserver(this);
    final rememberedSubagents =
        _dshSubagentMemory[_dshSubagentMemoryKey(widget.sessionId)];
    if (rememberedSubagents != null) {
      _subagents = List<DshSubagentEntry>.of(rememberedSubagents);
    }
    DshService.instance.status.addListener(_onDshStatus);
    _scroll.addListener(_onScroll);
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
    _scroll.removeListener(_onScroll);
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
    _muxWatchdog?.cancel();
    unawaited(_termSub?.cancel());
    _termOutput.dispose();
    _termInput.dispose();
    unawaited(_muxSub?.cancel());
    unawaited(_hostSub?.cancel());
    unawaited(_controlSub?.cancel());
    _streamText.dispose();
    _streamReasoning.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onDshStatus() {
    if (mounted) setState(() {});
    if (DshService.instance.status.value == DshStatus.running &&
        _historyRefreshPending) {
      _historyRefreshPending = false;
      unawaited(_refreshHistory(clearLive: false));
    }
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
    final source = _olderMessages.isEmpty
        ? _messages
        : <ChatMessage>[..._olderMessages, ..._messages];
    return source
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
      _applyHistoryWindow(bundle);
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
        // 缓存页首帧可以先展示，但 DSH 启动竞态期间的历史读取不能
        // 被静默丢掉；服务恢复 running 后由状态监听补读一次权威历史。
        if (!_usesLivePageData) _historyRefreshPending = true;
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
        // 诊断：模型目录到底给了几组/几个模型（局域网抽屉空的排查用，#403）。
        RuntimeLogger.instance.info(
          'DSH',
          'model.catalog',
          sessionId: widget.sessionId,
          data: {
            'groups': groups.length,
            'detail': [
              for (final group in groups.take(8))
                '${group.id}:${group.models.length}',
            ].join(','),
            'defaultProvider': current?.provider ?? '',
            'defaultModel': current?.model ?? '',
          },
        );
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
        // 目录没给分组（目标只回了 default）时别让抽屉空着：用 default 造一条。
        final currentSelection = current;
        if (_dshModelOptions.isEmpty &&
            currentSelection != null &&
            currentSelection.provider.trim().isNotEmpty &&
            currentSelection.model.trim().isNotEmpty) {
          final provider = currentSelection.provider.trim();
          final model = currentSelection.model.trim();
          _dshModelOptions = [
            SessionModelOption(
              value: provider,
              label: provider,
              subtitle: model,
              models: [model],
              targetDsh: true,
              targetProvider: provider,
            ),
          ];
        }
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

  /// 页面/应用是否可见（后台、被别的 route 盖住都算不可见）。
  bool get _pollVisible => dshPollVisible(
    mounted: mounted,
    lifecycle: WidgetsBinding.instance.lifecycleState,
    routeIsCurrent: ModalRoute.of(context)?.isCurrent ?? true,
  );

  /// 记录「历史是否在增长」：新 seq 前进或 live 可见内容在跑 = 在出字。
  /// LAN 没有 mux 时，只有这里为真才值得 800ms 轮询（发热复盘 #397）。
  void _noteHistoryGrowth(DshHistoryBundle bundle) {
    final seq = bundle.newestSeq ?? -1;
    final grew =
        seq > _lastGrowthSeq || (bundle.live.open && bundle.live.hasVisible);
    _lastGrowthSeq = seq;
    if (grew) {
      _growTicks = 3;
    } else if (_growTicks > 0) {
      _growTicks--;
    }
  }

  void _maybePoll() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      _pollTicks++;
      // 页面不在最前 / 应用在后台时一律不拉：真机上这是纯发热。
      if (!_pollVisible) return;
      final wantFast = _running && !_muxUp;
      final tick = dshChatPollTick(
        ticks: _pollTicks,
        running: _running,
        muxUp: _muxUp,
        growing: _growTicks > 0,
        unreachable: _pollUnreachable,
      );
      if (!tick.fetch) return;
      final withList = tick.withList;
      try {
        // mux 连上不代表每一条 reasoning-delta 都已经送达；旧版 2.0
        // 由 history/stream 双路共同喂给 streamReasoning。运行中的回合继续
        // 走 history 兜底，非活动状态才只刷新元数据。
        if (_muxUp && _live.open && !_awaitingFinalReply && !_running) {
          await _refreshMeta();
          return;
        }
        final readGeneration = ++_historyReadGeneration;
        if (wantFast) {
          final results = await Future.wait([
            _api.historyBundle(widget.sessionId),
            if (withList) _api.listSessions(),
          ]);
          if (!mounted || readGeneration != _historyReadGeneration) return;
          _pollUnreachable = false;
          final bundle = results[0] as DshHistoryBundle;
          _noteHistoryGrowth(bundle);
          final historyConfirmsLive = _historyConfirmsLive(bundle.messages);
          _rememberResponseModels(bundle);
          _applyHistoryWindow(bundle);
          _adoptHistoryReasoning(bundle.messages);
          if (withList) {
            _applySessionMeta(results[1] as List<DshSessionSummary>);
            // 后台任务清单在目标里是 stream 端点（`job/list`），只有 mux 通
            // 才有意义；局域网没有 WS 隧道，打了也必被拒（#403）。
            if (_muxUp) unawaited(_refreshJobs());
            unawaited(_refreshFeedback());
          }
          final finalizesTurn = _shouldFinalizeHistory(bundle);
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
              allowClose: _allowsLiveClose(bundle, historyConfirmsLive),
            );
          }
          _dropStrandedLiveIfIdle();
          if ((bundle.live.open || bundle.live.hasVisible) &&
              !_tailRefreshPaused) {
            _scrollToBottom();
          }
          return;
        }
        final results = await Future.wait([
          _api.historyBundle(widget.sessionId),
          if (withList) _api.listSessions(),
        ]);
        if (!mounted || readGeneration != _historyReadGeneration) return;
        _pollUnreachable = false;
        final bundle = results[0] as DshHistoryBundle;
        _noteHistoryGrowth(bundle);
        final historyConfirmsLive = _historyConfirmsLive(bundle.messages);
        _rememberResponseModels(bundle);
        _applyHistoryWindow(bundle);
        _adoptHistoryReasoning(bundle.messages);
        final prevLast = _messages.isEmpty ? null : _messages.last;
        final nextLast = bundle.messages.isEmpty ? null : bundle.messages.last;
        final changed =
            bundle.messages.length != _messages.length ||
            nextLast?.content != prevLast?.content;
        if (withList) {
          _applySessionMeta(results[1] as List<DshSessionSummary>);
        }
        final finalizesTurn = _shouldFinalizeHistory(bundle);
        // 用户正在上翻读历史（且没有回合在跑、也没到收口时机）：这拍不重排
        // 尾部列表、也不把视线拽回底部；回到最新位置后自动恢复。
        final pauseTail =
            _tailRefreshPaused && !_turnInFlight && !finalizesTurn;
        if (!pauseTail) {
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
              force: true,
              allowClose: _allowsLiveClose(bundle, historyConfirmsLive),
            );
          }
          _dropStrandedLiveIfIdle();
          if (changed) _scrollToBottom();
        }
        if (!_running && !changed && (!bundle.live.open || !_live.open)) {
          final last = _messages.isEmpty ? null : _messages.last;
          final done =
              last == null ||
              last.role == 'user' ||
              (last.role == 'assistant' && last.content.isNotEmpty);
          if (done) _stopPoll();
        }
      } catch (e) {
        // 不自动拉起服务：轮询失败等用户手动启动。
        // 目标打不通（Connection refused 之类）就进入"不可达"状态，
        // 轮询节奏再放慢 5 倍（见 dshChatPollTick 的 unreachable）。
        if (mounted) _pollUnreachable = _isUnreachableError(e);
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

  /// 把待发附件变成官方 content 块。
  ///
  /// - 图片：读成 base64 内联（rc.2 的 image 块不用先上传）；
  /// - 文件：`fileUploads/upload` 换 receiptId（file 块只带 receiptId）；
  /// - 失败的那些退回文本提示，至少让模型知道文件名。
  Future<
    ({
      List<DshImageAttachment> images,
      List<String> receipts,
      String fallback,
    })
  >
  _prepareOutgoingAttachments(
    List<String> imagePaths,
    List<String> filePaths,
  ) async {
    final images = <DshImageAttachment>[];
    final receipts = <String>[];
    final fallback = StringBuffer();
    for (final path in imagePaths) {
      try {
        final bytes = await File(path).readAsBytes();
        if (bytes.isEmpty) throw StateError('空图片');
        images.add(
          DshImageAttachment(
            mediaType: DshImageAttachment.mediaTypeForPath(path),
            base64: base64Encode(bytes),
            name: p.basename(path),
          ),
        );
      } catch (_) {
        fallback.writeln('【图片：${p.basename(path)}】');
      }
    }
    for (final path in filePaths) {
      try {
        final bytes = await File(path).readAsBytes();
        final receipt = await _api.uploadFile(
          widget.sessionId,
          base64: base64Encode(bytes),
          name: p.basename(path),
        );
        if (receipt.receiptId.isEmpty) throw StateError('没有 receiptId');
        receipts.add(receipt.receiptId);
      } catch (_) {
        fallback.writeln('【附件：${p.basename(path)}】');
      }
    }
    return (
      images: images,
      receipts: receipts,
      fallback: fallback.toString().trim(),
    );
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
    // 上线正文：只有文本 + 技能指令；附件走官方 content 块
    // （图片内联 base64、文件先上传换 receiptId），不再把本地路径当文本发出去。
    final wireText = StringBuffer();
    if (_selectedSkills.isNotEmpty) {
      for (final skill in _selectedSkills) {
        wireText.writeln('/${skill.name}');
      }
    }
    if (text.isNotEmpty) wireText.write(text);
    // 乐观消息仍显示本地预览（图片/文件名 + 路径），刷新后由服务端历史覆盖。
    final content = StringBuffer();
    for (final path in images) {
      content.writeln('![图片]($path)');
    }
    for (final path in files) {
      content.writeln('【附件：${p.basename(path)}】');
      content.writeln('路径：$path');
    }
    if (wireText.isNotEmpty) content.write(wireText.toString());
    final prompt = content.toString().trim();
    final wirePrompt = wireText.toString().trim();
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
    Future<void> sendPrompt() async {
      // 官方 content 块：图片内联、文件先上传换 receiptId；失败的退回文本提示，
      // 至少让模型知道有这个东西（见 docs/dsh-parity.md）。
      final prepared = await _prepareOutgoingAttachments(images, files);
      final outgoing = [
        if (wirePrompt.isNotEmpty) wirePrompt,
        if (prepared.fallback.isNotEmpty) prepared.fallback,
      ].join('\n');
      return DshService.instance.withRecover(
        () => _turnCommands.enqueue(
          () => _api.prompt(
            widget.sessionId,
            outgoing,
            images: prepared.images,
            fileReceiptIds: prepared.receipts,
          ),
        ),
        recover: true,
      );
    }
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
                unawaited(_browseWorkspaceFiles());
              },
              child: const Text('浏览工作区文件'),
            ),
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(_openTerminalPanel());
              },
              child: const Text('目标机终端（本机模式）'),
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
    if (isAtReferenceTrigger(_input.text)) {
      final now = DateTime.now();
      if (_lastAtTrigger != null &&
          now.difference(_lastAtTrigger!).inMilliseconds < 600) {
        return;
      }
      _lastAtTrigger = now;
      unawaited(_pickReferenceSheet());
      return;
    }
    if (!isSkillSlashTrigger(_input.text)) return;
    final now = DateTime.now();
    if (_lastSlashTrigger != null &&
        now.difference(_lastSlashTrigger!).inMilliseconds < 600) {
      return;
    }
    _lastSlashTrigger = now;
    unawaited(_pickSkillSheet());
  }

  /// 末尾 `@词` 触发引用选择（官方 @-引用：`fileReferences/list` +
  /// `sessionReferenceResolver/candidates`）。判定逻辑见 `core/at_trigger.dart`。
  Future<void> _pickReferenceSheet() async {
    final query = atReferenceQuery(_input.text) ?? '';
    final references = <String>[];
    final sessions = <Map<String, dynamic>>[];
    try {
      references.addAll(await _api.listFileReferences(widget.sessionId, query));
    } catch (_) {
      // 旧版没有 fileReferences/list。
    }
    try {
      sessions.addAll(
        await _api.sessionReferenceCandidates(widget.sessionId, query),
      );
    } catch (_) {
      // 旧版没有 sessionReferenceResolver/candidates。
    }
    if (!mounted) return;
    if (references.isEmpty && sessions.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有匹配的引用')));
      return;
    }
    final picked = await showIosFadeSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Row(
                children: [
                  Text(
                    '插入引用',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  if (query.isNotEmpty)
                    Text(
                      '@$query',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).hintColor,
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                children: [
                  for (final path in references)
                    ListTile(
                      dense: true,
                      leading: const Icon(CupertinoIcons.doc, size: 18),
                      title: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(ctx, path),
                    ),
                  for (final session in sessions)
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        CupertinoIcons.chat_bubble_2,
                        size: 18,
                      ),
                      title: Text(
                        (session['title'] ??
                                session['sessionId'] ??
                                session['id'] ??
                                '')
                            .toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        (session['sessionId'] ?? session['id'] ?? '')
                            .toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(
                        ctx,
                        (session['sessionId'] ?? session['id'] ?? '')
                            .toString(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final replaced = replaceAtReference(_input.text, picked);
    _input.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: replaced.length),
    );
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
      // 官方斜杠命令（`commands/list`）一起列出来：它们是动作，不是可多选的技能，
      // 所以单独一段、点一下即执行（带参数的只填 `/name ` 让用户补完）。
      var commands = const <DshCommandInfo>[];
      try {
        commands = await _api.listCommands(widget.sessionId);
      } catch (_) {
        // 旧版没有 commands/list：只显示技能。
      }
      if (!mounted) return;
      // 定时任务（官方 `schedule/list`，unary，局域网也通）。
      var schedules = const <Map<String, dynamic>>[];
      try {
        schedules = await _api.listSchedules(widget.sessionId);
      } catch (_) {
        // 旧版没有 schedule/* ：这一段不显示。
      }
      if (!mounted) return;
      if (skills.isEmpty && commands.isEmpty && schedules.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前会话没有可用技能或命令')));
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
                  if (commands.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 10, 18, 2),
                      child: Row(
                        children: [
                          Text(
                            '官方命令',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final command in commands)
                      ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(
                          CupertinoIcons.command,
                          size: 18,
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                        title: Text('/${command.name}'),
                        subtitle:
                            (command.description.isEmpty &&
                                command.hint.isEmpty)
                            ? null
                            : Text(
                                command.hint.isEmpty
                                    ? command.description
                                    : '${command.description}'
                                          '${command.description.isEmpty ? '' : ' · '}'
                                          '${command.hint}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: const Icon(
                          CupertinoIcons.chevron_right,
                          size: 16,
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          if (command.needsArgs) {
                            _input.text = '/${command.name} ';
                            _input.selection = TextSelection.collapsed(
                              offset: _input.text.length,
                            );
                            _stripSlash();
                            return;
                          }
                          unawaited(
                            _runOfficialCommand('/${command.name}'),
                          );
                        },
                      ),
                    const Divider(height: 8),
                  ],
                  if (schedules.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 10, 18, 2),
                      child: Text(
                        '定时任务',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final schedule in schedules)
                      ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(
                          CupertinoIcons.time,
                          size: 18,
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                        title: Text(
                          (schedule['title'] ??
                                  schedule['name'] ??
                                  schedule['id'] ??
                                  '')
                              .toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if ((schedule['cron'] ?? '').toString().isNotEmpty)
                              schedule['cron'].toString(),
                            if ((schedule['nextRunAt'] ??
                                    schedule['next'] ??
                                    '')
                                .toString()
                                .isNotEmpty)
                              '下次 ${schedule['nextRunAt'] ?? schedule['next']}',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(CupertinoIcons.trash, size: 18),
                          onPressed: () async {
                            final id =
                                (schedule['id'] ?? schedule['scheduleId'] ?? '')
                                    .toString();
                            Navigator.pop(ctx);
                            if (id.isEmpty) return;
                            try {
                              await _api.deleteSchedule(widget.sessionId, id);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已删除定时任务')),
                              );
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('删除失败：$e')),
                              );
                            }
                          },
                        ),
                      ),
                    const Divider(height: 8),
                  ],
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

  /// 刷新后台任务清单（`job/list`，纯 HTTP，局域网也通）。
  Future<void> _refreshJobs() async {
    try {
      final jobs = await _api.listJobs(widget.sessionId);
      if (!mounted) return;
      setState(() => _jobs = jobs);
    } catch (_) {
      // 旧版 / 服务未挂时静默：芯片本来就不显示。
    }
  }

  /// 后台任务面板：列出任务，运行中的可以结束。
  Future<void> _openJobsSheet() async {
    await _refreshJobs();
    if (!mounted) return;
    if (_jobs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前会话没有后台任务')));
      return;
    }
    await showIosFadeSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Row(
                children: [
                  Text(
                    '后台任务',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_jobs.where((j) => j.running).length} 个运行中',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).hintColor,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                children: [
                  for (final job in _jobs)
                    ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      leading: Icon(
                        job.running
                            ? CupertinoIcons.hammer
                            : CupertinoIcons.checkmark_circle,
                        size: 18,
                        color: job.running
                            ? Theme.of(ctx).colorScheme.primary
                            : Theme.of(ctx).hintColor,
                      ),
                      title: Text(
                        job.label.isEmpty ? job.id : job.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (job.kind.isNotEmpty) job.kind,
                          if (job.status.isNotEmpty) job.status,
                          if ((job.progress ?? '').isNotEmpty) job.progress!,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: job.running
                          ? TextButton(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                try {
                                  await _api.killJob(
                                    widget.sessionId,
                                    job.id,
                                  );
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('已请求结束 ${job.label}')),
                                  );
                                  await _refreshJobs();
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('结束失败：$e')),
                                  );
                                }
                              },
                              child: const Text('结束'),
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 工作区文件浏览 + 预览（官方 `workspaceFiles/*`，scopeId = 会话 id）。
  ///
  /// 这是官方侧边栏那条链路：只看会话工作区内的文件，能读文本、能看图片；
  /// 目录选择器（`directoryPicker/*`）仍留给「换工作目录」。
  Future<void> _browseWorkspaceFiles({String path = ''}) async {
    try {
      final listing = await _api.listWorkspaceFiles(widget.sessionId, path);
      if (!mounted) return;
      await showIosFadeSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        listing.path.isEmpty
                            ? '工作区文件'
                            : '工作区文件 / ${listing.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (listing.truncated)
                      Text(
                        '已截断',
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          color: Theme.of(ctx).hintColor,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                  children: [
                    if (listing.entries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('这个目录是空的'),
                      ),
                    for (final entry in listing.entries)
                      ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(
                          entry.isDir
                              ? CupertinoIcons.folder
                              : CupertinoIcons.doc_text,
                          size: 18,
                          color: entry.isDir
                              ? Theme.of(ctx).colorScheme.primary
                              : Theme.of(ctx).hintColor,
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: entry.size == null
                            ? null
                            : Text('${entry.size} B'),
                        trailing: entry.isDir
                            ? const Icon(CupertinoIcons.chevron_right, size: 16)
                            : null,
                        onTap: () {
                          final child = listing.path.isEmpty
                              ? entry.name
                              : '${listing.path}/${entry.name}';
                          Navigator.pop(ctx);
                          unawaited(
                            entry.isDir
                                ? _browseWorkspaceFiles(path: child)
                                : _previewWorkspaceFile(child),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开工作区文件失败：$e')));
    }
  }

  /// 预览工作区文件：图片走 `readBytes`，其余按文本读（读不动就报错）。
  Future<void> _previewWorkspaceFile(String path) async {
    final lower = path.toLowerCase();
    final isImage =
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
    try {
      if (isImage) {
        final bytes = await _api.readWorkspaceFileBytes(widget.sessionId, path);
        if (!mounted) return;
        if (bytes.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('图片内容为空')));
          return;
        }
        await showIosFadeSheet<void>(
          context: context,
          builder: (ctx) => SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                ],
              ),
            ),
          ),
        );
        return;
      }
      final file = await _api.readWorkspaceFile(widget.sessionId, path);
      if (!mounted) return;
      await showIosFadeSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${file.lines} 行${file.eof ? '' : '（未完）'}',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    file.text.isEmpty ? '（空文件）' : file.text,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('预览失败：$e')));
    }
  }

  /// 执行一条官方斜杠命令（不带参数的，如 `/compact`）。
  Future<void> _runOfficialCommand(String line) async {
    try {
      await _api.executeCommand(sessionId: widget.sessionId, line: line);
      if (!mounted) return;
      _stripSlash();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已执行 $line')));
      _maybePoll();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('命令执行失败：$e')));
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
    _muxWatchdog?.cancel();
    await _muxSub?.cancel();
    await _hostSub?.cancel();
    await _controlSub?.cancel();
    _muxSub = null;
    _hostSub = null;
    _controlSub = null;
    // 局域网 8080 转发层会让 WebSocket「升级成功但永不下发」：没有这个
    // 看门狗，应用会一直攥着一个死连接（既不重连也不释放），
    // `_onMuxLost` 永远不触发。只盯首帧，连上后不再打扰。
    _muxWatchdog = Timer(const Duration(seconds: 8), () {
      if (mounted && gen == _muxGen && !_muxUp) _onMuxLost();
    });
    try {
      _muxSub = _api
          .watchMux(sessionId: widget.sessionId)
          .listen(
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
      _controlSub = _api
          .watchSessionControl(sessionId: widget.sessionId)
          .listen(
            (frame) {
              if (gen == _muxGen) _onControlFrame(frame);
            },
            onError: (_) {},
            cancelOnError: true,
          );
    } catch (_) {
      if (gen == _muxGen) _onMuxLost();
    }
  }

  void _onControlFrame(Map<String, dynamic> frame) {
    final type = frame['type']?.toString() ?? '';
    if (type == 'baseline') {
      // rc.2 的 `session/control` 首帧是
      // `{type:'baseline', value:{projections:{<id>:{asOfSeq,values:{…}}}}}`，
      // 原来的解析只认 `projection` 帧，baseline 被整帧丢掉 → 会话开头拿不到
      // inbox/permissions 这类投影（见 docs/fix-log.md #396）。
      final value = frame['value'];
      final projections = value is Map ? value['projections'] : null;
      if (projections is Map) {
        for (final entry in projections.values) {
          final values = entry is Map ? entry['values'] : null;
          if (values is Map) _applyControlProjectionValues(values);
        }
      }
      return;
    }
    if (type == 'projection') {
      final key = frame['key']?.toString() ?? '';
      final value = frame['value'];
      if ((key == 'running' || key == 'isRunning') && value is bool) {
        _applyControlRunning(value);
      }
      return;
    }
    if (type == 'queue') {
      final items = frame['items'];
      if (items is List && items.isNotEmpty) _applyControlRunning(true);
      return;
    }
    if (type == 'jobs') {
      final jobs = frame['jobs'];
      if (jobs is List && jobs.isNotEmpty) _applyControlRunning(true);
    }
  }

  /// 官方投影 values 里能推出「有活在跑」的信号：
  /// `inbox.next-turn` / `inbox.next-step` 非空 = 有排队或正在推进的回合。
  void _applyControlProjectionValues(Map<dynamic, dynamic> values) {
    final inbox = values['inbox'];
    if (inbox is! Map) return;
    final nextTurn = inbox['next-turn'];
    final nextStep = inbox['next-step'];
    final hasWork =
        (nextTurn is List && nextTurn.isNotEmpty) ||
        (nextStep is List && nextStep.isNotEmpty);
    if (hasWork) _applyControlRunning(true);
  }

  void _applyControlRunning(bool running) {
    if (!mounted || running == _running) return;
    setState(() => _running = running);
    if (running) {
      _syncSubagentPolling();
      _maybePoll();
    }
  }

  void _onMuxLost() {
    if (!mounted) return;
    _muxUp = false;
    _muxFailures++;
    _muxWatchdog?.cancel();
    _muxRetry?.cancel();
    _muxRetry = Timer(dshMuxRetryDelay(_muxFailures), () {
      if (mounted && _muxGen != 0) unawaited(_connectDownlink());
    });
  }

  void _onDownlinkFrame(Map<String, dynamic> frame) {
    final type = frame['type']?.toString() ?? '';
    final sid = frame['sessionId']?.toString() ?? '';
    if (sid.isNotEmpty && sid != widget.sessionId) return;

    if (type == 'session/subscribed') {
      _muxUp = true;
      _muxFailures = 0;
      _muxWatchdog?.cancel();
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
    if (type == 'session/assistant-stream-end') {
      if (frame['outcome'] == 'abandoned') {
        _turnEndSeen = true;
        _finishOpenToolEvents(ok: false);
        if (mounted) setState(() => _running = false);
        _syncSubagentPolling();
        unawaited(_refreshHistory(clearLive: true));
      }
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
          // rc.2 的 `userQuestions/answer(agentId, callId, answer)` 要 callId，
          // 帧里优先用它自己的 id，没有就退回 rpcId（见 docs/fix-log.md #398）。
          'callId':
              frame['callId']?.toString() ??
              frame['id']?.toString() ??
              rpcId,
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
      // rc.2 可能先发 assistant/message，再把 turn/end 和正式历史落盘。
      // 进入收口重试，避免正文已经显示但思考层永远留着。
      unawaited(_refreshHistory(clearLive: _awaitingFinalReply));
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
    final readGeneration = ++_historyReadGeneration;
    try {
      final bundle = await _api.historyBundle(widget.sessionId);
      if (!mounted || readGeneration != _historyReadGeneration) return;
      _historyRefreshPending = false;
      if (bundle.permissionPreset != null &&
          bundle.permissionPreset != _sessionPermission) {
        setState(() => _sessionPermission = bundle.permissionPreset!);
      }
      _rememberResponseModels(bundle);
      _applyHistoryWindow(bundle);
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
      final finalizesTurn = _shouldFinalizeHistory(bundle);
      final preserveLocalProgress =
          !authoritative &&
          !finalizesTurn &&
          (_shouldPreserveLocalProgress(bundle) || !historyConfirmsLive);
      final nextMessages = _mergeHistory(
        bundle.messages,
        live: bundle.live,
        preserveLocalProgress: preserveLocalProgress,
      );
      _replaceMessages(nextMessages);
      if (finalizesTurn) {
        _finishPendingTurn();
      } else {
        _adoptLive(
          bundle.live,
          force: true,
          allowClose: _allowsLiveClose(bundle, historyConfirmsLive),
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
      _dropStrandedLiveIfIdle();
      _scheduleCacheWrite();
      // 读历史时不要把视线拽回底部。
      if (!_tailRefreshPaused) _scrollToBottom();
    } catch (e) {
      // 不自动拉起服务：刷新失败等用户手动启动。手动压缩需要把失败
      // 交给调用方，避免在权威历史尚未重载时误报成功。
      if (!throwOnError && !_usesLivePageData) {
        _historyRefreshPending = true;
        if (DshService.instance.status.value == DshStatus.running) {
          _historyRefreshPending = false;
          Future<void>.delayed(const Duration(milliseconds: 500), () {
            if (mounted) unawaited(_refreshHistory(clearLive: false));
          });
        }
      }
      if (throwOnError) rethrow;
    }
  }

  /// 记录尾页窗口的分页元数据（每次读到尾部历史后调用）。
  ///
  /// `newestSeq` 只在增长时更新，保证同一轮上翻沿用一个固定的尾部游标。
  void _applyHistoryWindow(DshHistoryBundle bundle) {
    _hasMoreOlder = bundle.hasMoreOlder;
    final newest = bundle.newestSeq;
    if (newest != null &&
        (_historyThroughSeq == null || newest > _historyThroughSeq!)) {
      _historyThroughSeq = newest;
    }
    final oldest = bundle.oldestSeq;
    if (oldest != null &&
        (_oldestLoadedSeq == null || oldest < _oldestLoadedSeq!)) {
      _oldestLoadedSeq = oldest;
    }
  }

  /// 长会话滚动：接近最老一段时补一页更早的消息；离开最新位置时暂停
  /// 尾部刷新，避免读历史时每拍重排列表。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final paused = dshShouldPauseTailRefresh(pixels: position.pixels);
    if (paused != _tailRefreshPaused) {
      setState(() => _tailRefreshPaused = paused);
    }
    if (dshShouldLoadOlder(
      hasMoreOlder: _hasMoreOlder,
      loading: _loadingOlder,
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
    )) {
      unawaited(_loadOlder());
    }
  }

  /// 取比当前已加载的最老一条更早的一页（官方 beforeSeq 是开区间上界）。
  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    final before = _oldestLoadedSeq;
    if (before == null) return;
    setState(() => _loadingOlder = true);
    try {
      final bundle = await _api.historyOlder(
        widget.sessionId,
        beforeSeq: before,
        throughSeq: _historyThroughSeq,
      );
      if (!mounted) return;
      setState(() {
        _olderMessages = dshPrependOlderMessages(
          older: bundle.messages,
          current: _olderMessages,
        );
        _hasMoreOlder = bundle.hasMoreOlder;
        _oldestLoadedSeq = bundle.oldestSeq ?? before;
        _loadingOlder = false;
      });
    } catch (_) {
      // 失败不弹错：回到最新位置会重新触发；留着哨兵行等用户再上翻。
      if (!mounted) return;
      setState(() => _loadingOlder = false);
    }
  }

  Widget _olderLoader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: _loadingOlder
            ? const AppLoading()
            : Text(
                '上翻加载更早的消息',
                style: TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
      ),
    );
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
    // 子代理要从 `session/list` 派生（官方没有 subagents/list，见 #396）。
    // 这里把刚拿到的那份存下来，子代理轮询就不必每 2 秒再打一次 session.list
    // —— 之前 500ms × session.list 是发热源之一（#399 之后实测 48 次/31 秒）。
    _sessionsSnapshot = list;
    _sessionsSnapshotAt = DateTime.now();
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
      // 主轮询刚拉过 session/list 就直接派生，省掉一次 RPC（发热敏感）。
      final snapshot = _sessionsSnapshot;
      final at = _sessionsSnapshotAt;
      final fresh =
          snapshot.isNotEmpty &&
          at != null &&
          DateTime.now().difference(at) < const Duration(seconds: 6);
      final result = fresh
          ? DshApiClient.deriveSubagents(
              parentSessionId: widget.sessionId,
              sessions: snapshot,
            )
          : await _api.listSubagents(widget.sessionId);
      if (!mounted || refreshGeneration != _subagentRefreshGeneration) return;
      _rememberDshSubagents(
        _dshSubagentMemoryKey(widget.sessionId),
        result.entries,
      );
      setState(() {
        _subagents = result.entries.isEmpty ? _subagents : result.entries;
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
      _subagentPollTimer ??= Timer.periodic(
        const Duration(milliseconds: 2000),
        (timer) {
          // 后台不拉！真机复盘（docs/fix-log.md #393）：这条定时器原先没有可见性
          // 判断，应用退到桌面后仍 2Hz 拉列表，边充电边跑 → 电池 56.7°C。
          // 2026-10-12 又降到 0.5Hz：那时每次都是一发 `session.list`
          // （子代理要从 session/list 派生，#396），实测 48 次/31 秒；
          // 现在改为优先复用主轮询那份结果，RPC 基本归零（#401）。
          if (!_pollVisible) return;
          // 目标打不通时别跟着一起打（子代理列表也要走会话列表）。
          if (_pollUnreachable) return;
          unawaited(_refreshSubagents());
        },
      );
      return;
    }
    _subagentPollTimer?.cancel();
    _subagentPollTimer = null;
  }

  void _finalizeSubagentStatus() {
    _subagentRefreshGeneration++;
    _syncSubagentPolling();
    if (mounted) setState(() {});
  }

  /// 让旧回合的子代理投影和异步刷新结果彻底失效。
  void _resetSubagentStatusForNewTurn() {
    _subagentRefreshGeneration++;
    _forgetDshSubagents(_dshSubagentMemoryKey(widget.sessionId));
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
    return _historyHasAssistantAfterPending(bundle.messages);
  }

  bool _historyHasAssistantAfterPending(List<ChatMessage> messages) {
    if (!_awaitingFinalReply) return false;
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
    if (userIndex < 0) return false;
    for (var i = userIndex + 1; i < messages.length; i++) {
      final message = messages[i];
      if (message.role == 'assistant' &&
          (message.content.trim().isNotEmpty ||
              message.reasoning.trim().isNotEmpty ||
              message.toolCalls.isNotEmpty)) {
        return true;
      }
    }
    return false;
  }

  bool _shouldFinalizeHistory(DshHistoryBundle bundle) {
    if (_historyFinalizesPendingTurn(bundle)) return true;
    // 某些 rc.2 回合不会把 turn/end 转发给手机客户端，但 session.list
    // 已经报告 stopped，且正式 assistant/message 已经落盘。此时不能再
    // 继续保留本地 thinking 占位。
    return _awaitingFinalReply &&
        !_running &&
        !bundle.live.open &&
        _historyHasAssistantAfterPending(bundle.messages);
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

  /// 是否仍有一轮在跑（DSH 报 running 或本地还在等正式助手消息）。
  bool get _turnInFlight => _running || _awaitingFinalReply;

  /// 是否允许关掉 live 缓冲。
  ///
  /// `bundle.live` 是从会话事件流**重建**的，本身不代表会话在跑：同一段未收口
  /// 缓冲既会冻成正式助手消息（`dsh_api.dart` 的 `freezePendingLive`），也会被
  /// `DshLiveTurn.fromHistoryValue` 还原成 `open` 的 live。若在会话已经 stopped
  /// 时还让这份重建缓冲压住收口，正式消息与重建的流式气泡会同时渲染，出现
  /// “生成完成多一条重复信息”；`_maybePoll` 的停止条件又要求 `!bundle.live.open`，
  /// 于是轮询也停不下来。所以只有仍在跑时才看 `bundle.live.open`。
  bool _allowsLiveClose(DshHistoryBundle bundle, bool historyConfirmsLive) {
    return dshAllowsLiveClose(
      turnInFlight: _turnInFlight,
      incomingLiveOpen: bundle.live.open,
      historyConfirmsLive: historyConfirmsLive,
    );
  }

  /// 回合已经不在跑时，任何残留的流式气泡都必须清掉。
  ///
  /// 迟到 chunk、历史重建的 live、`_adoptHistoryReasoning` 事后补思考都能重新
  /// 点亮 live 气泡，而收口路径只认 `_awaitingFinalReply` / `wasRunning`，
  /// 覆盖不到这些“事后点亮”。幂等（`_live.reset()` 后 `_live.hasVisible` 为
  /// false，`_clearLiveUi` 也不会再点亮 live），所以可以每拍执行。
  void _dropStrandedLiveIfIdle() {
    if (_turnInFlight || !mounted) return;
    if (!_live.open &&
        !_live.hasVisible &&
        !_messages.any((m) => m.streaming)) {
      return;
    }
    _clearLiveUi(preserveVisible: _live.hasVisible);
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
        callId: q['callId']?.toString(),
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

  String _messageListItemKey(Object item) {
    if (item is ChatMessage) return _itemKey(item);
    if (item is _DshThinkingPlaceholder) return 'dsh-thinking-placeholder';
    if (item is _DshOlderLoader) return 'dsh-older-loader';
    return 'unknown:${identityHashCode(item)}';
  }

  Widget _buildMessageListItem(BuildContext context, Object item) {
    if (item is _DshThinkingPlaceholder) return _thinkingPlaceholder();
    if (item is _DshOlderLoader) return _olderLoader();
    final m = item as ChatMessage;
    return KeyedSubtree(
      key: ValueKey(_itemKey(m)),
      child: RepaintBoundary(
        child: ValueListenableBuilder<String>(
          valueListenable: _streamReasoning,
          builder: (context, reasoning, _) => ValueListenableBuilder<String>(
            valueListenable: _streamText,
            builder: (context, text, _) => MessageBubble(
              message: m,
              liveContent: m.streaming && text.isNotEmpty ? text : null,
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
              // 官方消息反馈（messageFeedback/*）。
              feedbackRating: _dshMessageId(m.id) == null
                  ? null
                  : _feedback[_dshMessageId(m.id)],
              onFeedbackUp: m.role == 'assistant'
                  ? (msg) => unawaited(_sendFeedback(msg, 'positive'))
                  : null,
              onFeedbackDown: m.role == 'assistant'
                  ? (msg) => unawaited(_sendFeedback(msg, 'negative'))
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _composerFloatChips() {
    final showSubagent = _subagentTotalCount > 0 || _subagentPeekOpen;
    final showStats = DshStatsBar.hasContent(_summary);
    final runningJobs = _jobs.where((j) => j.running).length;
    if (!showSubagent && !showStats && runningJobs == 0) {
      return const SizedBox.shrink();
    }
    final chips = ChatComposerFloatChips(
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
    if (runningJobs == 0) return chips;
    // 官方后台任务：有任务在跑时挂一个芯片，点开可结束。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 12, bottom: 6),
          child: ChatComposerChip(
            tooltip: '后台任务',
            onTap: () => unawaited(_openJobsSheet()),
            children: [
              const Icon(CupertinoIcons.hammer, size: 14),
              const SizedBox(width: 5),
              Text('任务 $runningJobs'),
            ],
          ),
        ),
        chips,
      ],
    );
  }

  Widget _buildMessages(double overlayHeight) {
    if (_loading) {
      return AppLoading.centered();
    }
    if (_waitingService) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppLoading(),
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
              GlassActionButton(label: '重试', onPressed: _load, accent: true),
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
    final visibleItems = visible.reversed.toList();
    final hasStreaming = visibleItems.any((m) => m.streaming);
    // 会话仍活跃（整轮未完 / 子代理在跑）但没有真实流式气泡时，
    // 在底部补一条“思考中”占位，保证指示常驻；有真实流就不画，避免重复。
    final thinkingNeeded = _isThinkingActive && !hasStreaming;
    final items = <Object>[
      if (thinkingNeeded) const _DshThinkingPlaceholder(),
      ...visibleItems,
      // reverse 列表：追加在最后 = 渲染在最上面（最老的一端）。
      if (_hasMoreOlder || _loadingOlder) const _DshOlderLoader(),
    ];
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
      child: AnimatedMessageList(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(
          messageListSidePadding,
          12,
          messageListSidePadding,
          overlayHeight + 12,
        ),
        items: items,
        keyOf: _messageListItemKey,
        itemBuilder: _buildMessageListItem,
      ),
    );
  }
}

class _DshThinkingPlaceholder {
  const _DshThinkingPlaceholder();
}

/// reverse 列表里“更早的消息”哨兵行：渲染在最老的一端，可见即触发上翻。
class _DshOlderLoader {
  const _DshOlderLoader();
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
