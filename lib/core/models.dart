import 'dart:convert';

/// OpenAI 兼容自定义接口地址规范化：结尾没有版本段时自动补 /v1。
String normalizeOpenAiBaseUrl(String url) {
  var u = url.trim().replaceAll(RegExp(r'/+$'), '');
  if (u.isEmpty) return u;
  if (RegExp(r'/v\d+([a-z]*)$', caseSensitive: false).hasMatch(u)) return u;
  return '$u/v1';
}

/// 一次工具调用的信息流条目（按会话持久化）。
class ToolEvent {
  int? id;
  final String name;
  final String argsSummary;
  final int startedAt;
  bool done;
  bool ok;
  String? summary;
  int? finishedAt;

  ToolEvent({
    this.id,
    required this.name,
    required this.argsSummary,
    required this.startedAt,
    this.done = false,
    this.ok = false,
    this.summary,
    this.finishedAt,
  });

  int? get durationMs => finishedAt == null ? null : finishedAt! - startedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'args_summary': argsSummary,
    'summary': summary,
    'ok': ok ? 1 : 0,
    'started_at': startedAt,
    'finished_at': finishedAt,
  };

  factory ToolEvent.fromMap(Map<String, dynamic> m) => ToolEvent(
    id: m['id'] as int?,
    name: m['name'] ?? '',
    argsSummary: m['args_summary'] ?? '',
    startedAt: m['started_at'] ?? 0,
    done: (m['finished_at'] != null),
    ok: (m['ok'] ?? 0) == 1,
    summary: m['summary'] as String?,
    finishedAt: m['finished_at'] as int?,
  );
}

class Session {
  String id;
  String title;
  String model;

  /// 本会话绑定的已保存配置名（[ApiProfile.name]）。空 = 跟随全局设置。
  String apiProfile;
  int createdAt;
  int updatedAt;
  int messageCount;
  int totalTokens;

  /// 所属项目 id；空 = 未分类。
  String projectId;

  /// 最近一次请求由服务端真实返回的 total_tokens（含输入+输出）。
  /// 作为会话“当前上下文占用”的基线；null = 还没有真实 usage。
  int? lastUsageTotalTokens;

  /// 会话级滚动任务摘要：上下文压缩时生成，后续请求注入系统提示。
  String rollingSummary;

  /// 会话级项目工作目录（空 = 用全局默认工作目录）。
  String workspaceDir;

  /// 本会话累计的缓存命中 token（Σ 服务端返回的缓存输入）。
  /// 与 [cacheInputTokens] 配对持久化：退出会话再进入/重启后仍显示
  /// 整个会话的缓存命中率（口径同 DSH 的 durable log）。
  int cacheHitTokens;

  /// 本会话累计的输入 token（Σ 每次请求的 prompt 输入，仅统计
  /// 服务端明确返回缓存字段的请求；与 [cacheHitTokens] 同分母）。
  int cacheInputTokens;

  Session({
    required this.id,
    required this.title,
    required this.model,
    this.apiProfile = '',
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
    this.totalTokens = 0,
    this.projectId = '',
    this.lastUsageTotalTokens,
    this.rollingSummary = '',
    this.workspaceDir = '',
    this.cacheHitTokens = 0,
    this.cacheInputTokens = 0,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'model': model,
    'api_profile': apiProfile,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'total_tokens': totalTokens,
    'project_id': projectId,
    'last_usage_total_tokens': lastUsageTotalTokens,
    'rolling_summary': rollingSummary,
    'workspace_dir': workspaceDir,
    'cache_hit_tokens': cacheHitTokens,
    'cache_input_tokens': cacheInputTokens,
  };

  factory Session.fromMap(Map<String, dynamic> m) => Session(
    id: m['id'],
    title: m['title'],
    model: m['model'],
    apiProfile: m['api_profile'] == null ? '' : '${m['api_profile']}',
    createdAt: m['created_at'],
    updatedAt: m['updated_at'],
    messageCount: m['message_count'] == null
        ? 0
        : int.tryParse('${m['message_count']}') ?? 0,
    totalTokens: m['total_tokens'] == null
        ? 0
        : int.tryParse('${m['total_tokens']}') ?? 0,
    projectId: m['project_id'] == null ? '' : '${m['project_id']}',
    lastUsageTotalTokens: m['last_usage_total_tokens'] == null
        ? null
        : int.tryParse('${m['last_usage_total_tokens']}'),
    rollingSummary: m['rolling_summary'] == null
        ? ''
        : '${m['rolling_summary']}',
    workspaceDir: m['workspace_dir'] == null ? '' : '${m['workspace_dir']}',
    cacheHitTokens: m['cache_hit_tokens'] == null
        ? 0
        : int.tryParse('${m['cache_hit_tokens']}') ?? 0,
    cacheInputTokens: m['cache_input_tokens'] == null
        ? 0
        : int.tryParse('${m['cache_input_tokens']}') ?? 0,
  );
}

/// 会话项目分组：一个项目可挂多个会话，未分类会话的 projectId 为空。
class Project {
  String id;
  String name;
  int createdAt;
  int sessionCount;

