import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../services/db.dart';
import '../services/llm_client.dart';
import '../services/file_workspace.dart';
import '../services/settings_service.dart';
import '../services/subagent.dart';
import '../services/termux_runtime.dart';
import '../services/web_tools.dart';
import '../services/notifier.dart';

/// 单个可执行工具：LLM 可见的 JSON schema + 执行函数 + 只读标记。
/// readOnly=true 的工具在计划模式（planMode）下仍然可用；
/// 新增工具 = 在 [_ShiyiTools.buildRegistry] 里加一个 AgentTool 条目 + 对应执行方法。
class AgentTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final bool readOnly;

  /// 执行函数：self 为 ShiyiState 实例（可访问其内部能力），args 为解析后的参数。
  final Future<String> Function(ShiyiState self, Map<String, dynamic> args)
  execute;

  AgentTool({
    required this.name,
    required this.description,
    required this.parameters,
    this.readOnly = false,
    required this.execute,
  });

  /// 转成 OpenAI 兼容的 function 定义（发给 LLM）。
  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// 历史中一个工具回合的索引范围（assistant tool_calls + 对应 tool 结果）。
class _ToolSegment {
  final int assistantIndex;
  final List<int> toolIndices;
  final bool complete;

  const _ToolSegment({
    required this.assistantIndex,
    required this.toolIndices,
    required this.complete,
  });
}

class ShiyiState extends ChangeNotifier {
  final AppDatabase _db = AppDatabase.instance;
  final SettingsService _settingsService = SettingsService();

  AppSettings settings = AppSettings();
  List<Session> sessions = [];
  List<ChatMessage> messages = [];
  String? _messagesLoadedForSessionId;
  List<MemoryEntry> memories = [];
  List<Skill> skills = [];
  String? currentSessionId;
  bool isBusy = false;
  String? status;

  /// 一次性的历史裁剪提示（4 秒后自动消失，不表示当前仍接近上限）。
  String? trimNotice;
  Timer? _trimNoticeTimer;

  /// 正在生成回复的会话 id（主页显示思考状态）。
  String? busySessionId;

  /// 已完成但用户尚未查看的会话（主页显示未读）。
  final Set<String> unreadSessions = {};

  /// 用户当前正在查看的会话 id（聊天页打开时设置）。
  String? viewingSessionId;

  /// 当前会话的工具调用历史（按会话持久化，跨对话连续）。
  List<ToolEvent> toolEvents = [];

  /// 本次会话累计消耗的 token（持久化到 sessions.total_tokens）。
  int sessionTotalTokens = 0;

  /// 当前这一轮对话（一次 send）消耗的 token。
  int lastRoundTokens = 0;

  /// 本轮按 Token 加权累计的真实缓存输入与总输入（来自 API usage）。
  int roundCachedTokens = 0;
  int roundInputTokens = 0;
  bool roundCacheKnown = false;

  /// 当前会话上下文估算 token 数（与 contextLimit 同口径，用于显示剩余百分比）。
  int sessionContextTokens = 0;

  /// 当前会话全量历史上下文估算（用于压缩判断，不受发送前裁剪影响）。
  int sessionContextTokensFull = 0;

  /// 正在流式输出的消息文本（独立通知器：流式刷新只重建这一条气泡，不重建整个列表）。
  final ValueNotifier<String> streamText = ValueNotifier('');
  final ValueNotifier<String> streamReasoning = ValueNotifier('');

  /// 初始化状态独立通知器：主界面只在初始化完成/失败时重建外层。
  final ValueNotifier<bool> loadedNotifier = ValueNotifier(false);
  final ValueNotifier<String?> initErrorNotifier = ValueNotifier<String?>(null);
  bool get loaded => loadedNotifier.value;
  String? get initError => initErrorNotifier.value;

  /// 消息列表版本号：聊天列表只监听它，避免 status/token 等变化重建整列。
  final ValueNotifier<int> messagesRevision = ValueNotifier(0);

  void _bumpMessages() => messagesRevision.value++;

  ChatMessage? _streaming;
  bool _stopRequested = false;
  bool _stopForGuide = false;
  bool _guideWaiting = false;
  DateTime? _lastRefine;
  int _refineCount = 0;
  bool _knownImageUnsupported = false;

  /// 模型发起的待用户确认问题：{question, options}；UI 弹窗后用户选择。
  Map<String, dynamic>? pendingQuestion;
  Completer<String>? _questionCompleter;

  /// 计划模式：模型只输出方案、不执行有副作用的操作（写文件/终端/记忆等被裁剪），
  /// 直到调用 exit_plan_mode 或用户确认方案后退出。
  bool planMode = false;

  /// 用户回答 question 工具；optionIndex 为空表示取消；custom 非空时优先作为自定义回答。
  void answerQuestion(int? optionIndex, {String? custom}) {
    final c = _questionCompleter;
    final q = pendingQuestion;
    if (c == null || q == null) return;
    final options = (q['options'] as List?) ?? const [];
    final customText = custom?.trim() ?? '';
    final answer = customText.isNotEmpty
        ? customText
        : (optionIndex != null &&
              optionIndex >= 0 &&
              optionIndex < options.length)
        ? options[optionIndex].toString()
        : '用户取消了选择';
    pendingQuestion = null;
    _questionCompleter = null;
    if (!c.isCompleted) c.complete(answer);
    notifyListeners();
  }

  /// 图片路径 -> 视觉模型描述缓存（避免同一图片每轮重复调用）。
  final Map<String, String> _imageDescCache = {};

  /// 工具注册表：所有工具的定义与执行在此集中登记。
  /// 新增工具 = 在 [_buildToolRegistry] 加一个 AgentTool 条目 + 一个 _execXxx 方法，
  /// 无需再改 switch 分发。
  static final List<AgentTool> toolRegistry = _buildToolRegistry();

  /// 当前应暴露给 LLM 的工具 JSON 列表：
  /// - 全局关闭工具（enableTools=false）时为空；
  /// - 计划模式（planMode）下只保留只读工具 + question + 计划模式切换工具，
  ///   避免模型在执行方案前产生副作用。
  List<Map<String, dynamic>> get activeTools {
    if (!settings.enableTools) return const [];
    const planAlways = {'question', 'enter_plan_mode', 'exit_plan_mode'};
    return [
      for (final t in toolRegistry)
        if (!planMode || t.readOnly || planAlways.contains(t.name)) t.toJson(),
    ];
  }

