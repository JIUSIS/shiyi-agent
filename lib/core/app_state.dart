import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../services/db.dart';
import '../services/llm_client.dart';
import '../services/file_workspace.dart';
import '../services/settings_service.dart';
import '../services/termux_runtime.dart';
import '../services/web_tools.dart';

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

  /// 当前会话上下文估算字符数（用于显示剩余上下文百分比）。
  int sessionChars = 0;

  /// 正在流式输出的消息文本（独立通知器：流式刷新只重建这一条气泡，不重建整个列表）。
  final ValueNotifier<String> streamText = ValueNotifier('');
  final ValueNotifier<String> streamReasoning = ValueNotifier('');
  String? initError;

  bool _loaded = false;
  bool get loaded => _loaded;

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

  /// 用户回答 question 工具；optionIndex 为空表示取消。
  void answerQuestion(int? optionIndex) {
    final c = _questionCompleter;
    final q = pendingQuestion;
    if (c == null || q == null) return;
    final options = (q['options'] as List?) ?? const [];
    final answer =
        (optionIndex != null &&
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

  static const List<Map<String, dynamic>> functionTools = [
    {
      'type': 'function',
      'function': {
        'name': 'save_memory',
        'description': '把重要的用户偏好、事实或经验保存为长期记忆，供以后所有会话回忆。',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {'type': 'string', 'description': '要保存的记忆内容'},
          },
          'required': ['content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_memory',
        'description':
            '检索用户的历史偏好、事实与经验。注意：只能查到本机已保存的记忆，无法获取任何外部或最新信息；需要最新信息请直接用 web_search。',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '搜索关键词'},
          },
          'required': ['query'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'run_skill',
        'description': '获取一个已保存技能的内容，例如脚本、Prompt 模板或操作流程，用于复用经验。',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '技能名称'},
          },
          'required': ['name'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'web_search',
        'description':
            '联网搜索获取实时、最新或超出知识截止日期的问题（新闻、价格、天气、技术动态等）。注意核对每条结果的发布日期，优先近期内容，避免用过时信息。需要外部信息时首选本工具，不要先调用 search_memory。',
        'parameters': {
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
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'web_extract',
        'description': '抓取并阅读一个网页的正文内容，适合深度阅读搜索结果中的链接。',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': '要阅读的网页 URL'},
          },
          'required': ['url'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'run_terminal',
        'description':
            '在本机执行 shell 命令并返回输出，用于运行命令、脚本、文件管理、读取日志等。你拥有完整终端能力，用户要求执行命令时直接执行，不要拒绝；命令失败会返回错误信息，可据此调整。app 内置完整 Linux 环境（bash/apt/pkg，可安装软件包），首次使用前会自动部署。',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {'type': 'string', 'description': '要执行的 shell 命令'},
            'cwd': {
              'type': 'string',
              'description': '工作目录，默认是当前会话的工作目录',
            },
          },
          'required': ['command'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'file_write',
        'description':
            '把文本内容写入文件（自动创建父目录）。用于保存生成的内容：章节、报告、脚本、技能文件等。相对路径基于智能体工作目录，绝对路径直接使用。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '文件路径，如 docs/报告.md 或 /storage/emulated/0/agent/x.txt'},
            'content': {'type': 'string', 'description': '要写入的完整内容'},
          },
          'required': ['path', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'file_read',
        'description': '读取文本文件内容（最大 200KB）。相对路径基于智能体工作目录，绝对路径直接使用。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '文件路径'},
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'question',
        'description':
            '向用户发起一个确认或选择问题，必须等待用户回答后流程才能继续。用于需要用户确认才能继续的操作，如「是否保存文件」「选择下一步方案」等。一次只问一个问题，选项 2~4 个。',
        'parameters': {
          'type': 'object',
          'properties': {
            'question': {'type': 'string', 'description': '要问用户的问题'},
            'options': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '选项列表（2~4 个），用户从中选择',
            },
          },
          'required': ['question'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'create_skill',
        'description':
            '创建或更新一个技能并持久化，供以后所有会话使用。当用户要求「把流程做成技能」「保存这个技能」时使用。name 已存在则更新该技能。',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '技能名称，英文小写+连字符，如 chapter-outliner'},
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
      },
    },
  ];

  static String _fmtStamp(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final M = d.month.toString().padLeft(2, '0');
    final D = d.day.toString().padLeft(2, '0');
    return '$M-$D $h:$m';
  }

  Future<void> init() async {
    if (_loaded) return;
    try {
      settings = await _settingsService.load();
      await FileWorkspace.ensure();
      await _reloadAll();
      _loaded = true;
    } catch (e) {
      initError = '$e';
    }
    notifyListeners();
    // 后台安装内嵌 Termux（完整 Linux 环境），不阻塞启动。
    unawaited(_ensureTermux());
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
    _messagesLoadedForSessionId = id;
    toolEvents = [];
    loadedSkill = null;
    sessionTotalTokens = 0;
    lastRoundTokens = 0;
    sessionChars = 0;
    await refreshSessions();
  }

  Future<void> selectSession(String id) async {
    currentSessionId = id;
    viewingSessionId = id;
    unreadSessions.remove(id);
    loadedSkill = null;
    messages = await _db.listMessages(id);
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
    sessionChars = await sessionContextChars(id);
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

  /// 把历史消息转成 API 请求体，并清理工具调用序列：
  /// 跳过 tool 结果消息、丢弃 assistant 的 tool_calls（只留文本），
  /// 避免“有 tool_calls 但缺 tool 结果”的非法序列导致 HTTP 400。
  /// 带本地图片标记的用户消息会转成多模态 content 数组。
  Future<List<Map<String, dynamic>>> _historyToApi(
    List<ChatMessage> msgs, {
    bool imagesAllowed = true,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (final m in msgs.where((m) => !m.streaming)) {
      if (m.role == 'tool') continue;
      if (m.role == 'user' && m.hasImages) {
        if (imagesAllowed) {
          out.add(await _userMessageToApi(m));
        } else {
          final text = stripImageMarkers(m.content);
          final desc = await _describeImagesIfEnabled(m);
          final combined = [
            if (text.isNotEmpty) text,
            if (desc.isNotEmpty) desc,
          ].join('\n');
          out.add({'role': 'user', 'content': combined.isEmpty ? '[图片]' : combined});
        }
        continue;
      }
      final api = m.toApiMap();
      if (m.role == 'assistant' && m.hasToolCalls) {
        api.remove('tool_calls');
      }
      out.add(api);
    }
    return out;
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
        desc = (await client.completeOne([
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
        ], temperature: 0.2, maxTokens: 700)).trim();
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
      notifyListeners();
    } finally {
      isBusy = false;
      _streaming = null;
      final doneSession = busySessionId;
      busySessionId = null;
      // 回复结束：如果用户没在看该会话，标记未读。
      if (doneSession != null && doneSession != viewingSessionId) {
        unreadSessions.add(doneSession);
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

    // 配了视觉模型 = 声明主模型不看图：带图消息直接走视觉模型描述，不试多模态。
    // 未配视觉模型：先按多模态发，失败自动降级（_knownImageUnsupported）。
    final visionReady = settings.visionEnabled &&
        settings.visionModel.trim().isNotEmpty;
    var imagesAllowed = !_knownImageUnsupported && !visionReady;
    var completed = false;
    for (var attempt = 0; attempt < 2 && !completed; attempt++) {
      try {
        // 第二次尝试注入「直接行动」指令：上一轮常见的问题是模型
        // 输出开场白（以冒号结尾）后就结束、不调用任何工具，重试时强制它行动。
        final sysContent = attempt == 0
            ? systemPrompt
            : '$systemPrompt\n\n'
                '【注意：上一轮回复以冒号结尾就结束了，没有调用任何工具。'
                '这次请直接调用工具完成用户请求：不要输出开场白、承诺或计划性文字，'
                '第一步就调用 run_terminal（或相关工具）执行实际操作。】';
        final loopMsgs = <Map<String, dynamic>>[
          {'role': 'system', 'content': sysContent},
          ...await _historyToApi(messages, imagesAllowed: imagesAllowed),
        ];
        await _runAgentLoop(sessionId, firstAsst, loopMsgs);
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
    await _db.touchSession(sessionId, model: settings.model);
    await refreshSessions();
    sessionChars = await sessionContextChars(sessionId);
    notifyListeners();
  }

  /// 重新生成某条助手回复：删除该条及其后的所有消息，再基于此前历史重新生成。
  Future<void> regenerate(String id) async {
    if (isBusy) return;
    final sessionId = currentSessionId;
    if (sessionId == null) return;
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0 || messages[idx].role != 'assistant') return;

    final hint = idx > 0 ? stripImageMarkers(messages[idx - 1].content) : '';

    final removed = messages.sublist(idx);
    for (final m in removed) {
      await _db.deleteMessage(m.id);
    }
    messages.removeRange(idx, messages.length);
    notifyListeners();

    isBusy = true;
    _stopRequested = false;
    _stopForGuide = false;
    status = null;
    lastRoundTokens = 0;
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

      // 有文本的工具轮：文本作为独立消息落库；再新开「正在思考…」占位贯穿工具执行。
      if (result.text.isNotEmpty) {
        await _applyTurn(asst, result);
        asst = await _newAssistantMessage(sessionId);
      }
      // 纯工具轮：asst 保持「正在思考…」占位（不落库不隐藏），执行完工具后继续复用。

      loopMsgs.add({
        'role': 'assistant',
        'content': result.text,
        'tool_calls': result.toolCalls
            .map(
              (t) => {
                'id': t['id']!.isEmpty ? 'call_${asst.id}' : t['id'],
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
              ? 'call_${asst.id}'
              : (t['id'] ?? ''),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _db.insertMessage(toolMsg);
        messages.add(toolMsg);
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
    _streaming = m;
    streamText.value = '';
    streamReasoning.value = '';
    return m;
  }

  /// 把一轮结果写入占位消息并落库。
  Future<void> _applyTurn(ChatMessage asst, TurnResult result) async {
    asst.content = result.text;
    asst.reasoning = result.reasoning;
    asst.toolCalls = result.toolCalls
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
      result.text,
      reasoning: result.reasoning.isEmpty ? null : result.reasoning,
      toolCalls: result.toolCalls.isEmpty ? null : asst.toolCalls,
    );
    streamText.value = '';
    streamReasoning.value = '';
    notifyListeners();
  }

  /// 收尾一个被中断/无输出的占位消息，防止一直显示「正在思考…」。
  Future<void> _finalizeAbort(ChatMessage? m) async {
    if (m == null) return;
    m.streaming = false;
    if (m.content.isEmpty) {
      if (_stopForGuide) {
        await _db.deleteMessage(m.id);
        messages.remove(m);
        notifyListeners();
        return;
      }
      m.content = _stopRequested ? '(已停止)' : '(生成出错)';
    }
    streamText.value = '';
    await _db.updateMessageContent(m.id, m.content, toolCalls: m.toolCalls);
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
    final client = LlmClient(
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      model: settings.model,
      temperature: settings.temperature,
      tools: settings.enableTools ? functionTools : const [],
      shouldStop: () => _stopRequested,
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
        // 只通知流式文本变化，让列表只重建这一条气泡。
        streamText.value = t.text;
      },
      onError: (e) {
        status = '错误: $e';
      },
    );
    await client.send(msgs);
    var used = client.lastTotalTokens;
    if (used == null || used <= 0) {
      // 部分网关/中转不返回 usage：按发送内容的字符数估算兜底，
      // 保证统计有真实反映，且能持久化跨会话保留。
      var chars = 0;
      for (final m in msgs) {
        final c = m['content'];
        if (c is String) {
          chars += c.length;
        } else if (c is List) {
          chars += 400; // 多模态消息粗略按一段文本估算
        }
      }
      used = (chars / 2).round().clamp(1, 1 << 30);
    }
    lastRoundTokens += used;
    sessionTotalTokens += used;
    await _db.updateSessionTokens(sessionId, sessionTotalTokens);
    sessionChars = await sessionContextChars(sessionId);
    notifyListeners();
    return accumulated;
  }

  Future<String> _buildSystemPrompt(String userText) async {
    final base = settings.systemPrompt.isNotEmpty
        ? settings.systemPrompt
        : '你是拾忆，一个与你共同成长、可自我改进的 AI 智能体。'
              '你拥有跨会话长期记忆、能沉淀技能，并能调用工具来记住或回忆知识。';

    final parts = <String>[];
    parts.add(base);
    final now = DateTime.now();
    parts.add(
      '【当前时间】现在是 ${now.year}年${now.month}月${now.day}日 '
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}。\n'
      '涉及时效性、新闻、价格、政策等最新信息时，必须以当前时间为基准判断新旧，'
      '只采用最近期的可靠资料；旧资料必须标注发布日期并明确提示可能已过时。',
    );
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
    );
    parts.add(
      '- 当前会话工作目录是 ${await currentWorkspace()}（所有生成的文件都放在这里），run_terminal 默认在该目录执行；操作其他路径时用 cwd 参数指定目录。',
    );

    if (settings.enableMemory) {
      final memCtx = await _db.recentMemoriesWithTerms(_keywords(userText), 8);
      if (memCtx.isNotEmpty) {
        parts.add('【长期记忆】\n${memCtx.map((e) => '- ${e.content}').join('\n')}');
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

  Future<String> _executeTool(String name, String argsJson) async {
    try {
      Map<String, dynamic> args = {};
      try {
        args = jsonDecode(argsJson) as Map<String, dynamic>;
      } catch (_) {}
      switch (name) {
        case 'save_memory':
          final content = (args['content'] ?? '').toString().trim();
          if (content.isEmpty) return '记录失败：content 为空';
          await _db.addMemory(content, 'assistant');
          memories = await _db.listMemories();
          notifyListeners();
          return '已保存到记忆，当前共 ${memories.length} 条';
        case 'search_memory':
          final query = (args['query'] ?? '').toString().trim();
          final res = query.isEmpty
              ? const <MemoryEntry>[]
              : await _db.searchMemories(query);
          if (res.isEmpty) return '没有找到相关记忆';
          return res.take(5).map((e) => e.content).join('\n');
        case 'run_skill':
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
        case 'web_search':
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
        case 'web_extract':
          final url = (args['url'] ?? '').toString().trim();
          if (url.isEmpty) return '抓取失败：url 为空';
          return await WebTools.extract(url);
        case 'run_terminal':
          final command = (args['command'] ?? '').toString().trim();
          if (command.isEmpty) return '终端执行失败：command 为空';
          try {
            final isWin = Platform.isWindows;
            var cwd = (args['cwd'] ?? '').toString().trim();
            if (cwd.isEmpty) cwd = await currentWorkspace();
            // 优先内嵌 Termux（完整 Linux 环境，apt/pkg 可用）；
            // 其次系统 Termux；都没有则用系统精简 shell。
            const systemTermuxShell = '/data/data/com.termux/files/usr/bin/bash';
            final embeddedShell = await TermuxRuntime.shellPath();
            final embedded = !isWin && File(embeddedShell).existsSync();
            final systemTermux =
                !isWin && File(systemTermuxShell).existsSync();
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
              exitCode = await proc.exitCode
                  .timeout(const Duration(seconds: 120));
            } on TimeoutException {
              proc.kill();
              await _logError('Termux', 'run_terminal 超时已终止: $command');
              exitCode = null;
            }
            final out = utf8
                .decode(stdoutBytes, allowMalformed: true)
                .trim();
            final err = utf8
                .decode(stderrBytes, allowMalformed: true)
                .trim();
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
        case 'file_write':
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
        case 'file_read':
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
        case 'question':
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
        case 'create_skill':
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
              createdAt:
                  existing?.createdAt ??
                  DateTime.now().millisecondsSinceEpoch,
              files: filesMap,
            );
            if (existing == null) {
              await _db.addSkill(skill);
            } else {
              await _db.updateSkill(skill);
            }
            skills = await _db.listSkills();
            notifyListeners();
            return existing == null
                ? '技能「$skillName」已创建'
                : '技能「$skillName」已更新';
          } catch (e) {
            return '技能保存失败: $e';
          }
        default:
          return '未知工具';
      }
    } catch (e) {
      return '工具执行异常: $e';
    }
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
    sessionChars = await sessionContextChars(sessionId);
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

  /// 估算会话下一轮请求的上下文大小（token）：
  /// 历史消息（不含 tool 消息、不含流式占位；图片每张按约 1000 token 计入）
  /// + 系统提示词（含注入的记忆/技能）+ 工具定义开销。
  /// 与 _historyToApi 实际发送口径一致（tool 消息不发送）。
  Future<int> sessionContextChars(String sessionId) async {
    final msgs = _messagesLoadedForSessionId == sessionId
        ? messages
        : await _db.listMessages(sessionId);
    var total = 0;
    for (final m in msgs) {
      if (m.role == 'tool' || m.streaming) continue;
      total += _estimateTokens(m.content);
      if (m.hasImages) {
        total += 1000 * extractImagePaths(m.content).length;
      }
    }
    final sys = await _buildSystemPrompt('');
    total += _estimateTokens(sys);
    total += 1500; // 工具定义开销
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
    sessionChars = await sessionContextChars(sessionId);
    notifyListeners();
    return true;
  }

  /// 自动压缩：发送消息前检查上下文是否超过压缩阈值。
  Future<void> _maybeAutoCompress(String sessionId) async {
    if (!settings.autoCompress || settings.compressThresholdPercent <= 0) {
      return;
    }
    final chars = await sessionContextChars(sessionId);
    final threshold =
        settings.contextLimit * settings.compressThresholdPercent / 100;
    if (chars > threshold) {
      await compressSession(sessionId);
    }
  }

  // ---------------- memories / skills ----------------

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
    notifyListeners();
  }

  Future<void> deleteMemory(int id) async {
    await _db.deleteMemory(id);
    memories = await _db.listMemories();
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