  /// 项目级工作目录：未单独设置目录的会话自动使用它。
  String workspaceDir;

  Project({
    required this.id,
    required this.name,
    required this.createdAt,
    this.sessionCount = 0,
    this.workspaceDir = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'created_at': createdAt,
    'workspace_dir': workspaceDir,
  };

  factory Project.fromMap(Map<String, dynamic> m) => Project(
    id: m['id'],
    name: m['name'],
    createdAt: m['created_at'],
    sessionCount: m['session_count'] == null
        ? 0
        : int.tryParse('${m['session_count']}') ?? 0,
    workspaceDir: m['workspace_dir'] == null ? '' : '${m['workspace_dir']}',
  );
}

/// 会话搜索结果：会话 + 命中的消息片段（仅标题命中时片段为空）。
class SessionSearchResult {
  final Session session;
  final String snippet;
  const SessionSearchResult({required this.session, this.snippet = ''});
}

class ToolCall {
  String id;
  String name;
  String arguments; // raw JSON string

  ToolCall({required this.id, required this.name, required this.arguments});

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };
  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
    id: j['id'] ?? '',
    name: j['name'] ?? '',
    arguments: j['arguments'] ?? '',
  );
}

/// 消息中的本地图片标记，格式：![图片](本地路径)
const String imageMarker = '图片';
final RegExp imageMarkerRegExp = RegExp(r'!\[图片\]\(([^)]+)\)');

/// 提取消息内容里所有本地图片路径（按出现顺序）。
List<String> extractImagePaths(String content) => imageMarkerRegExp
    .allMatches(content)
    .map((m) => m.group(1)!.trim())
    .toList();

/// 去掉图片标记，只留纯文本。
String stripImageMarkers(String content) =>
    content.replaceAll(imageMarkerRegExp, '').trim();

/// 正文里拆出的思考块。部分网关不走 reasoning_content，只在 content 里写 think 标签。
class ThinkSplit {
  final String text;
  final String reasoning;
  const ThinkSplit(this.text, this.reasoning);
}

final _thinkOpen = RegExp(r'<think(?:ing)?>', caseSensitive: false);
final _thinkClose = RegExp(r'</think(?:ing)?>', caseSensitive: false);

/// 把正文里的 think 标签拆成可见文本和思考。未闭合标签按思考处理；
/// 末尾半截 <th 先留着，等下一片 delta。
ThinkSplit splitThinkTags(String raw) {
  if (raw.isEmpty) return const ThinkSplit('', '');
  if (!_thinkOpen.hasMatch(raw) && !raw.contains('<')) {
    return ThinkSplit(raw, '');
  }
  final text = StringBuffer();
  final reasoning = StringBuffer();
  var i = 0;
  var inThink = false;
  while (i < raw.length) {
    final rest = raw.substring(i);
    if (!inThink) {
      final open = _thinkOpen.firstMatch(rest);
      if (open == null) {
        final hold = _incompleteThinkOpenAt(rest);
        text.write(hold == null ? rest : rest.substring(0, hold));
        break;
      }
      text.write(rest.substring(0, open.start));
      i += open.end;
      inThink = true;
      continue;
    }
    final close = _thinkClose.firstMatch(rest);
    if (close == null) {
      reasoning.write(rest);
      break;
    }
    reasoning.write(rest.substring(0, close.start));
    i += close.end;
    inThink = false;
  }
  return ThinkSplit(text.toString(), reasoning.toString());
}

int? _incompleteThinkOpenAt(String rest) {
  final lt = rest.lastIndexOf('<');
  if (lt < 0) return null;
  final frag = rest.substring(lt + 1).toLowerCase();
  if (frag.isEmpty ||
      'think>'.startsWith(frag) ||
      'thinking>'.startsWith(frag) ||
      '/think>'.startsWith(frag) ||
      '/thinking>'.startsWith(frag)) {
    return lt;
  }
  return null;
}