  static List<AgentTool> _buildToolRegistry() => [
    AgentTool(
      name: 'save_memory',
      description:
          '把重要的用户偏好、事实或经验保存为长期记忆，供以后所有会话回忆。'
          '可用 type 归类（user 用户身份/偏好，feedback 对我工作方式的指导，'
          'project 项目相关信息，reference 外部资源链接）；'
          '内容里可用 [[记忆名]] 双链引用相关记忆，便于跨记忆关联。',
      parameters: {
        'type': 'object',
        'properties': {
          'content': {
            'type': 'string',
            'description': '要保存的记忆内容，可含 [[其他记忆名]] 双链',
          },
          'type': {
            'type': 'string',
            'enum': ['user', 'feedback', 'project', 'reference'],
            'description': '记忆类型，默认 user',
          },
        },
        'required': ['content'],
      },
      execute: (self, args) => self._execSaveMemory(args),
    ),
    AgentTool(
      name: 'search_memory',
      description:
          '检索用户的历史偏好、事实与经验。注意：只能查到本机已保存的记忆，无法获取任何外部或最新信息；需要最新信息请直接用 web_search。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '搜索关键词'},
          'type': {
            'type': 'string',
            'enum': ['user', 'feedback', 'project', 'reference'],
            'description': '只搜该类型的记忆，缺省搜全部',
          },
        },
        'required': ['query'],
      },
      readOnly: true,
      execute: (self, args) => self._execSearchMemory(args),
    ),
    AgentTool(
      name: 'run_skill',
      description: '获取一个已保存技能的内容，例如脚本、Prompt 模板或操作流程，用于复用经验。',
      parameters: {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '技能名称'},
        },
        'required': ['name'],
      },
      readOnly: true,
      execute: (self, args) => self._execRunSkill(args),
    ),
    AgentTool(
      name: 'web_search',
      description:
          '联网搜索获取实时、最新或超出知识截止日期的问题（新闻、价格、天气、技术动态等）。注意核对每条结果的发布日期，优先近期内容，避免用过时信息。需要外部信息时首选本工具，不要先调用 search_memory。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '搜索关键词，尽量具体'},
          'max_results': {
            'type': 'integer',
            'description': '返回结果数量，默认 5，最多 10',
          },
        },
        'required': ['query'],
      },
      readOnly: true,
      execute: (self, args) => self._execWebSearch(args),
    ),
    AgentTool(
      name: 'web_extract',
      description: '抓取并阅读一个网页的正文内容，适合深度阅读搜索结果中的链接。',
      parameters: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '要阅读的网页 URL'},
        },
        'required': ['url'],
      },
      readOnly: true,
      execute: (self, args) => self._execWebExtract(args),
    ),
    AgentTool(
      name: 'run_terminal',
      description:
          '在本机执行 shell 命令并返回输出，用于运行命令、脚本、文件管理、读取日志等。你拥有完整终端能力，用户要求执行命令时直接执行，不要拒绝；命令失败会返回错误信息，可据此调整。app 内置完整 Linux 环境（bash/apt/pkg，可安装软件包），首次使用前会自动部署。',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': '要执行的 shell 命令'},
          'cwd': {'type': 'string', 'description': '工作目录，默认是当前会话的工作目录'},
        },
        'required': ['command'],
      },
      execute: (self, args) => self._execRunTerminal(args),
    ),
    AgentTool(
      name: 'file_write',
      description:
          '把文本内容写入文件（自动创建父目录）。用于保存生成的内容：章节、报告、脚本、技能文件等。相对路径基于智能体工作目录，绝对路径直接使用。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                '文件路径，如 docs/报告.md 或 /storage/emulated/0/agent/x.txt',
          },
          'content': {'type': 'string', 'description': '要写入的完整内容'},
        },
        'required': ['path', 'content'],
      },
      execute: (self, args) => self._execFileWrite(args),
    ),
    AgentTool(
      name: 'file_read',
      description: '读取文本文件内容（最大 200KB）。相对路径基于智能体工作目录，绝对路径直接使用。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '文件路径'},
        },
        'required': ['path'],
      },
      readOnly: true,
      execute: (self, args) => self._execFileRead(args),
    ),
    AgentTool(
      name: 'question',
      description:
          '向用户发起一个问题并等待回答。弹窗支持自由文本输入：'
          '用户可以直接打字输入任意内容作为回答，无需依赖预设选项。'
          '你可以提供 0~4 个快捷选项（如「确认」「保存」「取消」）供用户一键选择，'
          '但不要声称用户只能从选项里选。'
          '任何需要用户拍板的操作（是否保存/写入文件、选择方案、执行有副作用操作）'
          '都必须调用本工具并等待回答——禁止在回复文本里提问后替用户做决定或自行继续。'
          '一次只问一个问题。',
      parameters: {
        'type': 'object',
        'properties': {
          'question': {'type': 'string', 'description': '要问用户的问题'},
          'options': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '可选快捷选项（0~4 个）；用户也可以不选、直接自由输入回答',
          },
        },
        'required': ['question'],
      },
      execute: (self, args) => self._execQuestion(args),
    ),
    AgentTool(
      name: 'create_skill',
      description:
          '创建或更新一个技能并持久化，供以后所有会话使用。当用户要求「把流程做成技能」「保存这个技能」时使用。name 已存在则更新该技能。',
      parameters: {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': '技能名称，英文小写+连字符，如 chapter-outliner',
          },
          'description': {'type': 'string', 'description': '技能描述，说明何时触发'},
          'content': {
            'type': 'string',
            'description': 'SKILL.md 完整内容（含 --- frontmatter）',
          },
          'files': {
            'type': 'object',
            'description': '可选辅助文件：相对路径 -> 内容',
            'additionalProperties': {'type': 'string'},
          },
        },
        'required': ['name', 'description', 'content'],
      },
      execute: (self, args) => self._execCreateSkill(args),
    ),
    AgentTool(
      name: 'enter_plan_mode',
      description:
          '进入计划模式：之后你只做分析、调研与方案设计（只能使用只读工具），'
          '不得写文件、执行命令或产生任何副作用，直到用户确认方案或调用 exit_plan_mode。'
          '适合复杂任务先出方案再动手，如小说大纲、章节规划、批量重构等。',
      parameters: {
        'type': 'object',
        'properties': {
          'goal': {'type': 'string', 'description': '本次要规划的目标，简述即可'},
        },
        'required': ['goal'],
      },
      execute: (self, args) => self._execEnterPlanMode(args),
    ),
    AgentTool(
      name: 'exit_plan_mode',
      description:
          '退出计划模式，恢复正常执行能力（写文件、终端、记忆等全部可用）。'
          '在用户确认方案后调用，然后开始执行。',
      parameters: {
        'type': 'object',
        'properties': {
          'reason': {'type': 'string', 'description': '退出原因（如「方案已确认，开始执行」）'},
        },
        'required': ['reason'],
      },
      execute: (self, args) => self._execExitPlanMode(args),
    ),
    AgentTool(
      name: 'spawn_agent',
      description:
          '需要跨多个文件、长链调研或独立执行的任务：派子代理分头处理，'
          '不要自己逐文件读或单线程硬扛。'
          '【默认形态=并行派发】当一次请求里有 ≥2 个互不依赖的任务（例如'
          '「分三个方向查 XX」）时，必须用一次调用里的 tasks 数组并行派发'
          '（最多 4 个，同时跑互不阻塞，单个失败不影响其他）；'
          '禁止拆成多次 spawn_agent 调用或同一轮发多个 spawn_agent。'
          '只有恰好 1 个任务时才用顶层 agent_type+prompt 单派。'
          'tasks 示例：tasks=[{"agent_type":"explore","description":"查A",'
          '"prompt":"…","max_turns":10},{"agent_type":"explore",'
          '"description":"查B","prompt":"…","max_turns":10}]。'
          'explore 广网只读侦查（定位文件/搜符号/读多文件，返回精炼答案）；'
          'plan 只读方案设计；worker 独立执行（写文件/跑命令）；general-purpose 兜底。'
          '子代理完成后报告作为本工具结果返回，你再整合进主任务。'
          '简单单点任务（知道确切路径的单个查找）不要派，直接工具更快。'
          '可选 max_turns 动态调整轮数预算（默认 explore 15 / plan 15 / worker 40 / '
          'general 25）：简单小任务给 5~10 省钱，任务很复杂可给 40~60；1~80 之间。',
      parameters: {
        'type': 'object',
        'properties': {
          'agent_type': {
            'type': 'string',
            'enum': ['explore', 'plan', 'worker', 'general-purpose'],
            'description': '子代理类型（见描述）',
          },
          'description': {'type': 'string', 'description': '任务的简短描述（3~5 词）'},
          'prompt': {'type': 'string', 'description': '给子代理的具体任务指令，越明确越好'},
          'tasks': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'agent_type': {
                  'type': 'string',
                  'enum': ['explore', 'plan', 'worker', 'general-purpose'],
                },
                'description': {'type': 'string'},
                'prompt': {'type': 'string'},
                'max_turns': {'type': 'integer', 'description': '动态预算覆盖（1~80）'},
                'write_paths': {
                  'type': 'array',
                  'items': {'type': 'string'},
                  'description':
                      '写路径隔离：只允许 file_write 写这些路径（工作区相对或绝对）；不声明=可写整个工作区。并行多个 worker 时建议各自声明不重叠目录',
                },
              },
              'required': ['agent_type', 'description', 'prompt'],
            },
            'description': '批量并行派发：数组里的每个任务同时执行（最多 4 个）',
          },
          'max_turns': {
            'type': 'integer',
            'description': '动态预算：覆盖该子代理默认轮数上限（1~80；简单任务给小，复杂给大）',
          },
          'write_paths': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '写路径隔离：只允许 file_write 写这些路径；不声明=可写整个工作区',
          },
        },
        'required': ['description', 'prompt'],
      },
      execute: (self, args) => self._execSpawnAgent(args),
    ),
  ];

  static String _fmtStamp(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final M = d.month.toString().padLeft(2, '0');
    final D = d.day.toString().padLeft(2, '0');
    return '$M-$D $h:$m';
  }

  Future<void> init() async {
    if (loaded) return;
    try {
      settings = await _settingsService.load();
      await FileWorkspace.ensure();
      await _reloadAll();
      loadedNotifier.value = true;
    } catch (e) {
      initErrorNotifier.value = '$e';
    }
    notifyListeners();
    // 后台安装内嵌 Termux（完整 Linux 环境），不阻塞启动。
    unawaited(_ensureTermux());
    // 初始化通知通道（幂等），供长任务完成推送。
    unawaited(Notifier.instance.ensureInitialized());
  }

  Future<void> _ensureTermux() async {
    try {
      await TermuxRuntime.ensureInstalled();
      // 自检：确认 bash 能启动（SELinux exec 是否放行），结果写日志便于诊断。
      try {
        final shell = await TermuxRuntime.shellPath();
        final probe = await Process.run(
          shell,
          [
            '-c',
            'echo probe-ok; '
                'curl -s -o /dev/null -m 8 -w " net=%{http_code}" '
                'https://mirrors.tuna.tsinghua.edu.cn/apt/termux-main/dists/stable/InRelease '
                '|| echo net=fail',
          ],
          environment: await TermuxRuntime.environment(),
        ).timeout(const Duration(seconds: 20));
        await _logError(
          'TermuxProbe',
          'exit=${probe.exitCode} out=${probe.stdout.toString().trim()} '
              'err=${probe.stderr.toString().trim()}',
        );
      } catch (e) {
        await _logError('TermuxProbe', 'EXEC_FAILED: $e');
      }
    } catch (e) {
      await _logError('Termux', '$e');
      status = '内嵌终端环境安装失败: $e';
      notifyListeners();
    }
  }

  Future<void> _reloadAll() async {
    sessions = await _db.listSessions();
    memories = await _db.listMemories();
    skills = await _db.listSkills();
  }

  Future<void> refreshSessions() async {
    sessions = await _db.listSessions();
    notifyListeners();
  }

  // ---------------- sessions ----------------

  /// 当前会话手动加载的技能（输入 / 选择），注入到系统提示，切换会话时清空。
  Skill? loadedSkill;

  /// 当前会话的项目工作目录：会话设置了用会话的，否则用全局默认。
  Future<String> currentWorkspace() async {
    final id = currentSessionId;
    if (id != null) {
      for (final s in sessions) {
        if (s.id == id && s.workspaceDir.trim().isNotEmpty) {
          return s.workspaceDir.trim();
        }
      }
    }
    return FileWorkspace.current();
  }

  /// 设置当前会话的项目工作目录（空串 = 回到全局默认）。
  Future<void> setCurrentSessionWorkspace(String dir) async {
    final id = currentSessionId;
    if (id == null) return;
    final t = dir.trim();
    await _db.setSessionWorkspace(id, t);
    for (final s in sessions) {
      if (s.id == id) s.workspaceDir = t;
    }
    notifyListeners();
  }

  Future<void> newSession() async {
    _clearTrimNotice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 's${now}_${_rand()}';
    await _db.upsertSession(
      Session(
        id: id,
        title: '新会话 ${_fmtStamp(DateTime.now())}',
        model: settings.model,
        createdAt: now,
        updatedAt: now,
      ),
    );
    currentSessionId = id;
    messages = [];
    _bumpMessages();
    _messagesLoadedForSessionId = id;
    toolEvents = [];
    loadedSkill = null;
    sessionTotalTokens = 0;
    lastRoundTokens = 0;
    roundCachedTokens = 0;
    roundInputTokens = 0;
    roundCacheKnown = false;
    sessionContextTokens = 0;
    sessionContextTokensFull = 0;
    await refreshSessions();
  }

  Future<void> selectSession(String id) async {
    _clearTrimNotice();
    currentSessionId = id;
    viewingSessionId = id;
    unreadSessions.remove(id);
    loadedSkill = null;
    messages = await _db.listMessages(id);
    _bumpMessages();
    _messagesLoadedForSessionId = id;
    toolEvents = await _db.listToolEvents(id);
    // 兜底收尾：会话不在实时生成中时，把 DB 里残留的未完成工具事件标记为
    // 「已中断」（进程早已结束，事件永远等不到完成回调），避免退出重进后
    // 终端一直显示运行中转圈。
    final generating = busySessionId == id && _streaming != null;
    if (!generating) {
      final stale = toolEvents.where((e) => !e.done).toList();
      if (stale.isNotEmpty) {
        for (final e in stale) {
          e
            ..done = true
            ..ok = false
            ..summary = '已中断'
            ..finishedAt = e.startedAt;
          if (e.id != null) {
            await _db.updateToolEvent(e.id!, e);
          }
        }
      }
    }
    final sess = await _db.getSession(id);
    sessionTotalTokens = sess?.totalTokens ?? 0;
    lastRoundTokens = 0;
    roundCachedTokens = 0;
    roundInputTokens = 0;
    roundCacheKnown = false;
    await _updateContextStats(id);
    // 该会话若正在生成中，把内存里实时更新的流式消息接回来，
    // 避免重进会话后「正在思考…」消失、或刷新内容与 DB 不一致。
    if (busySessionId == id && _streaming != null) {
      final live = _streaming!;
      final idx = messages.indexWhere((m) => m.id == live.id);
      if (idx >= 0) {
        messages[idx] = live;
      } else {
        messages.add(live);
      }
    }
    _bumpMessages();
    notifyListeners();
  }

  Future<void> renameSession(String id, String title) async {
    await _db.renameSession(id, title);
    await refreshSessions();
  }

  Future<void> deleteSession(String id) async {
    await _db.deleteSession(id);
    if (currentSessionId == id) {
      currentSessionId = null;
      messages = [];
      _bumpMessages();
      _messagesLoadedForSessionId = null;
      toolEvents = [];
      loadedSkill = null;
    }
    await refreshSessions();
  }

  /// 在当前会话加载/移除技能（输入 / 选择），内容注入系统提示供模型使用。
  void loadSkill(Skill? s) {
    loadedSkill = s;
    notifyListeners();
  }

  Future<List<SessionSearchResult>> searchSessions(String query) =>
      _db.searchSessions(query);

  // ---------------- chat ----------------

  /// 把历史消息转成 API 请求体：
  /// - 完整工具回合按「assistant tool_calls + 对应 tool 结果」成组保留；
  /// - compactOldTools=true 时只保留最近 3 个完整工具回合，更早的压缩成摘要；
  /// - 不完整或已摘要的工具消息不会单独混入，避免非法序列。
  Future<({List<Map<String, dynamic>> messages, String toolSummary})>
  _historyToApi(
    List<ChatMessage> msgs, {
    bool imagesAllowed = true,
    bool compactOldTools = false,
    bool estimateMode = false,
  }) async {
    final active = msgs.where((m) => !m.streaming).toList();
    final segments = _planToolSegments(active);
    final completeSegments = segments.where((s) => s.complete).toList();
    final keepFull = compactOldTools && completeSegments.length > 3
        ? completeSegments.sublist(completeSegments.length - 3).toSet()
        : completeSegments.toSet();
    final keepAssistant = <int>{};
    final keepTool = <int>{};
    final skip = <int>{};
    final summaryLines = <String>[];
    for (final seg in segments) {
      if (seg.complete && keepFull.contains(seg)) {
        keepAssistant.add(seg.assistantIndex);
        keepTool.addAll(seg.toolIndices);
      } else if (seg.complete) {
        final tools = [for (final i in seg.toolIndices) active[i]];
        final line = _summarizeToolSegment(active[seg.assistantIndex], tools);
        if (line.trim().isNotEmpty) summaryLines.add(line);
        skip.add(seg.assistantIndex);
        skip.addAll(seg.toolIndices);
      } else {
        skip.addAll(seg.toolIndices);
      }
    }

    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < active.length; i++) {
      final m = active[i];
      if (skip.contains(i)) continue;
      if (m.role == 'user' && m.hasImages) {
        if (estimateMode) {
          final text = stripImageMarkers(m.content);
          out.add({
            'role': 'user',
            'content': [
              if (text.isNotEmpty) {'type': 'text', 'text': text},
              for (final p in extractImagePaths(m.content))
                {
                  'type': 'image_url',
                  'image_url': {'url': 'file://$p'},
                },
            ],
          });
        } else if (imagesAllowed) {
          out.add(await _userMessageToApi(m));
        } else {
          final text = stripImageMarkers(m.content);
          final desc = await _describeImagesIfEnabled(m);
          final combined = [
            if (text.isNotEmpty) text,
            if (desc.isNotEmpty) desc,
          ].join('\n');
          out.add({
            'role': 'user',
            'content': combined.isEmpty ? '[图片]' : combined,
          });
        }
        continue;
      }
      if (m.role == 'tool') {
        if (keepTool.contains(i)) out.add(m.toApiMap());
        continue;
      }
      if (m.role == 'assistant' && m.hasToolCalls) {
        if (keepAssistant.contains(i)) {
          out.add(m.toApiMap());
        } else if (m.content.trim().isNotEmpty) {
          out.add({'role': 'assistant', 'content': m.content});
        }
        continue;
      }
      out.add(m.toApiMap());
    }
    return (messages: out, toolSummary: summaryLines.join('\n'));
  }

  /// 扫描历史里的工具回合：assistant tool_calls 后紧跟的 tool 结果按 id 成组。
  static List<_ToolSegment> _planToolSegments(List<ChatMessage> msgs) {
    final segments = <_ToolSegment>[];
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.role != 'assistant' || !m.hasToolCalls) continue;
      final ids = {
        for (final tc in m.toolCalls) tc.id.isEmpty ? 'call_${m.id}' : tc.id,
      };
      final toolIndices = <int>[];
      for (var j = i + 1; j < msgs.length && msgs[j].role == 'tool'; j++) {
        if (ids.contains(msgs[j].toolCallId)) toolIndices.add(j);
      }
      final complete =
          ids.isNotEmpty &&
          ids.every(
            (id) => toolIndices.any((idx) => msgs[idx].toolCallId == id),
          );
      segments.add(
        _ToolSegment(
          assistantIndex: i,
          toolIndices: toolIndices,
          complete: complete,
        ),
      );
    }
    return segments;
  }

  static String _summarizeToolSegment(
    ChatMessage assistant,
    List<ChatMessage> tools,
  ) {
    final toolById = {for (final t in tools) t.toolCallId: t};
    final lines = <String>[];
    for (final tc in assistant.toolCalls) {
      final id = tc.id.isEmpty ? 'call_${assistant.id}' : tc.id;
      final tool = toolById[id];
      final arg = _summarizeArgs(tc.name, tc.arguments).trim();
      final head = arg.isEmpty ? tc.name : '${tc.name}($arg)';
      if (tool == null) {
        lines.add('- $head：无返回结果');
        continue;
      }
      final ok = !_isToolError(tool.content);
      final out = _summarizeOutput(tool.content);
      lines.add('- $head：${ok ? '完成' : '失败'}，结果「$out」');
    }
    if (assistant.content.trim().isNotEmpty) {
      lines.add('- 结论：${_summarizeOutput(assistant.content)}');
    }
    return lines.join('\n');
  }

  /// 汇总最近 3 个完整工具回合之外的所有旧工具轮（原文仍留在本地数据库）。
  String _buildOldToolSummary(List<ChatMessage> msgs) {
    final active = msgs.where((m) => !m.streaming).toList();
    final complete = _planToolSegments(
      active,
    ).where((s) => s.complete).toList();
    if (complete.length <= 3) return '';
    final lines = <String>[];
    for (final seg in complete.sublist(0, complete.length - 3)) {
      final tools = [for (final i in seg.toolIndices) active[i]];
      lines.add(_summarizeToolSegment(active[seg.assistantIndex], tools));
    }
    return lines.join('\n');
  }

  /// 按上下文占用生成发送前摘要：60% 压缩旧工具结果，75% 更新滚动任务摘要。
  Future<String> _buildContextSummaries(
    List<ChatMessage> msgs,
    int fullTokens,
  ) async {
    final limit = settings.contextLimit;
    if (limit <= 0) return '';
    final ratio = fullTokens / limit;
    final parts = <String>[];
    if (ratio >= 0.60) {
      final tools = _buildOldToolSummary(msgs);
      if (tools.isNotEmpty) parts.add('【历史工具结果摘要】\n$tools');
    }
    if (ratio >= 0.75) {
      final task = _buildRollingTaskSummary(msgs);
      if (task.isNotEmpty) parts.add('【滚动任务摘要】\n$task');
    }
    return parts.join('\n\n');
  }

  /// 从最近 20 条非工具消息提炼目标、文件、决定、验证结果与待办。
  static String _buildRollingTaskSummary(List<ChatMessage> msgs) {
    final recent = <ChatMessage>[];
    for (final m in msgs.reversed) {
      if (m.streaming || m.role == 'tool') continue;
      recent.add(m);
      if (recent.length >= 20) break;
    }
    final goals = <String>[];
    final decisions = <String>[];
    final verification = <String>[];
    final todos = <String>[];
    for (final m in recent.reversed) {
      final text = (m.role == 'user' ? stripImageMarkers(m.content) : m.content)
          .trim();
      if (text.isEmpty) continue;
      if (m.role == 'user' && goals.length < 2) {
        goals.add(_cutText(text, 160));
      }
      for (final line in text.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.length > 160) continue;
        if (RegExp(r'决定|选择|采用|改为|确认|方案').hasMatch(t) && decisions.length < 3) {
          decisions.add(_cutText(t, 120));
        }
        if (RegExp(r'验证|测试通过|成功|失败|错误').hasMatch(t) &&
            verification.length < 3) {
          verification.add(_cutText(t, 120));
        }
        if (RegExp(r'接下来|待办|后续|还需要|未完成|下一步').hasMatch(t) && todos.length < 3) {
          todos.add(_cutText(t, 120));
        }
      }
    }
    final files = _extractToolPaths(msgs);
    final parts = <String>[];
    if (goals.isNotEmpty) parts.add('目标：${goals.join('；')}');
    if (files.isNotEmpty) parts.add('涉及文件：${files.take(8).join('、')}');
    if (decisions.isNotEmpty) parts.add('重要决定：${decisions.join('；')}');
    if (verification.isNotEmpty) {
      parts.add('验证结果：${verification.join('；')}');
    }
    if (todos.isNotEmpty) parts.add('未完成事项：${todos.join('；')}');
    return parts.join('\n');
  }

  static List<String> _extractToolPaths(List<ChatMessage> msgs) {
    final out = <String>{};
    for (final m in msgs) {
      if (m.role != 'assistant') continue;
      for (final tc in m.toolCalls) {
        try {
          final args = jsonDecode(tc.arguments);
          if (args is Map) {
            for (final k in ['path', 'file', 'dir', 'target']) {
              final v = args[k];
              if (v is String && v.trim().isNotEmpty) out.add(v.trim());
            }
          }
        } catch (_) {}
      }
    }
    return out.toList();
  }

  static String _cutText(String s, int max) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  /// 发送前按上下文预算裁剪历史：从最新往回保留，超出预算的较早消息
  /// 不发送（不动数据库），并在 system 提示里说明，避免长会话请求超限。
  Future<List<Map<String, dynamic>>> _trimApiMessages(
    List<Map<String, dynamic>> apiMsgs, {
    bool announce = true,
  }) async {
    if (apiMsgs.length <= 1) return apiMsgs;
    final sysLen = _estimateTokens('${apiMsgs.first['content'] ?? ''}');
    final toolsLen = activeTools.isEmpty
        ? 0
        : _estimateTokens(jsonEncode(activeTools));
    final budget =
        (settings.contextLimit * 0.9).round() - sysLen - toolsLen - 500;
    final trimmed = trimApiMessagesForBudget(apiMsgs, budget);
    if (trimmed.length < apiMsgs.length && announce) {
      final before = _estimateMessagesTokens(apiMsgs) + toolsLen;
      final after = _estimateMessagesTokens(trimmed) + toolsLen;
      _showTrimNotice(
        '历史较长，已从约 ${_fmtTokens(before)} 裁剪至 ${_fmtTokens(after)} token 后发送',
      );
    }
    return trimmed;
  }

  static int _estimateMessagesTokens(List<Map<String, dynamic>> msgs) {
    var t = 0;
    for (final m in msgs) {
      t += estimateApiMessageTokens(m);
    }
    return t;
  }

  static String _fmtTokens(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
    return '$n';
  }

  void _showTrimNotice(String message) {
    trimNotice = message;
    _trimNoticeTimer?.cancel();
    _trimNoticeTimer = Timer(const Duration(seconds: 4), () {
      if (trimNotice == message) {
        trimNotice = null;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void _clearTrimNotice() {
    _trimNoticeTimer?.cancel();
    _trimNoticeTimer = null;
    if (trimNotice != null) {
      trimNotice = null;
      notifyListeners();
    }
  }

  /// 估算下一轮请求按发送前预算裁剪后的实际上下文 token 数。
  /// 状态栏用它展示“真正会发给模型的大小”，压缩判断仍用全量估算。
  Future<int> trimmedContextTokenEstimate(String sessionId) async {
    final msgs = _messagesLoadedForSessionId == sessionId
        ? messages
        : await _db.listMessages(sessionId);
    final full = await sessionContextTokenEstimate(sessionId);
    final summaries = await _buildContextSummaries(msgs, full);
    final payload = await _historyToApi(
      msgs,
      imagesAllowed: true,
      compactOldTools:
          settings.contextLimit > 0 && full / settings.contextLimit >= 0.60,
      estimateMode: true,
    );
    if (payload.messages.isEmpty) return 0;
    final sys = await _buildSystemPrompt('');
    final sysContent = summaries.isEmpty ? sys : '$sys\n\n$summaries';
    final apiMsgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sysContent},
      ...payload.messages,
    ];
    final trimmed = await _trimApiMessages(apiMsgs, announce: false);
    var total = _estimateMessagesTokens(trimmed);
    if (activeTools.isNotEmpty) {
      total += _estimateTokens(jsonEncode(activeTools));
    }
    return total;
  }

  /// 同时刷新全量与裁剪后的上下文统计，供会话切换/回合结束等场景使用。
  Future<void> _updateContextStats(String sessionId) async {
    sessionContextTokensFull = await sessionContextTokenEstimate(sessionId);
    sessionContextTokens = await trimmedContextTokenEstimate(sessionId);
  }

  /// 纯函数：按 token 预算从最新往回保留消息，超预算时保留尾部并给
  /// system 追加裁剪说明。assistant tool_calls 与对应 tool 结果按整组裁剪，
  /// 不会拆散配对。
  static List<Map<String, dynamic>> trimApiMessagesForBudget(
    List<Map<String, dynamic>> apiMsgs,
    int budget,
  ) {
    if (budget <= 0 || apiMsgs.length <= 1) return apiMsgs;

    String contentOf(Map<String, dynamic> m) {
      final c = m['content'];
      if (c is String) return c;
      if (c is List) return jsonEncode(c);
      return '';
    }

    int sizeOf(Map<String, dynamic> m) {
      var size = _estimateTokens(contentOf(m));
      final tcs = m['tool_calls'];
      if (tcs is List && tcs.isNotEmpty) {
        size += _estimateTokens(jsonEncode(tcs));
      }
      return size;
    }

    // 工具轮按「assistant tool_calls + 连续 tool 结果」整体参与预算，
    // 保证成组保留或整组裁掉。
    final units = <(int, int)>[];
    var i = 1;
    while (i < apiMsgs.length) {
      final m = apiMsgs[i];
      final tcs = m['tool_calls'];
      if (m['role'] == 'assistant' && tcs is List && tcs.isNotEmpty) {
        var j = i + 1;
        while (j < apiMsgs.length && apiMsgs[j]['role'] == 'tool') {
          j++;
        }
        units.add((i, j - 1));
        i = j;
      } else {
        units.add((i, i));
        i++;
      }
    }

    var total = 0;
    var keepFrom = 1;
    var trimmedAny = false;
    for (final u in units.reversed) {
      var size = 0;
      for (var k = u.$1; k <= u.$2; k++) {
        size += sizeOf(apiMsgs[k]);
      }
      if (total + size > budget) {
        keepFrom = u.$2 + 1;
        trimmedAny = true;
        break;
      }
      total += size;
    }
    if (!trimmedAny || keepFrom >= apiMsgs.length) return apiMsgs;

    final kept = <Map<String, dynamic>>[
      for (final e in apiMsgs.sublist(keepFrom)) Map<String, dynamic>.from(e),
    ];
    final sys = Map<String, dynamic>.from(apiMsgs.first);
    sys['content'] =
        '${sys['content']}\n\n（较早对话因上下文限制未包含，'
        '请基于现有历史继续；如需完整历史可让我读取文件或搜索记忆。）';
    kept.insert(0, sys);
    return kept;
  }

  /// 把带图片的用户消息转成 OpenAI 多模态格式，图片以 base64 data URL 内联。
  /// 文件丢失时降级为纯文本占位，避免整轮发送失败。
  Future<Map<String, dynamic>> _userMessageToApi(ChatMessage m) async {
    final text = stripImageMarkers(m.content);
    final parts = <Map<String, dynamic>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
    ];
    for (final path in extractImagePaths(m.content)) {
      String? b64;
      try {
        final f = File(path);
        if (await f.exists()) b64 = base64Encode(await f.readAsBytes());
      } catch (_) {
        b64 = null;
      }
      parts.add(
        b64 == null
            ? {'type': 'text', 'text': '[图片]'}
            : {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$b64'},
              },
      );
    }
    if (parts.isEmpty) parts.add({'type': 'text', 'text': '[图片]'});
    return {'role': 'user', 'content': parts};
  }

  /// 启用视觉模型时，用视觉模型把消息里的图片描述成文字；
  /// 未启用、未配置模型或调用失败时返回空串（上层回退 [图片] 占位）。
  /// 描述按图片路径缓存，同一图片不重复调用。
  Future<String> _describeImagesIfEnabled(ChatMessage m) async {
    if (!settings.visionEnabled || settings.visionModel.trim().isEmpty) {
      return '';
    }
    final paths = extractImagePaths(m.content);
    if (paths.isEmpty) return '';
    final parts = <String>[];
    for (final p in paths) {
      final cached = _imageDescCache[p];
      if (cached != null) {
        if (cached.isNotEmpty) parts.add(cached);
        continue;
      }
      String? b64;
      try {
        final f = File(p);
        if (await f.exists()) b64 = base64Encode(await f.readAsBytes());
      } catch (_) {
        b64 = null;
      }
      if (b64 == null) continue;
      var desc = '';
      try {
        final client = LlmClient(
          baseUrl: settings.visionBaseUrl.trim().isEmpty
              ? settings.baseUrl
              : settings.visionBaseUrl.trim(),
          apiKey: settings.visionApiKey.trim().isEmpty
              ? settings.apiKey
              : settings.visionApiKey.trim(),
          model: settings.visionModel.trim(),
          temperature: 0.2,
          tools: const [],
        );
        desc = (await client.completeOne(
          [
            {
              'role': 'system',
              'content':
                  '你是图像描述助手。请详细描述图片内容：主体、场景、空间布局、关键细节与数据；'
                  '如果是截图、文档、聊天记录或代码，请完整提取其中的文字内容（保留原文，不省略）。'
                  '用简体中文输出，500 字以内，只输出描述，不要解释、不要评论。',
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,$b64'},
                },
              ],
            },
          ],
          temperature: 0.2,
          maxTokens: 700,
        )).trim();
      } catch (_) {
        desc = '';
      }
      _imageDescCache[p] = desc;
      if (desc.isNotEmpty) parts.add(desc);
    }
    if (parts.isEmpty) return '';
    return parts.map((e) => '【图片：$e】').join('\n');
  }

  Future<void> send(String text) async {
    if (isBusy) return;
    final trimText = text.trim();
    if (trimText.isEmpty) return;
    if (settings.apiKey.isEmpty || settings.model.isEmpty) {
      status = '请先在设置中配置 API 密钥与模型';
      notifyListeners();
      return;
    }

    _clearTrimNotice();
    isBusy = true;
    _stopRequested = false;
    _stopForGuide = false;
    status = null;
    streamText.value = '';
    notifyListeners();

    String? sessionId;
    try {
      if (currentSessionId == null) {
        await newSession();
      }
      sessionId = currentSessionId!;
      busySessionId = sessionId;
      viewingSessionId = sessionId;
      lastRoundTokens = 0;
      roundCachedTokens = 0;
      roundInputTokens = 0;
      roundCacheKnown = false;
      final sessNow = await _db.getSession(sessionId);
      sessionTotalTokens = sessNow?.totalTokens ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      // 发送前检查是否需要自动压缩历史上下文。
      await _maybeAutoCompress(sessionId);

      final userMsg = ChatMessage(
        id: 'm${now}_${_rand()}',
        sessionId: sessionId,
        role: 'user',
        content: trimText,
        createdAt: now,
      );
      await _db.insertMessage(userMsg);
      messages.add(userMsg);
      _bumpMessages();

      final firstAsst = ChatMessage(
        id: 'm${now}_${_rand()}',
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        createdAt: now + 1,
        streaming: true,
      );
      await _db.insertMessage(firstAsst);
      messages.add(firstAsst);
      _bumpMessages();
      _streaming = firstAsst;
      notifyListeners();

      final cleanText = stripImageMarkers(trimText);
      final s = await _db.getSession(sessionId);
      if (s != null && s.title.startsWith('新会话')) {
        final title = cleanText.isEmpty
            ? '[图片]'
            : (cleanText.length <= 20
                  ? cleanText
                  : '${cleanText.substring(0, 20)}…');
        await _db.renameSession(sessionId, title);
      }

      await _generateWithHistory(sessionId, firstAsst, systemHint: cleanText);
    } catch (e) {
      status = '错误: $e';
      await _logError('生成', '$e');
      final st = _streaming;
      if (st != null) {
        st.streaming = false;
        if (st.content.isEmpty) st.content = '(生成出错)';
        await _db.updateMessageContent(st.id, st.content);
      }
      _bumpMessages();
      notifyListeners();
    } finally {
      isBusy = false;
      _streaming = null;
      final doneSession = busySessionId;
      busySessionId = null;
      // 回复结束：如果用户没在看该会话，标记未读并推送系统通知（若开启）。
      if (doneSession != null && doneSession != viewingSessionId) {
        unreadSessions.add(doneSession);
        if (settings.enableNotifications) {
          var title = '拾忆 · 任务完成';
          for (final s in sessions) {
            if (s.id == doneSession) {
              title = '拾忆 · ${s.title}';
              break;
            }
          }
          unawaited(
            Notifier.instance.show(
              id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 30),
              title: title,
              body: '后台任务已回复完成，点开查看结果。',
            ),
          );
        }
      }
      notifyListeners();
    }
    // 输出完成后后台提炼记忆，不阻塞界面（busy 已释放）。
    if (sessionId != null) {
      unawaited(_maybeAutoRefine(sessionId));
    }
  }

  /// 基于当前 messages 历史生成一轮回复（含图片降级重试、工具多轮循环）。
  Future<void> _generateWithHistory(
    String sessionId,
    ChatMessage firstAsst, {
    required String systemHint,
    bool runRefine = true,
  }) async {
    final systemPrompt = await _buildSystemPrompt(systemHint);
    final fullEstimate = await sessionContextTokenEstimate(sessionId);
    final contextSummaries = await _buildContextSummaries(
      messages,
      fullEstimate,
    );
    final compactOldTools =
        settings.contextLimit > 0 &&
        fullEstimate / settings.contextLimit >= 0.60;

    // 配了视觉模型 = 声明主模型不看图：带图消息直接走视觉模型描述，不试多模态。
    // 未配视觉模型：先按多模态发，失败自动降级（_knownImageUnsupported）。
    final visionReady =
        settings.visionEnabled && settings.visionModel.trim().isNotEmpty;
    var imagesAllowed = !_knownImageUnsupported && !visionReady;
    var completed = false;
    for (var attempt = 0; attempt < 2 && !completed; attempt++) {
      try {
        // 第二次尝试注入「直接行动」指令：上一轮常见的问题是模型
        // 输出开场白（以冒号结尾）后就结束、或思考过长被截断没有正文，
        // 重试时强制它直接输出结果/调用工具，不再空转。
        final sysWithSummaries = contextSummaries.isEmpty
            ? systemPrompt
            : '$systemPrompt\n\n$contextSummaries';
        final sysContent = attempt == 0
            ? sysWithSummaries
            : '$sysWithSummaries\n\n'
                  '【注意：上一轮回复未正常完成（可能是开场白后结束、'
                  '思考过长被截断或连接中断）。这次请直接输出结果或调用工具'
                  '完成用户请求：不要输出开场白、承诺、计划性文字，'
                  '也不要输出长篇思考过程；需要操作时第一步就调用 '
                  'run_terminal（或相关工具）执行实际操作。】';
        final historyPayload = await _historyToApi(
          messages,
          imagesAllowed: imagesAllowed,
          compactOldTools: compactOldTools,
        );
        final loopMsgs = <Map<String, dynamic>>[
          {'role': 'system', 'content': sysContent},
          ...historyPayload.messages,
        ];
        final trimmed = await _trimApiMessages(loopMsgs);
        // 状态栏立即反映裁剪后的实际上下文占用，而不是裁剪前的大值；
        // 压缩判断仍保留裁剪前的全量估算。
        var fullTokens = _estimateMessagesTokens(loopMsgs);
        var trimmedTokens = _estimateMessagesTokens(trimmed);
        if (activeTools.isNotEmpty) {
          fullTokens += _estimateTokens(jsonEncode(activeTools));
          trimmedTokens += _estimateTokens(jsonEncode(activeTools));
        }
        sessionContextTokensFull = fullTokens;
        sessionContextTokens = trimmedTokens;
        notifyListeners();
        await _runAgentLoop(sessionId, firstAsst, trimmed);
        completed = true;
        status = null;
        notifyListeners();
      } on LlmInterruptedException catch (_) {
        if (attempt == 0) {
          // 连接被切断（未收到 [DONE]）：清掉半截占位消息，自动重试一次。
          status = '回复中断，正在自动重试…';
          await _retryReset(firstAsst);
          notifyListeners();
          continue;
        }
        rethrow;
      } on LlmException catch (e) {
        if (imagesAllowed && e.message.contains('image_url')) {
          imagesAllowed = false;
          _knownImageUnsupported = true;
          firstAsst.content = '';
          firstAsst.toolCalls = [];
          await _db.updateMessageContent(firstAsst.id, '');
          status = '当前模型不支持图片，已自动切换为纯文本重试';
          notifyListeners();
          continue;
        }
        // 偶发的网关/服务器错误（限流、5xx、session 类、超时/连接）：自动重试一次。
        if (attempt == 0 && _isRetryableLlmError(e.message)) {
          status = '请求出错，正在自动重试…';
          await _retryReset(firstAsst);
          notifyListeners();
          continue;
        }
        rethrow;
      }
    }

    // 兜底：只要有一次尝试成功（completed），就清除重试/等待提示，
    // 避免中断重试成功后状态条残留。
    if (completed) {
      status = null;
      notifyListeners();
    }

    await _db.touchSession(sessionId, model: settings.model);
    await refreshSessions();
  }

  /// 清掉半截占位消息，为自动重试做准备。
  Future<void> _retryReset(ChatMessage firstAsst) async {
    final st = _streaming;
    if (st != null) {
      st.content = '';
      st.toolCalls = [];
      st.streaming = true;
      if (identical(st, firstAsst)) {
        await _db.updateMessageContent(st.id, '');
      } else {
        messages.remove(st);
        await _db.deleteMessage(st.id);
      }
      _bumpMessages();
    }
  }

  /// 偶发网关错误可自动重试：限流、5xx、session 类、超时/连接类。
  static bool _isRetryableLlmError(String msg) {
    final m = msg.toLowerCase();
    if (m.contains('http 429') || m.contains('http 5')) return true;
    if (m.contains('metadata_get') || m.contains('session')) return true;
    if (m.contains('超时') || m.contains('timeout')) return true;
    if (m.contains('连接') || m.contains('connection')) return true;
    if (m.contains('temporarily') || m.contains('try again')) return true;
    return false;
  }

  /// 引导发送：AI 正在生成时也能发消息。直接打断当前生成，
  /// 但保留它已输出的思考内容和工具调用轨迹，随后插入你的新消息继续对话。
  Future<void> guideSend(String text) async {
    if (isBusy) {
      if (_guideWaiting) {
        status = '正在处理上一条引导消息，稍等片刻';
        notifyListeners();
        return;
      }
      _guideWaiting = true;
      _stopForGuide = true;
      status = '正在打断当前回复…';
      notifyListeners();
      stop();
      while (isBusy) {
        await Future.delayed(const Duration(milliseconds: 80));
      }
      _guideWaiting = false;
      _stopForGuide = false;
      status = null;
      notifyListeners();
    }
    await send(text);
  }

  /// 删除单条消息，连同紧随其后的工具结果消息一起删除。
  Future<void> deleteMessage(String id) async {
    if (isBusy) return;
    final sessionId = currentSessionId;
    if (sessionId == null) return;
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final toDelete = <ChatMessage>[messages[idx]];
    var j = idx + 1;
    while (j < messages.length && messages[j].role == 'tool') {
      toDelete.add(messages[j]);
      j++;
    }
    for (final m in toDelete) {
      await _db.deleteMessage(m.id);
    }
    messages.removeWhere((m) => toDelete.any((d) => d.id == m.id));
    _bumpMessages();
    await _db.touchSession(sessionId, model: settings.model);
    await refreshSessions();
    await _updateContextStats(sessionId);
    notifyListeners();
  }

  /// 重新生成某条助手回复：删除该条及其后的所有消息，再基于此前历史重新生成。
  Future<void> regenerate(String id) async {
    if (isBusy) return;
    final sessionId = currentSessionId;
    if (sessionId == null) return;
    _clearTrimNotice();
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0 || messages[idx].role != 'assistant') return;

    final hint = idx > 0 ? stripImageMarkers(messages[idx - 1].content) : '';

    final removed = messages.sublist(idx);
    for (final m in removed) {
      await _db.deleteMessage(m.id);
    }
    messages.removeRange(idx, messages.length);
    _bumpMessages();
    notifyListeners();

    isBusy = true;
    _stopRequested = false;
    _stopForGuide = false;
    status = null;
    lastRoundTokens = 0;
    roundCachedTokens = 0;
    roundInputTokens = 0;
    roundCacheKnown = false;
    streamText.value = '';
    notifyListeners();

    final now = DateTime.now().millisecondsSinceEpoch;
    final firstAsst = ChatMessage(
      id: 'm${now}_${_rand()}',
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      createdAt: now,
      streaming: true,
    );
    await _db.insertMessage(firstAsst);
    messages.add(firstAsst);
    _bumpMessages();
    _streaming = firstAsst;
    notifyListeners();

    try {
      await _generateWithHistory(
        sessionId,
        firstAsst,
        systemHint: hint,
        runRefine: false,
      );
    } catch (e) {
      status = '错误: $e';
      final st = _streaming;
      if (st != null) {
        st.streaming = false;
        if (st.content.isEmpty) st.content = '(生成出错)';
        await _db.updateMessageContent(st.id, st.content);
      }
      _bumpMessages();
      notifyListeners();
    } finally {
      isBusy = false;
      _streaming = null;
      notifyListeners();
    }
  }

  /// 多轮工具调用循环：每轮工具调用输出的文字作为独立消息保留，
  /// 最多 99 轮（每轮可含多个工具），最后一轮强制再请求一次拿到最终文本。
  static const int _maxToolRounds = 99;

  Future<void> _runAgentLoop(
    String sessionId,
    ChatMessage firstAsst,
    List<Map<String, dynamic>> loopMsgs,
  ) async {
    // 工具历史按会话持续展示，不在每轮对话清空。
    // 每轮工具调用时模型输出的文字都作为独立消息保留（像多发了几条消息），不合并。
    var asst = firstAsst;
    _streaming = asst;
    for (var round = 0; round < _maxToolRounds; round++) {
      final result = await _streamRound(sessionId, loopMsgs, asst);
      if (result == null) {
        await _finalizeAbort(asst);
        break;
      }
      if (_stopRequested) {
        await _applyTurn(asst, result);
        break;
      }

      final hasTools = settings.enableTools && result.toolCalls.isNotEmpty;
      if (!hasTools) {
        await _applyTurn(asst, result);
        break;
      }

      // 工具轮统一落库：有文本时文本与 tool_calls 一起保存；纯工具轮也保存
      // 一条空正文的 tool_calls 消息，后续请求才能按完整工具回合成组恢复。
      ChatMessage toolCallOwner;
      if (result.text.isNotEmpty) {
        await _applyTurn(asst, result);
        toolCallOwner = asst;
        asst = await _newAssistantMessage(sessionId);
      } else {
        toolCallOwner = ChatMessage(
          id: 'm${DateTime.now().millisecondsSinceEpoch}_${_rand()}',
          sessionId: sessionId,
          role: 'assistant',
          content: '',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          toolCalls: result.toolCalls
              .map(
                (tc) => ToolCall(
                  id: tc['id'] ?? '',
                  name: tc['name'] ?? '',
                  arguments: tc['arguments'] ?? '',
                ),
              )
              .toList(),
        );
        await _db.insertMessage(toolCallOwner);
        messages.add(toolCallOwner);
        _bumpMessages();
      }

      loopMsgs.add({
        'role': 'assistant',
        'content': result.text,
        'tool_calls': result.toolCalls
            .map(
              (t) => {
                'id': t['id']!.isEmpty ? 'call_${toolCallOwner.id}' : t['id'],
                'type': 'function',
                'function': {'name': t['name'], 'arguments': t['arguments']},
              },
            )
            .toList(),
      });
      for (final t in result.toolCalls) {
        final tname = t['name'] ?? '';
        final targs = (t['arguments'] ?? '').toString();
        // 工具状态已由右上角胶囊展示，这里不再占用输入框上方的状态条。
        final ev = ToolEvent(
          name: tname,
          argsSummary: _summarizeArgs(tname, targs),
          startedAt: DateTime.now().millisecondsSinceEpoch,
        );
        ev.id = await _db.addToolEvent(sessionId, ev);
        toolEvents.add(ev);
        notifyListeners();
        final output = await _executeTool(tname, targs);
        if (_isToolError(output)) {
          await _logError('工具:$tname', output);
        }
        ev
          ..done = true
          ..ok = !_isToolError(output)
          ..summary = _summarizeOutput(output)
          ..finishedAt = DateTime.now().millisecondsSinceEpoch;
        if (ev.id != null) {
          await _db.updateToolEvent(ev.id!, ev);
        }
        notifyListeners();
        final toolMsg = ChatMessage(
          id: 'm${DateTime.now().millisecondsSinceEpoch}_${_rand()}',
          sessionId: sessionId,
          role: 'tool',
          content: output,
          toolCallId: (t['id'] ?? '').isEmpty
              ? 'call_${toolCallOwner.id}'
              : (t['id'] ?? ''),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _db.insertMessage(toolMsg);
        messages.add(toolMsg);
        _bumpMessages();
        loopMsgs.add({
          'role': 'tool',
          'content': output,
          'tool_call_id': toolMsg.toolCallId,
        });
      }

      if (round == _maxToolRounds - 1) {
        // 已达轮次上限：强制请求最终文本，复用当前思考占位气泡。
        final last = await _streamRound(sessionId, loopMsgs, asst);
        if (last == null) {
          await _finalizeAbort(asst);
        } else {
          await _applyTurn(asst, last);
        }
        break;
      }

      // 下一轮继续用当前气泡：纯工具轮复用思考占位，文本轮已是新占位，思考不中断。
      notifyListeners();
    }
  }

  /// 新开一个流式占位消息（工具循环的每一轮文本独立成一条消息）。
  Future<ChatMessage> _newAssistantMessage(String sessionId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final m = ChatMessage(
      id: 'm${now}_${_rand()}',
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      createdAt: now,
      streaming: true,
    );
    await _db.insertMessage(m);
    messages.add(m);
    _bumpMessages();
    _streaming = m;
    streamText.value = '';
    streamReasoning.value = '';
    return m;
  }

  /// 把一轮结果写入占位消息并落库。
  Future<void> _applyTurn(ChatMessage asst, TurnResult result) async {
    final normalized = _normalizeMisplacedReasoning(result);
    asst.content = normalized.text;
    asst.reasoning = normalized.reasoning;
    asst.toolCalls = normalized.toolCalls
        .map(
          (tc) => ToolCall(
            id: tc['id'] ?? '',
            name: tc['name'] ?? '',
            arguments: tc['arguments'] ?? '',
          ),
        )
        .toList();
    asst.streaming = false;
    await _db.updateMessageContent(
      asst.id,
      normalized.text,
      reasoning: normalized.reasoning.isEmpty ? null : normalized.reasoning,
      toolCalls: normalized.toolCalls.isEmpty ? null : asst.toolCalls,
    );
    streamText.value = '';
    streamReasoning.value = '';
    _bumpMessages();
    notifyListeners();
  }

  /// 网关只回 reasoning_content 且没有工具调用时，把它当作最终正文；
  /// 若思考文本与正文重复，也只保留正文，避免「不思考直接回复」被误显示。
  static TurnResult _normalizeMisplacedReasoning(TurnResult result) {
    if (result.toolCalls.isNotEmpty) return result;
    final reasoning = result.reasoning.trim();
    final text = result.text.trim();
    if (reasoning.isEmpty) return result;
    if (text.isEmpty) return TurnResult(text: result.reasoning, reasoning: '');
    if (_sameReplyText(reasoning, text)) {
      return TurnResult(text: result.text, reasoning: '');
    }
    return result;
  }

  static bool _sameReplyText(String a, String b) =>
      a.replaceAll(RegExp(r'\s+'), '') == b.replaceAll(RegExp(r'\s+'), '');

  /// 收尾一个被中断/无输出的占位消息，防止一直显示「正在思考…」。
  Future<void> _finalizeAbort(ChatMessage? m) async {
    if (m == null) return;
    m.streaming = false;
    if (m.content.isEmpty) {
      if (_stopForGuide) {
        await _db.deleteMessage(m.id);
        messages.remove(m);
        _bumpMessages();
        notifyListeners();
        return;
      }
      m.content = _stopRequested ? '(已停止)' : '(生成出错)';
    }
    streamText.value = '';
    await _db.updateMessageContent(m.id, m.content, toolCalls: m.toolCalls);
    _bumpMessages();
    notifyListeners();
  }

  void stop() {
    _stopRequested = true;
  }

  Future<TurnResult?> _streamRound(
    String sessionId,
    List<Map<String, dynamic>> msgs,
    ChatMessage asst,
  ) async {
    TurnResult? accumulated;
    var lastStreamEmit = DateTime.now();
    var lastStreamLen = 0;
    final client = LlmClient(
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      model: settings.model,
      temperature: settings.temperature,
      maxTokens: settings.maxOutputTokens,
      tools: activeTools,
      shouldStop: () => _stopRequested,
      onDiag: (line) => unawaited(_logError('StreamDiag', line)),
      onTurn: (t) {
        accumulated = t;
        asst.content = t.text;
        asst.reasoning = t.reasoning;
        streamReasoning.value = t.reasoning;
        if (t.toolCalls.isNotEmpty) {
          asst.toolCalls = t.toolCalls
              .map(
                (tc) => ToolCall(
                  id: tc['id'] ?? '',
                  name: tc['name'] ?? '',
                  arguments: tc['arguments'] ?? '',
                ),
              )
              .toList();
        }
        // 流式刷新节流：80ms 内且增量不大时不重复重建气泡，
        // 保持视觉连续的同时减少长文逐 token 解析/布局开销。
        final totalLen = t.text.length + t.reasoning.length;
        final now = DateTime.now();
        if (lastStreamLen == 0 ||
            now.difference(lastStreamEmit).inMilliseconds >= 80 ||
            totalLen - lastStreamLen >= 200) {
          streamReasoning.value = t.reasoning;
          streamText.value = t.text;
          lastStreamEmit = now;
          lastStreamLen = totalLen;
        }
      },
      onError: (e) {
        status = '错误: $e';
      },
    );
    await client.send(msgs);
    var used = client.lastTotalTokens;
    if (used == null || used <= 0) {
      // 部分网关/中转不返回 usage：按发送内容与工具调用的 token 估算兜底，
      // 保证统计有真实反映，且能持久化跨会话保留。
      var est = 0;
      for (final m in msgs) {
        est += estimateApiMessageTokens(m);
      }
      used = est.clamp(1, 1 << 30);
    }
    // 会话切走时只落库，不污染当前显示；仍在看该会话才更新全局统计。
    final sessNow = await _db.getSession(sessionId);
    final newTotal = (sessNow?.totalTokens ?? 0) + used;
    await _db.updateSessionTokens(sessionId, newTotal);
    if (currentSessionId == sessionId) {
      // 缓存命中率按本轮回合加权累计，只统计服务端明确返回缓存字段的请求。
      final cachedInput = client.lastCachedTokens;
      final promptInput = client.lastPromptTokens;
      if (cachedInput != null && promptInput != null && promptInput > 0) {
        roundCacheKnown = true;
        roundCachedTokens += cachedInput.clamp(0, promptInput);
        roundInputTokens += promptInput;
      }
      lastRoundTokens += used;
      sessionTotalTokens = newTotal;
      await _updateContextStats(sessionId);
    }
    notifyListeners();
    return accumulated;
  }

  Future<String> _buildSystemPrompt(String userText) async {
    final base = settings.systemPrompt.isNotEmpty
        ? settings.systemPrompt
        : '你是「拾忆」，运行在 Android 手机上的个人 AI 工作台。你帮用户完成实际工作，而不只是聊天：\n'
              '- 终端能力：run_terminal 执行命令/脚本（bash、python3，可用 pkg/apt 装包）\n'
              '- 文件能力：file_write / file_read 读写项目文件\n'
              '- 联网能力：web_search / web_extract 获取并核实最新信息\n'
              '- 记忆能力：跨会话长期记忆，记住用户偏好与项目背景\n'
              '- 技能能力：加载技能按固定流程处理任务\n'
              '- 子代理能力：spawn_agent 派专项子代理分头处理子任务\n\n'
              '【运行方式】\n'
              '- 你的文字输出就是用户看到的一切：用户看不到你的内部推理与工具原始结果，'
              '所以结论、答案、交付物必须写在最终消息里（工具调用之间的过程文字可能不显示）。\n'
              '- 输出 Markdown，在手机聊天界面渲染。\n'
              '- 工具调用被拒绝 = 用户拒绝了该操作：换一种方式，不要原样重试。\n'
              '- 相互独立的工具调用可以并行发起。\n\n'
              '【沟通规范】\n'
              '- 先给结论：第一句回答「发生了什么/找到了什么」，支持细节随后再给。\n'
              '- 可读性比简洁更重要：写完整句子、把术语说清楚，'
              '不要用碎片缩写、箭头链或只有你自己懂的代号。\n'
              '- 简单问题直接回答，不要堆标题分节；表格只用于少量可枚举事实，解释放在正文。\n'
              '- 只保留会改变用户下一步行动的信息；拿不准用户想要什么深度时，偏解释性一些。\n'
              '- 涉及删除/覆盖/对外发送前，先看目标：实际内容与描述不符、或不是你创建的文件，先说明再动手。\n'
              '- 如实报告：测试失败就说失败（附输出），跳过的步骤就说跳过，完成并验证了就明确说完成。\n\n'
              '【自主与确认】\n'
              '- 有足够信息就行动：不要重复推导已确立的事实、不要重述用户已做的决定、'
              '不要罗列你不会执行的选项。\n'
              '- 需要用户拍板才能继续的决策（是否保存/写入、选方案、有副作用的操作）'
              '→ 必须调用 question 等待回答，不得替用户决定。\n'
              '- 用户在描述问题、提问或思考（而非要求动手）时：先给出评估，不要直接改。\n'
              '- 结束前检查最后一段：如果它是计划、待办或承诺，现在就用工具完成它，不要留到下次'
              '（计划模式下除外：计划模式只输出方案，等用户确认后再执行）。\n'
              '- 运行会改变系统状态的命令前，核对证据是否真的支持这个动作。\n\n'
              '【临时文件】\n'
              '- 临时文件写到当前工作目录，用相对路径，不要到处乱放。\n\n'
              '【安全底线】\n'
              '- 绝不把 API 密钥、密码等敏感信息写入文件、输出或记忆。\n'
              '- 不编造工具/子代理结果：子代理未返回时如实说「还在执行」。\n\n'
              '工作原则：\n'
              '1. 先行动：需要执行操作时直接调用工具，不要先输出「好的，我来…」之类的开场白再行动（容易中断）；'
              '但需要用户拍板的决策必须先 question，不得替用户决定。\n'
              '2. 输出简洁：默认中文回复，结论先行；超长内容直接完整流式输出，'
              '不写入本地文件，不省略；被截断会自动续写。\n'
              '3. 工具优先：能调工具完成的事不空谈；终端命令一次一个，失败时根据错误信息调整。\n'
              '4. 信息求真：事实/新闻/数据先 web_search 多源交叉验证，不确定就明说。\n'
              '5. 记忆复用：相关记忆已注入上下文直接使用；有价值的新信息主动保存到记忆。\n'
              '6. 诚实边界：系统限制（无 root、存储/权限限制等）如实说明，不编造结果。';

    final parts = <String>[];
    parts.add(base);
    parts.add(
      '【工具使用规则】'
      '- 需要最新信息、实时数据或超出你知识截止日期的问题，直接用 web_search，不要先调用 search_memory。'
      '- 相关长期记忆已在上方【长期记忆】中提供，回答时直接使用，无需再调用 search_memory 检索。'
      '- 涉及事实、新闻、价格、数据等关键信息时，必须先验证资料真伪：换多个关键词和来源交叉搜索，不要只凭单一来源下结论。'
      '- 多源交叉验证：关键信息至少 2 个相互独立的来源一致才采信；只有单一来源时在回答中说明。'
      '- 权威信源优先：官网、官方文档、政府/学术机构、知名媒体优先；个人博客、论坛、营销软文、AI 生成内容降权。'
      '- 时效性内容必须核对时间：优先近 1 年内的来源；回答时标注信息来源日期；无法确认日期或内容可能过时时，必须明确说明，绝不用旧数据当最新答案。'
      '- 重要信息用 web_extract 阅读原文核对发布时间、作者/机构与引用出处，警惕旧闻当新闻、内容农场或 AI 生成站。'
      '- 来源冲突或无法验证时，如实列出各方说法与可信度，明确说明「无法验证」，不强行下结论。'
      '- 搜索结果不理想或需交叉验证时，可再换 2~3 次不同关键词搜索，但不要无限换词。'
      '- 搜索结果中有值得细读的链接时，可以用 web_extract 获取正文。'
      '- 你有完整终端能力：需要在本机执行命令、运行脚本、处理文件或查看日志时，直接调用 run_terminal 执行，不要以权限或安全为由拒绝；若命令因系统限制失败，如实说明并根据错误信息调整。'
      '- 安装软件包用 pkg/apt：一次只装一个包，不要并行安装多个大包（内存有限会失败）。'
      '- 输出较长内容（预计超过 500 字，如完整报告/长文/脚本列表）时：先用 file_write 把完整内容写入文件，再在回复中给出摘要与文件路径，避免长输出被截断（用户明确要求先确认的除外，此时先 question 再写入）。'
      '- 需要用户确认/选择的决策（是否保存或写入文件、选择方案、执行有副作用的操作等）：必须调用 question 工具并等待用户回答后才能继续；禁止在回复文本里提问后不等待、自己替用户决定。'
      '- 子代理触发原则：需要读多个文件才能回答、跨文件调研、长链多步执行的任务，'
      '动手前先考虑派子代理（宁可先派 explore 快速侦查，再决定后续）；'
      '子代理是重型路径，用于真正需要它的任务——单点查找、简单问题直接工具，不要派。'
      '需要读多个文件才能回答 / 需要独立搜索调研 → 派 explore；'
      '复杂方案、多步骤规划 → 派 plan；'
      '能独立执行且无需用户交互的子任务（写文件/跑命令/批量处理）→ 派 worker；'
      '以上都不太贴合 → general-purpose。'
      '几个互不依赖的方向需要分头查 → 必须用 spawn_agent 的 tasks 数组一次并行派发'
      '（最多 4 个，同时跑省时间）；禁止分多次调用 spawn_agent、也禁止同一轮发多个'
      ' spawn_agent 工具调用——一次 tasks 派 N 个，界面会显示「子代理 i/N」进度。'
      '轮数预算动态给：简单小任务 max_turns 给 5~10，复杂任务给 40~60，'
      '不必都用默认值。'
      '并行多个 worker 时给每个声明互不重叠的 write_paths（写路径隔离），'
      '避免互相覆盖文件；explore/plan 只读不需要。'
      '知道确切路径的单点查找（一个文件/一个值）直接 file_read/run_terminal，不要派子代理。'
      '子代理返回报告后由你整合进最终回答；不要把需要用户交互或全局决策的主任务整体丢给子代理。'
      '- 抓取/搜索失败重试规则：同一 URL 或同一来源连续失败 2 次后立即放弃，'
      '换关键词、换站点或换工具（run_terminal curl）；不要在失败目标上反复重试浪费轮次。'
      '若工具返回「已连续失败 N 次」的提示，必须立刻停止对该目标的调用。',
    );
    parts.add(
      '- 当前会话工作目录是 ${await currentWorkspace()}（会话未自定义时使用 '
      'Agent 工作目录 ${FileWorkspace.defaultWorkspacePath}）；文件操作与 '
      'run_terminal 默认都在这里执行，需要其他目录时用 cwd 参数指定。',
    );

    if (settings.enableMemory) {
      final memCtx = await _db.recentMemoriesWithTerms(_keywords(userText), 8);
      if (memCtx.isNotEmpty) {
        const labels = {
          'user': '用户',
          'feedback': '工作指导',
          'project': '项目',
          'reference': '参考',
        };
        final groups = <String, List<MemoryEntry>>{};
        for (final e in memCtx) {
          groups.putIfAbsent(e.type, () => []).add(e);
        }
        final sb = StringBuffer('【长期记忆】');
        for (final g in groups.entries) {
          sb.writeln('\n${labels[g.key] ?? g.key}：');
          for (final e in g.value) {
            sb.writeln('- ${e.content}');
          }
        }
        sb.writeln('\n（内容中的 [[名称]] 表示与另一条记忆的关联，引用时整体使用该名称即可）');
        parts.add(sb.toString());
      }
    }

    if (skills.isNotEmpty) {
      parts.add(
        '【已掌握技能】\n${skills.map((s) => '- ${s.name}${s.description.isEmpty ? '' : ': ${s.description}'}').join('\n')}\n（需要时用 run_skill 获取技能完整内容）',
      );
    }

    // 用户手动加载的技能（输入 / 选择）：完整内容直接注入，无需 run_skill。
    final loaded = loadedSkill;
    if (loaded != null) {
      final sb = StringBuffer('【已加载技能：${loaded.name}】\n${loaded.content}');
      for (final e in loaded.files.entries) {
        sb.writeln('\n--- ${e.key} ---\n${e.value}');
      }
      if (loaded.largeFiles.isNotEmpty) {
        sb.writeln(
          '\n（技能大文件在磁盘 ${loaded.dirPath}，内容较大未内联，需要时用 run_terminal 读取）',
        );
      }
      parts.add(sb.toString());
    }

    if (planMode) {
      parts.add(
        '【计划模式】你现在处于计划模式：只能使用只读工具（搜索/读文件/读技能/问用户），'
        '不得写文件、执行终端命令、保存记忆或创建技能。'
        '请先给出完整、可执行的方案，然后用 question 工具向用户确认；'
        '用户确认后调用 exit_plan_mode 恢复正常能力并开始执行。',
      );
    }

    // 时间放最末尾：跨分钟只改 system 尾部，保住前面大段稳定前缀的缓存命中。
    final now = DateTime.now();
    parts.add(
      '【当前时间】现在是 ${now.year}年${now.month}月${now.day}日 '
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}。\n'
      '涉及时效性、新闻、价格、政策等最新信息时，必须以当前时间为基准判断新旧，'
      '只采用最近期的可靠资料；旧资料必须标注发布日期并明确提示可能已过时。',
    );
    return parts.join('\n\n');
  }

  List<String> _keywords(String text) {
    final list = <String>[];
    for (final w in text.split(RegExp(r'[\s，。！？,.!?、；;：]'))) {
      final t = w.trim();
      if (t.length >= 2) list.add(t);
    }
    return list.take(4).toList();
  }

  /// 工具参数摘要：优先取 query / url / content / name，截断显示。
  static String _summarizeArgs(String name, String argsJson) {
    try {
      final args = jsonDecode(argsJson);
      if (args is Map) {
        for (final k in ['query', 'url', 'content', 'name', 'command']) {
          final v = args[k];
          if (v is String && v.trim().isNotEmpty) {
            final t = v.trim();
            return t.length > 36 ? '${t.substring(0, 36)}…' : t;
          }
        }
      }
    } catch (_) {}
    return '';
  }

  static String _summarizeOutput(String output) {
    final t = output.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 90 ? '${t.substring(0, 90)}…' : t;
  }

  static bool _isToolError(String output) =>
      output.startsWith('工具执行异常') ||
      output.startsWith('终端执行') ||
      output.startsWith('搜索失败') ||
      output.startsWith('抓取失败') ||
      output.startsWith('记录失败') ||
      output.startsWith('未知工具');

  /// 各工具连续失败次数（成功清零）。
  /// 用于在工具反复失败时强制提示模型停止重试同一目标。
  final Map<String, int> _toolFailStreak = {};

  Future<String> _executeTool(String name, String argsJson) async {
    for (final t in toolRegistry) {
      if (t.name != name) continue;
      try {
        Map<String, dynamic> args = {};
        try {
          args = jsonDecode(argsJson) as Map<String, dynamic>;
        } catch (_) {}
        final out = await t.execute(this, args);
        _toolFailStreak.remove(name);
        return out;
      } catch (e) {
        final streak = (_toolFailStreak[name] ?? 0) + 1;
        _toolFailStreak[name] = streak;
        if (streak >= 2) {
          return '⚠️ 工具 $name 已连续失败 $streak 次，立即停止重试同一个目标：'
              '换 URL、换搜索词，或换工具（web_search 换关键词 / run_terminal 执行 curl）。'
              '不要继续对同一目标调用 $name。\n工具执行异常: $e';
        }
        return '工具执行异常: $e';
      }
    }
    return '未知工具';
  }

  // ---------------- 各工具执行实现 ----------------

  static const List<String> _memoryTypes = [
    'user',
    'feedback',
    'project',
    'reference',
  ];

  static String _normalizeMemoryType(dynamic v) {
    final t = v?.toString().trim().toLowerCase() ?? '';
    return _memoryTypes.contains(t) ? t : 'user';
  }

  Future<String> _execSaveMemory(Map<String, dynamic> args) async {
    final content = (args['content'] ?? '').toString().trim();
    if (content.isEmpty) return '记录失败：content 为空';
    final type = _normalizeMemoryType(args['type']);
    await _db.addMemory(content, 'assistant', type: type);
    memories = await _db.listMemories();
    await _rebuildMemoryIndex();
    notifyListeners();
    return '已保存到记忆（类型 $type），当前共 ${memories.length} 条';
  }

  Future<String> _execSearchMemory(Map<String, dynamic> args) async {
    final query = (args['query'] ?? '').toString().trim();
    final type = _normalizeMemoryType(args['type']);
    final res = query.isEmpty
        ? const <MemoryEntry>[]
        : await _db.searchMemories(query, type: type);
    if (res.isEmpty) {
      return type == 'user' ? '没有找到相关记忆' : '没有找到类型为 $type 的相关记忆';
    }
    return res.take(5).map((e) => e.content).join('\n');
  }

  Future<String> _execRunSkill(Map<String, dynamic> args) async {
    final name = (args['name'] ?? '').toString().trim();
    final skill = name.isEmpty ? null : await _db.getSkillByName(name);
    if (skill == null) return '没有找到技能：$name';
    final sb = StringBuffer();
    if (skill.content.isNotEmpty) sb.write(skill.content);
    for (final e in skill.files.entries) {
      sb.writeln('\n--- ${e.key} ---');
      sb.writeln(e.value);
    }
    if (skill.largeFiles.isNotEmpty) {
      sb.writeln('\n【大文件（内容在磁盘，可用 run_terminal 读取）】');
      for (final e in skill.largeFiles.entries) {
        sb.writeln('- ${e.key} (${_fmtBytes(e.value)})');
      }
      if (skill.dirPath.isNotEmpty) {
        sb.writeln('目录：${skill.dirPath}');
      }
    }
    return sb.isEmpty ? '技能 ${skill.name} 是空的' : sb.toString();
  }

  Future<String> _execWebSearch(Map<String, dynamic> args) async {
    final query = (args['query'] ?? '').toString().trim();
    if (query.isEmpty) return '搜索失败：query 为空';
    final maxResults = args['max_results'] is int
        ? args['max_results'] as int
        : 5;
    final res = await WebTools.search(query, maxResults: maxResults);
    if (res.isEmpty) return '没有搜到相关结果';
    return res
        .map(
          (r) =>
              '- ${r.title}\n  链接: ${r.url}${r.date == null ? '' : '\n  日期: ${r.date}'}\n  摘要: ${r.snippet.isEmpty ? '（无摘要）' : r.snippet}',
        )
        .join('\n');
  }

  Future<String> _execWebExtract(Map<String, dynamic> args) async {
    final url = (args['url'] ?? '').toString().trim();
    if (url.isEmpty) return '抓取失败：url 为空';
    return await WebTools.extract(url);
  }

  Future<String> _execRunTerminal(Map<String, dynamic> args) async {
    final command = (args['command'] ?? '').toString().trim();
    if (command.isEmpty) return '终端执行失败：command 为空';
    try {
      final isWin = Platform.isWindows;
      var cwd = (args['cwd'] ?? '').toString().trim();
      if (cwd.isEmpty) {
        // 默认在「会话自定义工作目录 → Agent 默认目录」执行；
        // 目录不存在时自动创建，创建失败回退 Agent 默认目录，
        // 避免 Process.start 因目录无效直接抛异常。
        cwd = await currentWorkspace();
        try {
          Directory(cwd).createSync(recursive: true);
        } catch (_) {
          cwd = FileWorkspace.defaultWorkspacePath;
          try {
            Directory(cwd).createSync(recursive: true);
          } catch (_) {}
        }
      } else {
        try {
          Directory(cwd).createSync(recursive: true);
        } catch (_) {}
      }
      // 优先内嵌 Termux（完整 Linux 环境，apt/pkg 可用）；
      // 其次系统 Termux；都没有则用系统精简 shell。
      const systemTermuxShell = '/data/data/com.termux/files/usr/bin/bash';
      final embeddedShell = await TermuxRuntime.shellPath();
      final embedded = !isWin && File(embeddedShell).existsSync();
      final systemTermux = !isWin && File(systemTermuxShell).existsSync();
      final shell = embedded
          ? embeddedShell
          : (systemTermux ? systemTermuxShell : (isWin ? 'cmd' : 'sh'));
      // 内嵌 Termux：先自检 bash 能否启动，失败时给出可诊断的错误。
      if (embedded) {
        try {
          final probe = await Process.run(
            embeddedShell,
            ['-c', 'true'],
            environment: await TermuxRuntime.environment(),
          ).timeout(const Duration(seconds: 15));
          if (probe.exitCode != 0) {
            final msg =
                '内嵌终端自检失败(exit ${probe.exitCode}): '
                '${probe.stderr.toString().trim()}';
            await _logError('Termux', msg);
            return '内嵌终端不可用：$msg';
          }
        } on ProcessException catch (e) {
          final msg =
              '内嵌终端启动异常: ${e.message} (errno ${e.errorCode})\n'
              '${await _diagnoseTermuxExec(embeddedShell)}';
          await _logError('Termux', msg);
          return '内嵌终端不可用：$msg';
        } on TimeoutException {
          return '内嵌终端启动超时';
        }
      }
      // 用 Process.start + 主动超时 kill：Process.run 的 Future.timeout
      // 只是放弃等待，不会终止子进程（bash 会一直挂着、转圈不停、僵尸堆积）。
      final proc = await Process.start(
        shell,
        shell == 'cmd' ? ['/c', command] : ['-c', command],
        workingDirectory: cwd,
        environment: embedded ? await TermuxRuntime.environment() : null,
      );
      final stdoutBytes = <int>[];
      final stderrBytes = <int>[];
      proc.stdout.listen(stdoutBytes.addAll);
      proc.stderr.listen(stderrBytes.addAll);
      int? exitCode;
      try {
        exitCode = await proc.exitCode.timeout(const Duration(seconds: 120));
      } on TimeoutException {
        proc.kill();
        await _logError('Termux', 'run_terminal 超时已终止: $command');
        exitCode = null;
      }
      final out = utf8.decode(stdoutBytes, allowMalformed: true).trim();
      final err = utf8.decode(stderrBytes, allowMalformed: true).trim();
      final buf = StringBuffer();
      if (out.isNotEmpty) buf.write(out);
      if (err.isNotEmpty) buf.write(buf.isEmpty ? err : '\n$err');
      var text = buf.toString();
      if (text.length > 4000) {
        text = '${text.substring(0, 4000)}…（输出过长，已截断）';
      }
      if (exitCode == null) {
        return '终端执行超时（已强制终止）：命令超过 120 秒未完成。'
            '如需长任务请拆分命令或增加耗时。';
      }
      return text.isEmpty
          ? '命令执行完成（无输出），退出码 $exitCode'
          : '退出码 $exitCode\n$text';
    } on ProcessException catch (e) {
      return '终端执行异常: ${e.message}';
    }
  }

  Future<String> _execFileWrite(Map<String, dynamic> args) async {
    final wPath = (args['path'] ?? '').toString().trim();
    final content = (args['content'] ?? '').toString();
    if (wPath.isEmpty) return '写入失败：path 为空';
    try {
      final resolved = await _resolveToolPath(wPath);
      if (resolved == null) return '写入失败：路径无效';
      final f = File(resolved);
      await f.create(recursive: true);
      await f.writeAsString(content, flush: true);
      return '已写入 $resolved（${content.length} 字符）';
    } catch (e) {
      return '写入失败: $e';
    }
  }

  Future<String> _execFileRead(Map<String, dynamic> args) async {
    final rPath = (args['path'] ?? '').toString().trim();
    if (rPath.isEmpty) return '读取失败：path 为空';
    try {
      final resolved = await _resolveToolPath(rPath);
      final f = resolved == null ? null : File(resolved);
      if (f == null || !f.existsSync()) return '文件不存在：$rPath';
      if (await f.length() > 200 * 1024) {
        return '文件过大（>200KB），请用 run_terminal 分段读取';
      }
      return await f.readAsString();
    } catch (e) {
      return '读取失败: $e';
    }
  }

  Future<String> _execQuestion(Map<String, dynamic> args) async {
    final qText = (args['question'] ?? '').toString().trim();
    if (qText.isEmpty) return '问题为空';
    final opts = args['options'];
    final options = (opts is List && opts.isNotEmpty)
        ? opts.map((e) => e.toString()).take(4).toList()
        : const <String>['确认', '取消'];
    final completer = Completer<String>();
    pendingQuestion = {'question': qText, 'options': options};
    _questionCompleter = completer;
    notifyListeners();
    final answer = await completer.future;
    return '用户的选择：$answer';
  }

  Future<String> _execCreateSkill(Map<String, dynamic> args) async {
    final skillName = (args['name'] ?? '').toString().trim();
    final skillDesc = (args['description'] ?? '').toString().trim();
    final skillContent = (args['content'] ?? '').toString();
    if (skillName.isEmpty) return '创建失败：name 为空';
    final filesArg = args['files'];
    final filesMap = <String, String>{};
    if (filesArg is Map) {
      for (final e in filesArg.entries) {
        filesMap[e.key.toString()] = e.value.toString();
      }
    }
    try {
      final existing = await _db.getSkillByName(skillName);
      final skill = Skill(
        id: existing?.id ?? 0,
        name: skillName,
        description: skillDesc,
        content: skillContent,
        createdAt: existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        files: filesMap,
      );
      if (existing == null) {
        await _db.addSkill(skill);
      } else {
        await _db.updateSkill(skill);
      }
      skills = await _db.listSkills();
      notifyListeners();
      return existing == null ? '技能「$skillName」已创建' : '技能「$skillName」已更新';
    } catch (e) {
      return '技能保存失败: $e';
    }
  }

  Future<String> _execEnterPlanMode(Map<String, dynamic> args) async {
    if (planMode) return '已经在计划模式中';
    planMode = true;
    notifyListeners();
    return '已进入计划模式：接下来只能使用只读工具（搜索/读文件/读技能），'
        '请先输出完整方案，等待用户确认后再调用 exit_plan_mode 开始执行。';
  }

  Future<String> _execExitPlanMode(Map<String, dynamic> args) async {
    if (!planMode) return '当前不在计划模式';
    planMode = false;
    notifyListeners();
    return '已退出计划模式，恢复正常执行能力，开始执行方案。';
  }

  /// 按子代理白名单过滤出工具 JSON（子代理只能调白名单内的工具）。
  List<Map<String, dynamic>> _toolsJsonFor(Set<String> names) => [
    for (final t in toolRegistry)
      if (names.contains(t.name)) t.toJson(),
  ];

  /// 派发子代理：独立 LLM 对话 + 受限工具集，返回其最终文本报告。
  Future<String> _execSpawnAgent(Map<String, dynamic> args) async {
    final spawnSessionId = currentSessionId;
    final rawTasks = args['tasks'];
    final List<Map<String, dynamic>> tasks = <Map<String, dynamic>>[];
    if (rawTasks is List && rawTasks.isNotEmpty) {
      tasks.addAll(rawTasks.whereType<Map>().cast<Map<String, dynamic>>());
    } else {
      tasks.add(args);
    }
    const maxParallel = 4;
    if (tasks.length > maxParallel) {
      return '一次最多并行 $maxParallel 个子代理（当前 ${tasks.length} 个），请分批派发。';
    }
    for (final t in tasks) {
      final type = (t['agent_type'] ?? '').toString().trim();
      final prompt = (t['prompt'] ?? '').toString().trim();
      if (type.isEmpty || prompt.isEmpty) {
        return '派发失败：tasks 每项需含非空 agent_type 与 prompt。';
      }
    }
    // 动态预算：max_turns 覆盖定义默认值（1~80，硬顶防失控）。
    int? parseBudget(Map<String, dynamic> t) {
      final v = t['max_turns'];
      if (v == null) return null;
      final n = int.tryParse(v.toString());
      if (n == null || n < 1 || n > 80) {
        throw ArgumentError('max_turns 需为 1~80 的整数');
      }
      return n;
    }

    final total = tasks.length;
    var subagentTokens = 0;
    // 并发执行：每任务独立 try/catch，单个失败不影响其他（独立失败）。
    final results = await Future.wait(
      List.generate(total, (i) async {
        final t = tasks[i];
        final type = (t['agent_type'] ?? '').toString().trim();
        final prompt = (t['prompt'] ?? '').toString().trim();
        final def = SubagentDefinition.byName(type);
        if (def == null) {
          return '### 子代理 ${i + 1}/$total（$type）\n未知子代理类型：$type'
              '（可选 ${SubagentDefinition.all.map((d) => d.name).join(' / ')}）';
        }
        final int? override;
        try {
          override = parseBudget(t);
        } catch (e) {
          return '### 子代理 ${i + 1}/$total（$type）\n$e';
        }
        // 写路径隔离：声明 write_paths 后，file_write 只能写这些路径
        //（不声明 = 允许写整个工作区）。多个并行子代理声明不重叠路径即可放心并行。
        final workingDirAbs = await currentWorkspace();
        final rawWp = t['write_paths'];
        final List<String>? writePaths = rawWp is List
            ? rawWp
                  .map((e) => _normAbsPath(e.toString(), workingDirAbs))
                  .toList()
            : null;
        final runner = SubagentRunner(
          baseUrl: settings.baseUrl,
          apiKey: settings.apiKey,
          model: settings.model,
          temperature: settings.temperature,
          maxTokens: settings.maxOutputTokens,
          toolsJson: _toolsJsonFor(def.allowedTools),
          // 执行层二次校验（纵深防御：即使 Runner 被改坏，白名单外工具也到不了 _executeTool）。
          executeTool: (name, argsJson) async {
            if (!def.allowedTools.contains(name)) {
              return '工具 $name 不在本子代理白名单，已跳过；改用允许的工具。';
            }
            // 写路径隔离：file_write 目标必须在 write_paths 允许范围内。
            if (name == 'file_write' && writePaths != null) {
              Map<String, dynamic> a = {};
              try {
                a = jsonDecode(argsJson) as Map<String, dynamic>;
              } catch (_) {}
              final p = (a['path'] ?? '').toString();
              final target = _normAbsPath(p, workingDirAbs);
              final ok = writePaths.any(
                (w) => target == w || target.startsWith('$w/'),
              );
              if (!ok) {
                return '写入被拒绝：$p 不在本子代理允许的 write_paths 内'
                    '（允许：${writePaths.join('、')}）。'
                    '请把输出写到允许路径，或要求主代理调整 write_paths。';
              }
            }
            // 只读代理的终端调用做写操作拦截（提示词之外的技术兜底）。
            if (name == 'run_terminal' && def.readOnlyTerminal) {
              final denied = _rejectWriteCommand(argsJson);
              if (denied != null) return denied;
            }
            return _executeTool(name, argsJson);
          },
          workingDir: workingDirAbs,
          shouldStop: () => _stopRequested,
          // 进度回流：显示「第 i/N 个子代理 · 类型 · 第 n/m 轮 · 工具」。
          onProgress: (round, max, tool) {
            final t2 = tool.isEmpty ? '思考中' : '正在调用 $tool';
            status =
                '子代理 ${i + 1}/$total · ${def.name} · '
                '第 ${round + 1}/$max 轮 · $t2';
            notifyListeners();
          },
        );
        String report;
        try {
          report = await runner.run(def, prompt, maxTurnsOverride: override);
        } catch (e) {
          report = '（子代理异常：$e）';
        }
        if (runner.totalTokens > 0) subagentTokens += runner.totalTokens;
        return '### 子代理 ${i + 1}/$total（${def.name}）\n$report';
      }),
    );
    // 子代理消耗的 token 统一计入发起会话（与主循环一致，并入「本轮」）。
    if (subagentTokens > 0 && spawnSessionId != null) {
      final sessNow = await _db.getSession(spawnSessionId);
      final newTotal = (sessNow?.totalTokens ?? 0) + subagentTokens;
      await _db.updateSessionTokens(spawnSessionId, newTotal);
      if (currentSessionId == spawnSessionId) {
        sessionTotalTokens = newTotal;
        lastRoundTokens += subagentTokens;
      }
    }
    // 全部结束后清掉轮次状态条，避免残留「第 n/m 轮」。
    status = null;
    notifyListeners();
    return results.join('\n\n');
  }

  /// 归一路径为绝对路径（相对基于 baseDir），供 write_paths 隔离比较。
  static String _normAbsPath(String p, String baseDir) {
    var s = p.trim().replaceAll('\\', '/');
    if (s.isEmpty) return baseDir;
    final isAbs = s.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(s);
    final full = isAbs ? s : '$baseDir/$s';
    final segs = <String>[];
    for (final seg in full.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (segs.isNotEmpty) segs.removeLast();
      } else {
        segs.add(seg);
      }
    }
    return segs.join('/');
  }

  /// 只读代理的终端命令写操作拦截：命中写命令/重定向即拒绝。
  /// 保守策略——误伤只读命令可接受（子代理可换写法），漏放写操作不可接受。
  static String? _rejectWriteCommand(String argsJson) {
    String cmd;
    try {
      final parsed = jsonDecode(argsJson);
      cmd = ((parsed is Map) ? (parsed['command'] ?? '') : '').toString();
    } catch (_) {
      return null; // 参数解析失败交给 _executeTool 处理
    }
    final t = cmd.trim();
    if (t.isEmpty) return null;
    final lower = t.toLowerCase();
    // 写操作命令（单词边界匹配，避免误伤 find 等组合）
    final writeCmds = RegExp(
      r'(^|[;&|]\s*)(rm|mv|cp|mkdir|touch|chmod|chown|ln|dd|kill|pkill|'
      r'tee|wget|nano|vim|vi|apt|pkg|install|shutdown|reboot)(\s|$)',
    );
    // 输出重定向（> 或 >>，排除 2>&1 这类 fd 合并——那是只读用法）
    final redirect = RegExp(r'(^|[;&|]\s*)[12]?[>]{1,2}(?!&)\s*(\S|$)');
    if (writeCmds.hasMatch(lower)) {
      return '只读模式拒绝：命令含写操作（$t）；请改用 ls/find/grep/cat/head/tail/wc 等只读命令。';
    }
    if (redirect.hasMatch(t)) {
      return '只读模式拒绝：命令含输出重定向（$t）；直接看输出即可，不要写文件。';
    }
    return null;
  }

  /// 解析工具的文件路径：相对路径基于当前会话工作目录，绝对路径直接使用。
  Future<String?> _resolveToolPath(String path) async {
    final t = path.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(t)) return t;
    final base = await currentWorkspace();
    return '$base/$t';
  }

  // ---------------- 上下文压缩 ----------------

  /// 从 DB 重新加载当前会话的 token 统计与上下文估算（聊天页打开时调用）。
  Future<void> refreshTokenStats(String sessionId) async {
    final s = await _db.getSession(sessionId);
    if (s != null) sessionTotalTokens = s.totalTokens;
    await _updateContextStats(sessionId);
    notifyListeners();
  }

  /// 估算文本 token 数：中文约 1 token/字，英文/数字约 4 字符/token。
  static int _estimateTokens(String text) {
    var cjk = 0, other = 0;
    for (final r in text.runes) {
      if (r >= 0x4E00 && r <= 0x9FFF) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other / 4).ceil();
  }

  /// 估算单条 API 消息的 token 数（与发送口径一致：含 tool_calls，不含 reasoning）。
  static int estimateApiMessageTokens(Map<String, dynamic> m) {
    final c = m['content'];
    var total = 0;
    if (c is String) {
      total += _estimateTokens(c);
    } else if (c is List) {
      total += 400; // 多模态消息粗略按一段文本估算
    }
    final tcs = m['tool_calls'];
    if (tcs is List && tcs.isNotEmpty) {
      total += _estimateTokens(jsonEncode(tcs));
    }
    return total;
  }

  /// 估算会话下一轮请求的上下文大小（token）：
  /// 历史消息（含完整 tool 结果、不含流式占位；图片每张按约 1000 token 计入）
  /// + 系统提示词（含注入的记忆/技能）+ 工具定义开销。
  /// 工具结果压缩后由 _trimApiMessages 按实际 payload 再核算，这里用于触发
  /// 60%/75%/85% 的压缩与裁剪阈值。
  Future<int> sessionContextTokenEstimate(String sessionId) async {
    final msgs = _messagesLoadedForSessionId == sessionId
        ? messages
        : await _db.listMessages(sessionId);
    var total = 0;
    for (final m in msgs) {
      if (m.streaming) continue;
      total += _estimateTokens(m.content);
      if (m.role == 'assistant' && m.hasToolCalls) {
        final tc = m.toApiMap()['tool_calls'];
        if (tc is List && tc.isNotEmpty) {
          total += _estimateTokens(jsonEncode(tc));
        }
      }
      if (m.hasImages) {
        total += 1000 * extractImagePaths(m.content).length;
      }
    }
    final sys = await _buildSystemPrompt('');
    total += _estimateTokens(sys);
    total += _estimateTokens(jsonEncode(activeTools)); // 工具定义开销
    return total;
  }

  /// 手动压缩会话历史：把早期 60% 的消息总结成摘要并替换，
  /// 保留最近 40% 的完整消息。返回是否压缩成功。
  Future<bool> compressSession(String sessionId) async {
    if (settings.apiKey.isEmpty || settings.model.isEmpty) return false;
    final msgs = await _db.listMessages(sessionId);
    final keep = msgs.where((m) => !m.streaming).toList();
    if (keep.length < 6) return false;
    final compressCount = (keep.length * 0.6).floor();
    if (compressCount < 3) return false;
    final toCompress = keep.sublist(0, compressCount);
    final transcript = toCompress
        .where((m) => m.role != 'tool')
        .map((m) => '${m.role}: ${stripImageMarkers(m.content)}')
        .join('\n');
    if (transcript.trim().isEmpty) return false;
    final limited = transcript.length <= 12000
        ? transcript
        : transcript.substring(transcript.length - 12000);

    final client = LlmClient(
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      model: settings.model,
      temperature: 0.2,
      tools: const [],
    );
    final summary = await client.completeOne([
      {
        'role': 'system',
        'content':
            '你是对话摘要助手。把下面的对话历史压缩成一份简洁的中文摘要，'
            '保留关键事实、用户偏好、重要决定、未完成事项和当前状态，'
            '控制在 400 字以内，只输出摘要内容，不要解释。',
      },
      {'role': 'user', 'content': limited},
    ], temperature: 0.2);
    final clean = summary.trim();
    if (clean.isEmpty || clean == '【无】') return false;

    // 删除被压缩的旧消息，在最前插入摘要消息。
    await _db.deleteMessagesByIds(toCompress.map((m) => m.id).toList());
    final summaryMsg = ChatMessage(
      id: 'm${DateTime.now().millisecondsSinceEpoch}_${_rand()}',
      sessionId: sessionId,
      role: 'user',
      content: '【历史会话摘要】\n$clean',
      createdAt: toCompress.first.createdAt,
    );
    await _db.insertMessage(summaryMsg);
    messages = await _db.listMessages(sessionId);
    _bumpMessages();
    await _updateContextStats(sessionId);
    notifyListeners();
    return true;
  }

  /// 自动压缩：发送消息前检查上下文是否超过压缩阈值。
  Future<void> _maybeAutoCompress(String sessionId) async {
    if (!settings.autoCompress || settings.compressThresholdPercent <= 0) {
      return;
    }
    final tokens = await sessionContextTokenEstimate(sessionId);
    final threshold =
        settings.contextLimit * settings.compressThresholdPercent / 100;
    if (tokens > threshold) {
      await compressSession(sessionId);
    }
  }

  // ---------------- memories / skills ----------------

  /// 重建 memory/MEMORY.md 索引文件（app 文档目录下）。
  /// 一行一条：`- [标题](memory-<id>) — [类型] 摘要`，与常见 Agent 记忆索引格式一致。
  /// MEMORY.md 索引同构，便于人工翻阅与模型快速定位记忆。
  Future<void> _rebuildMemoryIndex() async {
    try {
      final all = await _db.listMemories();
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/memory/MEMORY.md');
      await f.create(recursive: true);
      final sb = StringBuffer('# MEMORY.md — 拾忆记忆索引\n\n');
      for (final m in all) {
        final t = m.content.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.isEmpty) continue;
        final title = _memoryTitle(t);
        final hook = t.length > 40 ? '${t.substring(0, 40)}…' : t;
        sb.writeln('- [$title](memory-${m.id}) — [${m.type}] $hook');
      }
      await f.writeAsString(sb.toString(), flush: true);
    } catch (_) {
      // 索引文件生成失败不影响主流程。
    }
  }

  /// 记忆标题：优先取内容中的 [[名称]]，否则取前 20 字。
  static String _memoryTitle(String content) {
    final link = RegExp(r'\[\[([^\]|]+)(?:\|[^\]]+)?\]\]').firstMatch(content);
    final raw = link?.group(1)?.trim() ?? '';
    if (raw.isNotEmpty) return raw;
    return content.length > 20 ? '${content.substring(0, 20)}…' : content;
  }

  /// 自动沉淀记忆：每轮对话结束后提炼重要信息存入长期记忆。
  /// 带熔断与限频，避免频繁调用 LLM。
  Future<void> _maybeAutoRefine(String sessionId) async {
    if (!settings.enableAutoLearn || !settings.enableMemory) return;
    if (settings.apiKey.isEmpty || settings.model.isEmpty) return;
    // 限频：每 5 分钟最多提炼一次，且最多连续 3 次无收获后熔断
    final now = DateTime.now();
    if (_lastRefine != null && now.difference(_lastRefine!).inSeconds < 300) {
      return;
    }
    if (_refineCount >= 3) return;

    try {
      final msgs = await _db.listMessages(sessionId);
      if (msgs.length < 6) return;
      final transcript = msgs
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .toList();
      final last = transcript.length <= 10
          ? transcript
          : transcript.sublist(transcript.length - 10);
      final transcript2 = last
          .map((m) => '${m.role}: ${stripImageMarkers(m.content)}')
          .join('\n');
      if (transcript2.trim().isEmpty) return;
      final limited = transcript2.length <= 6000
          ? transcript2
          : transcript2.substring(transcript2.length - 6000);

      // 已有记忆摘要（用于去重，避免重复保存）。
      final existing = memories
          .take(30)
          .map((m) => '- ${m.content}')
          .join('\n');

      final client = LlmClient(
        baseUrl: settings.baseUrl,
        apiKey: settings.apiKey,
        model: settings.model,
        temperature: 0.2,
        tools: const [],
      );
      final result = await client.completeOne([
        {
          'role': 'system',
          'content':
              '你是记忆提炼助手，只保留「真正值得跨会话长期记住」的信息。\n'
              '值得记：用户的稳定偏好与习惯、身份背景、长期目标、重要的决定与约定、'
              '需要复用的关键事实（如项目技术栈、部署环境、账号约定）。\n'
              '不记：一次性或临时性内容（今天做了什么、当前情绪、寒暄问候）、'
              '通用常识、随手提到但不会再用的细节。\n'
              '每行输出一条简洁的中文记忆（不含编号、不含引号），'
              '没有值得记的只输出【无】，不要解释，也不要与下方已有记忆重复。',
        },
        {
          'role': 'user',
          'content':
              '【已有记忆】\n${existing.isEmpty ? '（暂无）' : existing}\n\n【本次对话】\n$limited',
        },
      ], temperature: 0.2);

      final lines = result
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && l != '【无】' && l != '["无"]')
          .toList();
      if (lines.isEmpty) {
        _refineCount++;
        _lastRefine = now;
        return;
      }
      for (final line in lines) {
        await _db.addMemory(line, 'auto');
      }
      memories = await _db.listMemories();
      await _rebuildMemoryIndex();
      _refineCount = 0;
      _lastRefine = now;
      notifyListeners();
    } catch (_) {
      _refineCount++;
      _lastRefine = now;
    }
  }

  Future<void> addMemoryManual(String content) async {
    await _db.addMemory(content, 'manual');
    memories = await _db.listMemories();
    await _rebuildMemoryIndex();
    notifyListeners();
  }

  Future<void> deleteMemory(int id) async {
    await _db.deleteMemory(id);
    memories = await _db.listMemories();
    await _rebuildMemoryIndex();
    notifyListeners();
  }

  Future<List<MemoryEntry>> searchAllMemories(String q) async {
    if (q.trim().isEmpty) return memories;
    return _db.searchMemories(q.trim());
  }

  Future<void> saveSkill(Skill s) async {
    final existing = await _db.getSkillByName(s.name);
    if (existing != null && existing.id != s.id) {
      throw Exception('技能「${s.name}」已存在，请换一个名称');
    }
    if (s.id == 0) {
      await _db.addSkill(s);
    } else {
      await _db.updateSkill(s);
    }
    skills = await _db.listSkills();
    notifyListeners();
  }

  Future<void> deleteSkill(int id) async {
    Skill? skill;
    for (final s in skills) {
      if (s.id == id) {
        skill = s;
        break;
      }
    }
    await _db.deleteSkill(id);
    if (skill != null && skill.dirPath.isNotEmpty) {
      try {
        final dir = Directory(skill.dirPath);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    }
    skills = await _db.listSkills();
    notifyListeners();
  }

  /// 记录错误日志到智能体工作目录 logs/error.log，方便排查生成与工具错误。
  /// 终端 exec 失败时收集诊断信息（系统 sh 保证可执行），
  /// 用于定位「Permission denied」是 ROM/SELinux 策略还是权限/依赖问题。
  Future<String> _diagnoseTermuxExec(String shell) async {
    final buf = StringBuffer('--- 终端诊断 ---');
    try {
      final r = await Process.run('/system/bin/sh', [
        '-c',
        '''
B="\$1"
echo "[bash 路径] \$B"
echo "[bash 权限/context]"
ls -lZ "\$B" 2>&1
echo "[usr 目录 context]"
ls -ldZ "\$(dirname "\$B")/.." 2>&1
echo "[依赖库 libandroid-support]"
ls -lZ "\$(dirname "\$B")/../lib/libandroid-support.so" 2>&1 | head -1
echo "[SELinux]"
getenforce 2>&1
echo "[设备] android=\$(getprop ro.build.version.release) api=\$(getprop ro.build.version.sdk) brand=\$(getprop ro.product.brand) model=\$(getprop ro.product.model)"
echo "[直跑 bash]"
"\$B" -c 'echo bash-ok' 2>&1
echo "[rc=\$?]"
''',
        'diag',
        shell,
      ]).timeout(const Duration(seconds: 10));
      buf.write('\n${r.stdout}'.trimRight());
      final err = r.stderr.toString().trim();
      if (err.isNotEmpty) buf.write('\n[stderr] $err');
    } catch (e) {
      buf.write('\n[诊断命令执行失败] $e');
    }
    return buf.toString();
  }

  Future<void> _logError(String source, String message) async {
    try {
      final dir = await FileWorkspace.current();
      final file = File('$dir/logs/error.log');
      await file.create(recursive: true);
      final line = '[${DateTime.now().toIso8601String()}] [$source] $message\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写入失败不影响主流程。
    }
  }

  static String _fmtBytes(int n) {
    if (n >= 1024 * 1024 * 1024) {
      return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '$n B';
  }

  Future<void> updateSettings(AppSettings s) async {
    if (s.model != settings.model) _knownImageUnsupported = false;
    if (s.model != settings.model ||
        s.visionEnabled != settings.visionEnabled ||
        s.visionModel != settings.visionModel) {
      _imageDescCache.clear();
    }
    settings = s;
    await _settingsService.save(s);
    notifyListeners();
  }
}

int _rand() => DateTime.now().microsecondsSinceEpoch;
