import 'dart:convert';

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
  int createdAt;
  int updatedAt;
  int messageCount;
  int totalTokens;

  Session({
    required this.id,
    required this.title,
    required this.model,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
    this.totalTokens = 0,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'model': model,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'total_tokens': totalTokens,
      };

  factory Session.fromMap(Map<String, dynamic> m) => Session(
        id: m['id'],
        title: m['title'],
        model: m['model'],
        createdAt: m['created_at'],
        updatedAt: m['updated_at'],
        messageCount: m['message_count'] == null ? 0 : int.parse('${m['message_count']}'),
        totalTokens: m['total_tokens'] == null ? 0 : int.parse('${m['total_tokens']}'),
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

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'arguments': arguments};
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
List<String> extractImagePaths(String content) =>
    imageMarkerRegExp.allMatches(content).map((m) => m.group(1)!.trim()).toList();

/// 去掉图片标记，只留纯文本。
String stripImageMarkers(String content) =>
    content.replaceAll(imageMarkerRegExp, '').trim();

class ChatMessage {
  String id;
  String sessionId;
  String role; // user | assistant | system | tool
  String content;
  List<ToolCall> toolCalls;
  String toolCallId; // for tool results
  int createdAt;
  bool streaming;

  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content = '',
    List<ToolCall>? toolCalls,
    this.toolCallId = '',
    required this.createdAt,
    this.streaming = false,
  }) : toolCalls = toolCalls ?? [];

  bool get hasToolCalls => toolCalls.isNotEmpty;
  bool get hasImages => extractImagePaths(content).isNotEmpty;

  Map<String, dynamic> toMap() => {
        'id': id,
        'session_id': sessionId,
        'role': role,
        'content': content,
        'tool_calls': jsonEncode(toolCalls.map((t) => t.toJson()).toList()),
        'tool_call_id': toolCallId,
        'created_at': createdAt,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
        id: m['id'],
        sessionId: m['session_id'],
        role: m['role'],
        content: m['content'] ?? '',
        toolCalls: (m['tool_calls'] == null || m['tool_calls'] == '')
            ? []
            : (jsonDecode(m['tool_calls']) as List)
                .map((e) => ToolCall.fromJson(e))
                .toList(),
        toolCallId: m['tool_call_id'] ?? '',
        createdAt: m['created_at'],
      );

  Map<String, dynamic> toApiMap() {
    if (role == 'tool') {
      return {
        'role': 'tool',
        'content': content,
        'tool_call_id': toolCallId,
      };
    }
    if (hasToolCalls) {
      return {
        'role': 'assistant',
        'content': content,
        'tool_calls': toolCalls
            .map((t) => {
                  'id': t.id.isEmpty ? 'call_$id' : t.id,
                  'type': 'function',
                  'function': {'name': t.name, 'arguments': t.arguments}
                })
            .toList(),
      };
    }
    return {'role': role, 'content': content};
  }
}

class MemoryEntry {
  int id;
  String content;
  String source;
  int createdAt;

  MemoryEntry({required this.id, required this.content, required this.source, required this.createdAt});

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'source': source,
        'created_at': createdAt,
      };

  factory MemoryEntry.fromMap(Map<String, dynamic> m) => MemoryEntry(
        id: m['id'],
        content: m['content'],
        source: m['source'] ?? '',
        createdAt: m['created_at'],
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
  String systemPrompt;
  double temperature;
  bool enableTools;
  bool enableMemory;
  bool enableAutoLearn;
  bool ttsEnabled;
  double ttsRate;
  String themeMode; // light / dark / system

  /// 会话上下文上限（字符，最大 100 万）。
  int contextLimit;
  /// 上下文压缩阈值（占上下文上限的百分比，如 80 表示 80%）。
  double compressThresholdPercent;
  /// 达到压缩阈值时自动压缩。
  bool autoCompress;

  AppSettings({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = '',
    this.systemPrompt = '',
    this.temperature = 0.7,
    this.enableTools = true,
    this.enableMemory = true,
    this.enableAutoLearn = true,
    this.ttsEnabled = false,
    this.ttsRate = 1.0,
    this.themeMode = 'dark',
    this.contextLimit = 1000000,
    this.compressThresholdPercent = 80,
    this.autoCompress = true,
  });

  AppSettings copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    String? systemPrompt,
    double? temperature,
    bool? enableTools,
    bool? enableMemory,
    bool? enableAutoLearn,
    bool? ttsEnabled,
    double? ttsRate,
    String? themeMode,
    int? contextLimit,
    double? compressThresholdPercent,
    bool? autoCompress,
  }) =>
      AppSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        temperature: temperature ?? this.temperature,
        enableTools: enableTools ?? this.enableTools,
        enableMemory: enableMemory ?? this.enableMemory,
        enableAutoLearn: enableAutoLearn ?? this.enableAutoLearn,
        ttsEnabled: ttsEnabled ?? this.ttsEnabled,
        ttsRate: ttsRate ?? this.ttsRate,
        themeMode: themeMode ?? this.themeMode,
        contextLimit: contextLimit ?? this.contextLimit,
        compressThresholdPercent:
            compressThresholdPercent ?? this.compressThresholdPercent,
        autoCompress: autoCompress ?? this.autoCompress,
      );

  Map<String, dynamic> toJson() =>
      {'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model, 'systemPrompt': systemPrompt, 'temperature': temperature, 'enableTools': enableTools, 'enableMemory': enableMemory, 'enableAutoLearn': enableAutoLearn, 'ttsEnabled': ttsEnabled, 'ttsRate': ttsRate, 'themeMode': themeMode, 'contextLimit': contextLimit, 'compressThresholdPercent': compressThresholdPercent, 'autoCompress': autoCompress};

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        baseUrl: j['baseUrl'] ?? 'https://api.openai.com/v1',
        apiKey: j['apiKey'] ?? '',
        model: j['model'] ?? '',
        systemPrompt: j['systemPrompt'] ?? '',
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
        enableTools: j['enableTools'] ?? true,
        enableMemory: j['enableMemory'] ?? true,
        enableAutoLearn: j['enableAutoLearn'] ?? true,
        ttsEnabled: j['ttsEnabled'] ?? false,
        ttsRate: (j['ttsRate'] as num?)?.toDouble() ?? 1.0,
        themeMode: j['themeMode'] ?? 'dark',
        contextLimit: (j['contextLimit'] as num?)?.toInt() ?? 1000000,
        compressThresholdPercent:
            (j['compressThresholdPercent'] as num?)?.toDouble() ?? 80,
        autoCompress: j['autoCompress'] ?? true,
      );
}

/// 一组可保存的 API 配置：名称 + 接口地址 + 密钥 + 模型。
/// 切换配置时自动带出密钥，不用每次重输。
class ApiProfile {
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  const ApiProfile({
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
  });

  ApiProfile copyWith({String? baseUrl, String? apiKey, String? model}) =>
      ApiProfile(
        name: name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};

  factory ApiProfile.fromJson(Map<String, dynamic> j) => ApiProfile(
        name: j['name'] ?? '',
        baseUrl: j['baseUrl'] ?? '',
        apiKey: j['apiKey'] ?? '',
        model: j['model'] ?? '',
      );
}