/// 合并两路思考：字段流和 think 标签。已包含的片段不重复追加。
String mergeReasoning(String current, String incoming) {
  if (incoming.isEmpty) return current;
  if (current.isEmpty || incoming == current) return incoming;
  if (incoming.startsWith(current)) return incoming;
  if (current.startsWith(incoming) || current.endsWith(incoming)) {
    return current;
  }
  return current + incoming;
}

class ChatMessage {
  String id;
  String sessionId;
  String role; // user | assistant | system | tool
  String content;
  String reasoning; // 模型思考内容（reasoning_content，如 DeepSeek R1）
  List<ToolCall> toolCalls;
  String toolCallId; // for tool results
  int createdAt;
  bool streaming;
  bool archived;

  /// DSH 官方 runtime-context 快照。只给 UI 折叠展示，不入库、不回传模型。
  String runtimeContext;

  /// DSH 子代理结果的主模型总结。仅缓存展示，不回传模型。
  String subagentSummary;

  /// 拾忆子代理返回给主模型的原始报告。只在助手气泡折叠展示，
  /// 落库但不进入 [toApiMap]，避免在模型上下文里重复工具结果。
  String subagentResult;

  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content = '',
    this.reasoning = '',
    List<ToolCall>? toolCalls,
    this.toolCallId = '',
    required this.createdAt,
    this.streaming = false,
    this.archived = false,
    this.runtimeContext = '',
    this.subagentSummary = '',
    this.subagentResult = '',
  }) : toolCalls = toolCalls ?? [];

  bool get hasToolCalls => toolCalls.isNotEmpty;
  bool get hasImages => extractImagePaths(content).isNotEmpty;

  Map<String, dynamic> toMap() => {
    'id': id,
    'session_id': sessionId,
    'role': role,
    'content': content,
    'reasoning': reasoning,
    'subagent_result': subagentResult,
    'tool_calls': jsonEncode(toolCalls.map((t) => t.toJson()).toList()),
    'tool_call_id': toolCallId,
    'created_at': createdAt,
    'archived': archived ? 1 : 0,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> m) {
    final toolCalls = (m['tool_calls'] == null || m['tool_calls'] == '')
        ? <ToolCall>[]
        : (jsonDecode(m['tool_calls'] as String) as List)
              .map((e) => ToolCall.fromJson(e))
              .toList();
    final rawContent = (m['content'] ?? '').toString();
    final rawReasoning = (m['reasoning'] ?? '').toString();
    // 部分网关在模型「不思考直接回复」时，会把最终回复同时放进
    // reasoning_content；正文为空或与思考文本重复时按正文读取，
    // 避免旧数据一直显示成思考过程。
    final sameText =
        rawReasoning.replaceAll(RegExp(r'\s+'), '') ==
        rawContent.replaceAll(RegExp(r'\s+'), '');
    final misplacedReply =
        m['role'] == 'assistant' &&
        rawReasoning.isNotEmpty &&
        toolCalls.isEmpty &&
        (rawContent.trim().isEmpty || sameText);
    return ChatMessage(
      // 脏数据兜底（迁移/损坏库读出 null 或错误类型时取默认，不抛异常）：
      // 与 Session/MemoryEntry 的 tryParse 风格保持一致。
      id: (m['id'] ?? '').toString(),
      sessionId: (m['session_id'] ?? '').toString(),
      role: (m['role'] ?? 'user').toString(),
      content: misplacedReply && rawContent.trim().isEmpty
          ? rawReasoning
          : rawContent,
      reasoning: misplacedReply ? '' : rawReasoning,
      subagentResult: (m['subagent_result'] ?? '').toString(),
      toolCalls: toolCalls,
      toolCallId: (m['tool_call_id'] ?? '').toString(),
      createdAt: _toInt(m['created_at']),
      archived: _toInt(m['archived']) == 1,
    );
  }

  /// 数字字段脏数据兜底：num 直接取，数字字符串解析，其余取 0。
  static int _toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  Map<String, dynamic> toApiMap() {
    if (role == 'tool') {
      return {'role': 'tool', 'content': content, 'tool_call_id': toolCallId};
    }
    if (hasToolCalls) {
      return {
        'role': 'assistant',
        'content': content,
        if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
        'tool_calls': toolCalls
            .map(
              (t) => {
                'id': t.id.isEmpty ? 'call_$id' : t.id,
                'type': 'function',
                'function': {'name': t.name, 'arguments': t.arguments},
              },
            )
            .toList(),
      };
    }
    return {
      'role': role,
      'content': content,
      if (role == 'assistant' && reasoning.isNotEmpty)
        'reasoning_content': reasoning,
    };
  }
}

class MemoryEntry {
  int id;
  String content;
  String source;
  int createdAt;

  /// 记忆类型：user 用户身份/偏好 / feedback 工作方式指导 / project 项目信息 /
  /// reference 外部资源链接。默认 user。
  String type;

  MemoryEntry({
    required this.id,
    required this.content,
    required this.source,
    required this.createdAt,
    this.type = 'user',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'content': content,
    'source': source,
    'created_at': createdAt,
    'type': type,
  };

  factory MemoryEntry.fromMap(Map<String, dynamic> m) => MemoryEntry(
    id: m['id'],
    content: m['content'],
    source: m['source'] ?? '',
    createdAt: m['created_at'],
    type: m['type'] ?? 'user',
  );
}

class Skill {
  int id;
  String name;
  String description;
  String content;
  int createdAt;

  /// 文本辅助文件：路径（如 references/xxx.md）-> 内容（小文件，直接入库）。
  Map<String, String> files;

  /// 大文件：路径 -> 大小（字节）。内容留在磁盘目录 dirPath 中，不入库。
  Map<String, int> largeFiles;

  /// 技能包的磁盘目录（导入 zip 时的解压目录，可能为空）。
  String dirPath;

  Skill({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    required this.createdAt,
    this.files = const {},
    this.largeFiles = const {},
    this.dirPath = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'description': description,
    'content': content,
    'created_at': createdAt,
    'files': jsonEncode(files),
    'large_files': jsonEncode(largeFiles),
    'dir_path': dirPath,
  };

  factory Skill.fromMap(Map<String, dynamic> m) => Skill(
    id: m['id'],
    name: m['name'],
    description: m['description'] ?? '',
    content: m['content'] ?? '',
    createdAt: m['created_at'],
    files: _decodeFiles(m['files']),
    largeFiles: _decodeLargeFiles(m['large_files']),
    dirPath: m['dir_path'] ?? '',
  );

  static Map<String, String> _decodeFiles(dynamic v) {
    if (v is! String || v.isEmpty) return const {};
    try {
      final d = jsonDecode(v);
      if (d is Map) {
        return d.map((k, val) => MapEntry(k.toString(), val.toString()));
      }
    } catch (_) {}
    return const {};
  }

  static Map<String, int> _decodeLargeFiles(dynamic v) {
    if (v is! String || v.isEmpty) return const {};
    try {
      final d = jsonDecode(v);
      if (d is Map) {
        return d.map(
          (k, val) => MapEntry(k.toString(), int.tryParse('$val') ?? 0),
        );
      }
    } catch (_) {}
    return const {};
  }
}

class AppSettings {
  String baseUrl;
  String apiKey;
  String model;

  /// API 协议：openai（Chat Completions）或 anthropic（Messages API）。
  String apiProtocol;
  String systemPrompt;
  double temperature;
  bool enableTools;
  bool enableMemory;
  bool enableAutoLearn;
  bool ttsEnabled;
  double ttsRate;
  String themeMode; // light / dark / system

  /// 会话上下文上限（估算 token，默认 128k）。
  int contextLimit;

  /// 单次请求最大输出 token（思考型模型容易把预算花在推理上，默认 8192）。
  int maxOutputTokens;

  /// 上下文压缩阈值（占上下文上限的百分比，如 80 表示 80%）。
  double compressThresholdPercent;

  /// 达到压缩阈值时自动压缩。
  bool autoCompress;

  /// 视觉模型（辅助看图）：主模型不支持图片时，自动调用它描述图片。
  bool visionEnabled;
  String visionBaseUrl;
  String visionApiKey;
  String visionModel;

  /// 长任务完成时推送系统通知（app 在后台/切走时）。
  bool enableNotifications;

  /// 输入框按回车直接发送；关闭时回车换行。
  bool enterToSend;

  /// Windows 桌面终端后端：auto / pwsh / cmd / wsl2
  /// （Android 恒用内嵌 Alpine Linux，此设置不生效）。auto = WSL2 优先，
  /// 其次 PowerShell 7（pwsh），再回退 cmd。
  String terminalBackend;

  /// Agent 引擎：shiyi（拾忆本地引擎）/ dsh（DeepSeek Harness，经 HTTP API）。
  /// 切换后会话 tab 与聊天页走对应数据源；两套数据完全独立。
  String agentEngine;

  /// DSH 自动检查更新（默认开）：进入 DSH 模式时检测 npm 最新版，
  /// 发现新版弹提示由用户选择更新或暂不。
  bool dshAutoCheckUpdate;

  /// DSH 安装/更新自动使用代理（默认开）：检测系统代理或本地代理端口，
  /// npm 与 registry 请求走代理；无代理时直连 + 镜像兜底。
  bool dshUseProxy;

  /// 退出 App 时是否停止 DSH 服务（默认开）。关闭后退出 App / 进程销毁
  /// 不杀 dsh，重开 App 即用；切后台不受影响，始终常驻。
  bool dshStopOnExit;

  /// DSH 联网搜索引擎：auto / bing / ddg / ddg-lite / deepseek。
  /// 前四项免密；deepseek 使用 [dshSearchKey]。
  String dshSearchProvider;

  /// DSH DeepSeek 官方搜索 API Key（仅 provider=deepseek 时使用）。
  String dshSearchKey;

  AppSettings({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = '',
    this.apiProtocol = 'openai',
    this.systemPrompt = '',
    this.temperature = 0.7,
    this.enableTools = true,
    this.enableMemory = true,
    this.enableAutoLearn = true,
    this.ttsEnabled = false,
    this.ttsRate = 1.0,
    this.themeMode = 'dark',
    this.contextLimit = 128000,
    this.maxOutputTokens = 8192,
    this.compressThresholdPercent = 80,
    this.autoCompress = true,
    this.visionEnabled = false,
    this.visionBaseUrl = '',
    this.visionApiKey = '',
    this.visionModel = '',
    this.enableNotifications = true,
    this.enterToSend = true,
    this.terminalBackend = 'auto',
    this.agentEngine = 'shiyi',
    this.dshAutoCheckUpdate = true,
    this.dshUseProxy = true,
    this.dshStopOnExit = true,
    this.dshSearchProvider = 'auto',
    this.dshSearchKey = '',
  });

  AppSettings copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    String? apiProtocol,
    String? systemPrompt,
    double? temperature,
    bool? enableTools,
    bool? enableMemory,
    bool? enableAutoLearn,
    bool? ttsEnabled,
    double? ttsRate,
    String? themeMode,
    int? contextLimit,
    int? maxOutputTokens,
    double? compressThresholdPercent,
    bool? autoCompress,
    bool? visionEnabled,
    String? visionBaseUrl,
    String? visionApiKey,
    String? visionModel,
    bool? enableNotifications,
    bool? enterToSend,
    String? terminalBackend,
    String? agentEngine,
    bool? dshAutoCheckUpdate,
    bool? dshUseProxy,
    bool? dshStopOnExit,
    String? dshSearchProvider,
    String? dshSearchKey,
  }) => AppSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    apiProtocol: apiProtocol ?? this.apiProtocol,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    temperature: temperature ?? this.temperature,
    enableTools: enableTools ?? this.enableTools,
    enableMemory: enableMemory ?? this.enableMemory,
    enableAutoLearn: enableAutoLearn ?? this.enableAutoLearn,
    ttsEnabled: ttsEnabled ?? this.ttsEnabled,
    ttsRate: ttsRate ?? this.ttsRate,
    themeMode: themeMode ?? this.themeMode,
    contextLimit: contextLimit ?? this.contextLimit,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    compressThresholdPercent:
        compressThresholdPercent ?? this.compressThresholdPercent,
    autoCompress: autoCompress ?? this.autoCompress,
    visionEnabled: visionEnabled ?? this.visionEnabled,
    visionBaseUrl: visionBaseUrl ?? this.visionBaseUrl,
    visionApiKey: visionApiKey ?? this.visionApiKey,
    visionModel: visionModel ?? this.visionModel,
    enableNotifications: enableNotifications ?? this.enableNotifications,
    enterToSend: enterToSend ?? this.enterToSend,
    terminalBackend: terminalBackend ?? this.terminalBackend,
    agentEngine: agentEngine ?? this.agentEngine,
    dshAutoCheckUpdate: dshAutoCheckUpdate ?? this.dshAutoCheckUpdate,
    dshUseProxy: dshUseProxy ?? this.dshUseProxy,
    dshStopOnExit: dshStopOnExit ?? this.dshStopOnExit,
    dshSearchProvider: dshSearchProvider ?? this.dshSearchProvider,
    dshSearchKey: dshSearchKey ?? this.dshSearchKey,
  );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'apiProtocol': apiProtocol,
    'systemPrompt': systemPrompt,
    'temperature': temperature,
    'enableTools': enableTools,
    'enableMemory': enableMemory,
    'enableAutoLearn': enableAutoLearn,
    'ttsEnabled': ttsEnabled,
    'ttsRate': ttsRate,
    'themeMode': themeMode,
    'contextLimit': contextLimit,
    'maxOutputTokens': maxOutputTokens,
    'compressThresholdPercent': compressThresholdPercent,
    'autoCompress': autoCompress,
    'visionEnabled': visionEnabled,
    'visionBaseUrl': visionBaseUrl,
    'visionApiKey': visionApiKey,
    'visionModel': visionModel,
    'enableNotifications': enableNotifications,
    'enterToSend': enterToSend,
    'terminalBackend': terminalBackend,
    'agentEngine': agentEngine,
    'dshAutoCheckUpdate': dshAutoCheckUpdate,
    'dshUseProxy': dshUseProxy,
    'dshStopOnExit': dshStopOnExit,
    'dshSearchProvider': dshSearchProvider,
    'dshSearchKey': dshSearchKey,
  };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
    baseUrl: j['baseUrl'] ?? 'https://api.openai.com/v1',
    apiKey: j['apiKey'] ?? '',
    model: j['model'] ?? '',
    apiProtocol: j['apiProtocol'] ?? 'openai',
    systemPrompt: j['systemPrompt'] ?? '',
    temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
    enableTools: j['enableTools'] ?? true,
    enableMemory: j['enableMemory'] ?? true,
    enableAutoLearn: j['enableAutoLearn'] ?? true,
    ttsEnabled: j['ttsEnabled'] ?? false,
    ttsRate: (j['ttsRate'] as num?)?.toDouble() ?? 1.0,
    themeMode: j['themeMode'] ?? 'dark',
    contextLimit: (j['contextLimit'] as num?)?.toInt() ?? 128000,
    maxOutputTokens: (j['maxOutputTokens'] as num?)?.toInt() ?? 8192,
    compressThresholdPercent:
        (j['compressThresholdPercent'] as num?)?.toDouble() ?? 80,
    autoCompress: j['autoCompress'] ?? true,
    visionEnabled: j['visionEnabled'] ?? false,
    visionBaseUrl: j['visionBaseUrl'] ?? '',
    visionApiKey: j['visionApiKey'] ?? '',
    visionModel: j['visionModel'] ?? '',
    enableNotifications: j['enableNotifications'] ?? true,
    enterToSend: j['enterToSend'] ?? true,
    terminalBackend: j['terminalBackend'] ?? 'auto',
    agentEngine: j['agentEngine'] ?? 'shiyi',
    dshAutoCheckUpdate: j['dshAutoCheckUpdate'] ?? true,
    dshUseProxy: j['dshUseProxy'] ?? true,
    dshStopOnExit: j['dshStopOnExit'] ?? true,
    dshSearchProvider: j['dshSearchProvider'] ?? 'auto',
    dshSearchKey: j['dshSearchKey'] ?? '',
  );
}

/// 一组可保存的 API 配置：名称 + 接口地址 + 密钥 + 模型。
/// 切换配置时自动带出密钥，不用每次重输。
class ApiProfile {
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String apiProtocol;
  const ApiProfile({
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
    this.apiProtocol = 'openai',
  });

  ApiProfile copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    String? apiProtocol,
  }) => ApiProfile(
    name: name,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    apiProtocol: apiProtocol ?? this.apiProtocol,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'apiProtocol': apiProtocol,
  };

  factory ApiProfile.fromJson(Map<String, dynamic> j) => ApiProfile(
    name: j['name'] ?? '',
    baseUrl: j['baseUrl'] ?? '',
    apiKey: j['apiKey'] ?? '',
    model: j['model'] ?? '',
    apiProtocol: j['apiProtocol'] ?? 'openai',
  );
}
