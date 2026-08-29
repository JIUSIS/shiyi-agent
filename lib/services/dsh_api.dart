import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'dsh_endpoint.dart';
import 'dsh_live.dart';
import 'runtime_logger.dart';

/// DSH（DeepSeek Harness）HTTP RPC API 客户端。
///
/// 协议（实测于 dsh 0.1.0-rc.6，`dsh-host-apiproxy`）：
/// - 请求：`POST /api/<method>`，body `{type:'client-request', rpcId, method, payload}`
/// - 响应：`{type:'server-response', rpcId, result: {ok:true, value} | {ok:false, error:{code,message}}}`
/// - 下行：`ws://<host>/api/events.mux` 与 `/api/events.host`，每条文本是 ServerRequest；
///   `assistant/chunk` 就是 token 流（text-delta / reasoning-delta）。
///
/// 适配层单点封装：DSH 协议升级只改本文件。
class DshApiException implements Exception {
  final String message;
  final String? code;
  DshApiException(this.message, {this.code});
  @override
  String toString() => code == null ? message : '$message (code: $code)';
}

class DshCommandExecution {
  final String? commandId;
  final bool ok;
  final String? result;
  final String? error;
  final int? sourceEventSeq;

  const DshCommandExecution({
    required this.commandId,
    required this.ok,
    this.result,
    this.error,
    this.sourceEventSeq,
  });

  factory DshCommandExecution.fromJson(Map<String, dynamic> json) {
    final outcome = (json['result'] as Map?)?.cast<String, dynamic>();
    final kind = outcome?['kind']?.toString();
    final text = outcome?['text']?.toString();
    final legacyError = json['error'];
    final error = kind == 'error'
        ? text ?? 'DSH 命令执行失败'
        : legacyError is Map
        ? legacyError['message']?.toString() ?? legacyError.toString()
        : legacyError?.toString();
    return DshCommandExecution(
      commandId: json['commandId']?.toString(),
      ok: kind == 'success' || (kind == null && json['ok'] == true),
      result: kind == 'success'
          ? text
          : json['output']?.toString() ??
                (json['result'] is String ? json['result']?.toString() : null),
      error: error,
      sourceEventSeq: (outcome?['sourceEventSeq'] as num?)?.toInt(),
    );
  }
}

class DshSessionSummary {
  final String sessionId;
  final String? title;
  final int updatedAt;
  final bool running;
  final bool blank;
  final String? cwd;
  final String? agentPreset;
  final int turnCount;
  final int stepCount;
  final int llmMs;
  final int toolMs;
  final int ttftMs;
  final int ttftSteps;
  final int decodeMs;
  final int decodeTokens;
  final int uncachedInputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int outputTokens;

  /// 是否为子代理会话（origin=subagent，由 agent 派生，不显示在会话列表）。
  final bool isSubagent;

  /// 会话统计栏的 billed 输入口径（官方 tokenUsage 三桶之和）。
  int get billedInputTokens =>
      uncachedInputTokens + cacheReadTokens + cacheWriteTokens;

  bool get hasBilling => billedInputTokens > 0 || outputTokens > 0;

  DshSessionSummary({
    required this.sessionId,
    this.title,
    required this.updatedAt,
    required this.running,
    required this.blank,
    this.cwd,
    this.agentPreset,
    this.turnCount = 0,
    this.stepCount = 0,
    this.isSubagent = false,
    this.llmMs = 0,
    this.toolMs = 0,
    this.ttftMs = 0,
    this.ttftSteps = 0,
    this.decodeMs = 0,
    this.decodeTokens = 0,
    this.uncachedInputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.outputTokens = 0,
  });

  factory DshSessionSummary.fromJson(Map<String, dynamic> j) {
    final projections = (j['projections'] as Map?)?.cast<String, dynamic>();
    final values =
        (projections?['values'] as Map?)?.cast<String, dynamic>() ?? const {};
    final stats = (values['sessionStats'] as Map?)?.cast<String, dynamic>();
    final usage =
        (values['tokenUsage'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DshSessionSummary(
      sessionId: (j['sessionId'] ?? '').toString(),
      title: values['title']?.toString(),
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      running: j['running'] == true,
      blank: j['blank'] == true,
      cwd: j['cwd']?.toString(),
      agentPreset: j['agentPreset']?.toString(),
      turnCount: (stats?['turns'] as num?)?.toInt() ?? 0,
      stepCount: (stats?['steps'] as num?)?.toInt() ?? 0,
      isSubagent: j['origin']?.toString() == 'subagent',
      llmMs: (stats?['llmMs'] as num?)?.toInt() ?? 0,
      toolMs: (stats?['toolMs'] as num?)?.toInt() ?? 0,
      ttftMs: (stats?['ttftMs'] as num?)?.toInt() ?? 0,
      ttftSteps: (stats?['ttftSteps'] as num?)?.toInt() ?? 0,
      decodeMs: (stats?['decodeMs'] as num?)?.toInt() ?? 0,
      decodeTokens: (stats?['decodeTokens'] as num?)?.toInt() ?? 0,
      uncachedInputTokens: (usage['uncachedInputTokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (usage['cacheReadTokens'] as num?)?.toInt() ?? 0,
      cacheWriteTokens: (usage['cacheWriteTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['outputTokens'] as num?)?.toInt() ?? 0,
    );
  }

  DshSessionSummary withCwd(String? cwd) => DshSessionSummary(
    sessionId: sessionId,
    title: title,
    updatedAt: updatedAt,
    running: running,
    blank: blank,
    cwd: cwd,
    agentPreset: agentPreset,
    turnCount: turnCount,
    stepCount: stepCount,
    isSubagent: isSubagent,
    llmMs: llmMs,
    toolMs: toolMs,
    ttftMs: ttftMs,
    ttftSteps: ttftSteps,
    decodeMs: decodeMs,
    decodeTokens: decodeTokens,
    uncachedInputTokens: uncachedInputTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
    outputTokens: outputTokens,
  );

  /// 还原成 [fromJson] 可读的原始结构，供主页本地缓存使用。
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'updatedAt': updatedAt,
    'running': running,
    'blank': blank,
    'cwd': cwd,
    'agentPreset': agentPreset,
    'origin': isSubagent ? 'subagent' : null,
    'projections': {
      'values': {
        'title': title,
        'sessionStats': {
          'turns': turnCount,
          'steps': stepCount,
          'llmMs': llmMs,
          'toolMs': toolMs,
          'ttftMs': ttftMs,
          'ttftSteps': ttftSteps,
          'decodeMs': decodeMs,
          'decodeTokens': decodeTokens,
        },
        'tokenUsage': {
          'uncachedInputTokens': uncachedInputTokens,
          'cacheReadTokens': cacheReadTokens,
          'cacheWriteTokens': cacheWriteTokens,
          'outputTokens': outputTokens,
        },
      },
    },
  };
}

/// DSH 模型目录条目（modelProviderGroup.models 行）。
class DshModelInfo {
  final String id;
  final String name;
  final String providerId;
  final String providerName;
  final int? contextWindow;
  final int? maxTokens;
  DshModelInfo({
    required this.id,
    required this.name,
    required this.providerId,
    required this.providerName,
    this.contextWindow,
    this.maxTokens,
  });
}

/// DSH 模型分组（llm.models / session.models 的 groups 行）。
class DshModelGroup {
  final String id;
  final String name;
  final List<DshModelInfo> models;
  DshModelGroup({required this.id, required this.name, required this.models});
}

/// 当前会话模型选择（session.models 的 current）。
class DshModelSelection {
  final String provider;
  final String model;
  final String? reasoningEffort;
  DshModelSelection({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  factory DshModelSelection.fromJson(Map<String, dynamic> j) =>
      DshModelSelection(
        provider: (j['provider'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
        reasoningEffort: j['reasoningEffort']?.toString(),
      );
}

/// Agent 预设条目（agentPreset.list 行）。
class DshPresetInfo {
  final String id;
  final String trust; // system | user
  final bool isDefault;
  final String? name;
  final String? description;

  /// 为什么无法装载（YAML 损坏 / 缺少 agent.cordis.yml 等），正常为空。
  final String? broken;
  DshPresetInfo({
    required this.id,
    required this.trust,
    required this.isDefault,
    this.name,
    this.description,
    this.broken,
  });

  factory DshPresetInfo.fromJson(Map<String, dynamic> j) => DshPresetInfo(
    id: (j['id'] ?? '').toString(),
    trust: (j['trust'] ?? 'user').toString(),
    isDefault: j['isDefault'] == true,
    name: j['name']?.toString(),
    description: j['description']?.toString(),
    broken: j['broken']?.toString(),
  );
}

/// 工作区条目（workspace.list 行）。
class DshWorkspace {
  final String workspaceId;
  final String path;
  final String title;
  final List<String> sessionIds;
  final String createdAt;
  final String updatedAt;
  DshWorkspace({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
    required this.createdAt,
    required this.updatedAt,
  });

  factory DshWorkspace.fromJson(Map<String, dynamic> j) => DshWorkspace(
    workspaceId: (j['workspaceId'] ?? '').toString(),
    path: (j['path'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    sessionIds: ((j['sessionIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    createdAt: (j['createdAt'] ?? '').toString(),
    updatedAt: (j['updatedAt'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {
    'workspaceId': workspaceId,
    'path': path,
    'title': title,
    'sessionIds': sessionIds,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  DshWorkspace copyWith({List<String>? sessionIds}) => DshWorkspace(
    workspaceId: workspaceId,
    path: path,
    title: title,
    sessionIds: sessionIds ?? this.sessionIds,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// 子代理条目（subagent.list 行）。
class DshSubagentEntry {
  final String sessionId;
  final String? title;
  final bool running;
  final int updatedAt;
  final int turnCount;
  final String kind;
  final String mode;
  final bool hasChildren;
  final String? reason;
  DshSubagentEntry({
    required this.sessionId,
    this.title,
    required this.running,
    required this.updatedAt,
    this.turnCount = 0,
    this.kind = 'child',
    this.mode = 'one-shot',
    this.hasChildren = false,
    this.reason,
  });

  factory DshSubagentEntry.fromJson(Map<String, dynamic> j) {
    final projections = (j['projections'] as Map?)?.cast<String, dynamic>();
    final values =
        (projections?['values'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DshSubagentEntry(
      sessionId: (j['id'] ?? j['sessionId'] ?? '').toString(),
      title: j['label']?.toString() ?? values['title']?.toString(),
      running: j['activity'] == 'running' || j['running'] == true,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      turnCount:
          ((values['sessionStats'] as Map?)?['turns'] as num?)?.toInt() ?? 0,
      kind: (j['kind'] ?? 'child').toString(),
      mode: (j['mode'] ?? '').toString(),
      hasChildren: j['hasChildren'] == true,
      reason: j['reason']?.toString(),
    );
  }
}

/// 子代理历史包：消息 + 末尾未收口 live + 可选投影统计。
class DshSubagentHistoryBundle {
  final List<ChatMessage> messages;
  final DshLiveTurn live;
  final DshSessionSummary? summary;
  const DshSubagentHistoryBundle({
    required this.messages,
    required this.live,
    this.summary,
  });
}

/// 技能条目（skill.list 行）。
class DshSkillInfo {
  final String name;
  final String description;
  final String? whenToUse;
  final bool modelInvocable;
  DshSkillInfo({
    required this.name,
    required this.description,
    this.whenToUse,
    required this.modelInvocable,
  });

  factory DshSkillInfo.fromJson(Map<String, dynamic> j) => DshSkillInfo(
    name: (j['name'] ?? j['id'] ?? '').toString().trim(),
    description: (j['description'] ?? '').toString().trim(),
    whenToUse: j['whenToUse']?.toString().trim(),
    modelInvocable: j['modelInvocable'] != false,
  );
}

/// 凭据槽位（credentials.describe 行）。
class DshCredentialSlot {
  final List<String> path;
  final bool set;
  final bool writable;
  DshCredentialSlot({
    required this.path,
    required this.set,
    this.writable = true,
  });

  String get ref => path.isEmpty ? '' : path.last;
  String get label {
    switch (ref) {
      case 'SHIYI_API_KEY':
        return '拾忆模型 API Key';
      case 'SHIYI_DSH_SEARCH_KEY':
        return 'DSH 搜索 API Key';
      case 'DEEPSEEK_API_KEY':
        return 'DeepSeek API Key';
      default:
        return path.join(' › ');
    }
  }

  factory DshCredentialSlot.fromJson(Map<String, dynamic> j) =>
      DshCredentialSlot(
        path: _pathFromJson(j),
        set: j['set'] == true || j['configured'] == true,
        writable: j['writable'] != false,
      );

  static List<String> _pathFromJson(Map<String, dynamic> j) {
    final path = ((j['path'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    if (path.isNotEmpty) return path;
    final ref = (j['ref'] ?? '').toString();
    return ref.isEmpty ? const [] : [ref];
  }

  /// credentials.describe 返回 credentials 映射，而不是 slots 列表。
  static List<DshCredentialSlot> fromDescribeValue(Map<String, dynamic> v) {
    final raw = v['credentials'];
    if (raw is Map) {
      return raw.entries.map((e) {
        final info = (e.value is Map)
            ? Map<String, dynamic>.from(e.value as Map)
            : const <String, dynamic>{};
        return DshCredentialSlot(
          path: [e.key.toString()],
          set: info['configured'] == true,
          writable: info['writable'] != false,
        );
      }).toList();
    }
    final slots = (v['slots'] ?? const []) as List;
    return slots
        .map(
          (e) => DshCredentialSlot.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList();
  }
}

/// 主机描述（host.describe）。
class DshHostInfo {
  final String platform;
  final String arch;
  final String cwd;
  final String home;
  final String version;
  final bool canOpenPath;
  final String? name;
  DshHostInfo({
    required this.platform,
    required this.arch,
    required this.cwd,
    this.home = '',
    this.version = '',
    this.canOpenPath = false,
    this.name,
  });

  factory DshHostInfo.fromJson(Map<String, dynamic> j) => DshHostInfo(
    platform: (j['platform'] ?? '').toString(),
    arch: (j['arch'] ?? '').toString(),
    cwd: (j['cwd'] ?? '').toString(),
    home: (j['home'] ?? '').toString(),
    version: (j['version'] ?? '').toString(),
    canOpenPath: j['canOpenPath'] == true,
    name: j['name']?.toString(),
  );
}

/// 目录条目（host.listDirectory 行）。
class DshDirEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final bool hidden;
  final int? size;
  DshDirEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.hidden = false,
    this.size,
  });

  factory DshDirEntry.fromJson(Map<String, dynamic> j) => DshDirEntry(
    name: (j['name'] ?? j['basename'] ?? '').toString(),
    path: (j['path'] ?? j['fullPath'] ?? '').toString(),
    isDirectory:
        j['isDirectory'] == true ||
        j['kind'] == 'directory' ||
        (!j.containsKey('isDirectory') && !j.containsKey('kind')),
    hidden: j['hidden'] == true,
    size: (j['size'] as num?)?.toInt(),
  );
}

/// `host.listDirectory` 的完整目录快照。
class DshDirectoryListing {
  final String path;
  final String home;
  final List<DshDirEntry> crumbs;
  final List<DshDirEntry> entries;
  final bool truncated;

  const DshDirectoryListing({
    required this.path,
    required this.home,
    required this.crumbs,
    required this.entries,
    required this.truncated,
  });

  factory DshDirectoryListing.fromJson(Map<String, dynamic> j) {
    List<DshDirEntry> parse(dynamic raw) => raw is List
        ? raw
              .whereType<Map>()
              .map((e) => DshDirEntry.fromJson(e.cast<String, dynamic>()))
              .toList()
        : const <DshDirEntry>[];

    return DshDirectoryListing(
      path: (j['path'] ?? '').toString(),
      home: (j['home'] ?? '').toString(),
      crumbs: parse(j['crumbs']),
      entries: parse(j['items'] ?? j['entries']),
      truncated: j['truncated'] == true,
    );
  }
}

/// 探测当前 DSH 主机可访问的文件系统根目录。
///
/// DSH 目前没有独立的 host.listDrives RPC，因此 Windows 使用官方
/// host.listDirectory 逐个探测盘符；Unix-like 主机使用 `/` 作为根目录。
extension DshApiRootDirectoryScan on DshApiClient {
  Future<List<DshDirEntry>> scanRootDirectories({
    String platform = '',
    String pathHint = '',
  }) async {
    final isWindows = _looksLikeWindowsHost(platform, pathHint);
    final candidates = isWindows
        ? List<String>.generate(26, (i) => '${String.fromCharCode(65 + i)}:\\')
        : const ['/'];

    final results = await Future.wait(
      candidates.map((root) async {
        try {
          final listing = await directoryListing(
            root,
          ).timeout(const Duration(seconds: 3));
          return DshDirEntry(
            name: root,
            path: listing.path.isEmpty ? root : listing.path,
            isDirectory: true,
          );
        } catch (_) {
          return null;
        }
      }),
    );
    return results.whereType<DshDirEntry>().toList();
  }

  static bool _looksLikeWindowsHost(String platform, String pathHint) {
    final value = platform.trim().toLowerCase();
    if (value.contains('win')) return true;
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(pathHint.trim());
  }
}

/// 设置命名空间（settings.describe 行）。
class DshSettingsNamespace {
  final String ns;
  final Map<String, dynamic> value;
  final Map<String, dynamic> base;
  final Map<String, dynamic> user;
  final List<DshCredentialSlot> secrets;
  final int revision;

  /// 命名空间的 schemastery 序列化 schema（{uid, refs} 引用图）。
  /// 旧版 DSH 可能不下发；只读展示用。
  final Map<String, dynamic> schema;
  DshSettingsNamespace({
    required this.ns,
    required this.value,
    this.base = const {},
    this.user = const {},
    required this.secrets,
    required this.revision,
    this.schema = const {},
  });
}

/// 权限预设可选项（permission 命名空间 schema 里 advertised 的表项）。
class DshPermissionPresetOption {
  final String key;
  final String label;
  const DshPermissionPresetOption({required this.key, required this.label});
}

/// 目标 DSH 的权限预设表（permissionPresets 服务）。
class DshPermissionPresets {
  final String defaultPreset;
  final int revision;
  final List<DshPermissionPresetOption> options;
  const DshPermissionPresets({
    required this.defaultPreset,
    required this.revision,
    required this.options,
  });
}

/// 目标 DSH 实时插件清单条目（pluginInventory/list）。
class DshPluginInventoryEntry {
  final String entryId;
  final String moduleName;
  final bool enabled;

  /// null / failed / pending / active / loading / unloading。
  final String fiberPhase;
  const DshPluginInventoryEntry({
    required this.entryId,
    required this.moduleName,
    required this.enabled,
    required this.fiberPhase,
  });

  factory DshPluginInventoryEntry.fromJson(Map<String, dynamic> j) =>
      DshPluginInventoryEntry(
        entryId: (j['entryId'] ?? '').toString(),
        moduleName: (j['moduleName'] ?? '').toString(),
        enabled: j['enabled'] == true,
        fiberPhase: j['fiberPhase']?.toString() ?? '',
      );
}

/// 目标引用（goal.* 的 ref）。
class DshGoalRef {
  final String goalId;
  final String objective;
  final String status; // active | paused | completed | cleared
  final int round;
  final int maxRounds;
  DshGoalRef({
    required this.goalId,
    required this.objective,
    required this.status,
    required this.round,
    required this.maxRounds,
  });

  factory DshGoalRef.fromJson(Map<String, dynamic> j) => DshGoalRef(
    goalId: (j['goalId'] ?? j['id'] ?? '').toString(),
    objective: (j['objective'] ?? '').toString(),
    status: (j['status'] ?? 'active').toString(),
    round: (j['round'] as num?)?.toInt() ?? 0,
    maxRounds: (j['maxRounds'] as num?)?.toInt() ?? 0,
  );
}

/// DSH 工具调用记录（会话消息重建时的附属数据）。
class DshToolCallInfo {
  final String callId;
  final String name;
  final String arguments;
  DshToolCallInfo({
    required this.callId,
    required this.name,
    this.arguments = '',
  });
}

/// DSH 会话客户端：会话列表 / 历史 / 发消息 / 新建。
/// 默认地址本机 http://127.0.0.1:3080；局域网 / 公网由 [configure] 切换。
class DshApiClient {
  DshApiClient({
    String baseUrl = DshEndpoint.localUrl,
    String token = '',
    String scopeKey = '',
    String hostOverride = '',
    List<String> customCompatibilityHosts = const [],
    List<String> compatibilityHosts = const [],
    http.Client? client,
  }) : _scopeKey = scopeKey.trim(),
       _baseUrl = DshEndpoint.stripSlash(baseUrl),
       _token = token.trim(),
       _configuredHostOverride = hostOverride.trim(),
       _customHostCandidates = _normalizeCompatibilityHosts(
         customCompatibilityHosts,
       ),
       _compatHostCandidates = _normalizeCompatibilityHosts(compatibilityHosts),
       _client = client ?? http.Client();

  /// 全局单例：会话列表与聊天页共享同一连接（避免重复探测/缓存丢失）。
  static final DshApiClient instance = DshApiClient();

  String _baseUrl;
  final String _scopeKey;
  String _token;
  String _configuredHostOverride;
  List<String> _customHostCandidates;
  List<String> _compatHostCandidates;
  String? _compatHostOverride;
  final http.Client _client;
  static const Duration _timeout = Duration(seconds: 30);

  String get baseUrl => _baseUrl;
  String get token => _token;
  String get scopeKey => _scopeKey;

  /// 切换当前连接。空地址表示尚未填好，RPC 会直接失败。
  void configure({
    String? baseUrl,
    String? token,
    String? hostOverride,
    List<String> customCompatibilityHosts = const [],
    List<String> compatibilityHosts = const [],
  }) {
    final nextHostOverride = hostOverride?.trim() ?? _configuredHostOverride;
    final nextCustomHosts = _normalizeCompatibilityHosts(
      customCompatibilityHosts,
    );
    final nextCompatibilityHosts = _normalizeCompatibilityHosts(
      compatibilityHosts,
    );
    if (baseUrl != null) {
      final next = DshEndpoint.stripSlash(baseUrl);
      if (next != _baseUrl ||
          nextHostOverride != _configuredHostOverride ||
          !_sameStrings(nextCustomHosts, _customHostCandidates) ||
          !_sameStrings(nextCompatibilityHosts, _compatHostCandidates)) {
        _compatHostOverride = null;
      }
      _baseUrl = next;
    }
    _configuredHostOverride = nextHostOverride;
    _customHostCandidates = nextCustomHosts;
    _compatHostCandidates = nextCompatibilityHosts;
    if (token != null) _token = token;
  }

  static List<String> _normalizeCompatibilityHosts(Iterable<String> values) {
    final out = <String>[];
    for (final value in values) {
      final normalized = value.trim();
      if (normalized.isNotEmpty && !out.contains(normalized)) {
        out.add(normalized);
      }
    }
    return out;
  }

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, String> _headers({String? hostOverride}) {
    final headers = <String, String>{'content-type': 'application/json'};
    final host = _effectiveHostOverride(hostOverride);
    if (host != null) {
      headers['host'] = host;
      headers['origin'] = _originForHost(host);
    }
    final raw = _token.trim();
    if (raw.isNotEmpty) {
      headers['authorization'] = raw.toLowerCase().startsWith('bearer ')
          ? raw
          : 'Bearer $raw';
    }
    return headers;
  }

  Map<String, dynamic> _wsHeaders() {
    final headers = <String, dynamic>{};
    final host = _effectiveHostOverride(null);
    if (host != null) {
      headers['Host'] = host;
      headers['Origin'] = _originForHost(host);
    }
    final raw = _token.trim();
    if (raw.isNotEmpty) {
      headers['Authorization'] = raw.toLowerCase().startsWith('bearer ')
          ? raw
          : 'Bearer $raw';
    }
    return headers;
  }

  String? _effectiveHostOverride(String? explicit) {
    final value = explicit?.trim();
    if (value != null && value.isNotEmpty) return value;
    if (_configuredHostOverride.isNotEmpty) return _configuredHostOverride;
    final compatible = _compatHostOverride?.trim();
    return compatible == null || compatible.isEmpty ? null : compatible;
  }

  String _originForHost(String host) {
    final scheme = Uri.tryParse(_baseUrl)?.scheme == 'https' ? 'https' : 'http';
    return '$scheme://$host';
  }

  /// 仅供协议回归测试确认 WS 与 HTTP 使用同一身份头。
  Map<String, dynamic> debugWebSocketHeaders() => _wsHeaders();

  static String _newRpcId() {
    final r = Random.secure();
    final hex = List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<bool>? _rpcPingInFlight;

  /// RPC 就绪探测：比 GET / 严格，dsh 进程已监听但 API 未初始化完成时
  /// 仍算未就绪（否则页面会误判 running 去调接口挂 30 秒）。
  /// 并发合并：启动期多个页面同时轮询只发一个请求。
  Future<bool> rpcPing() {
    final existing = _rpcPingInFlight;
    if (existing != null) return existing;
    final done = _doRpcPing();
    _rpcPingInFlight = done;
    done.whenComplete(() => _rpcPingInFlight = null);
    return done;
  }

  Future<bool> _doRpcPing() async {
    if (_baseUrl.isEmpty) return false;
    try {
      await _rpc('session.list', {}).timeout(const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 执行一次 RPC，返回 value（已断言 ok）。
  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, dynamic> payload,
  ) async {
    final started = DateTime.now();
    final requestId =
        'dshrpc_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'rpc.started',
        requestId: requestId,
        data: {
          'method': method,
          'endpoint': _safeEndpoint('$_baseUrl/api/$method'),
        },
      ),
    );
    final encoded = jsonEncode({
      'type': 'client-request',
      'rpcId': _newRpcId(),
      'method': method,
      'payload': payload,
    });
    http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_baseUrl/api/$method'),
            headers: _headers(),
            body: encoded,
          )
          .timeout(_timeout);
      if (res.statusCode == 403 &&
          _configuredHostOverride.isEmpty &&
          _compatHostOverride == null &&
          (method == 'session.list' ||
              method == 'workspace.list' ||
              method == 'settings.describe') &&
          (_customHostCandidates.isNotEmpty ||
              _compatHostCandidates.isNotEmpty)) {
        final custom = await _scanCompatibilityHosts(
          method: method,
          encoded: encoded,
          candidates: _customHostCandidates,
          allowEmpty: true,
        );
        final preset =
            custom ??
            await _scanCompatibilityHosts(
              method: method,
              encoded: encoded,
              candidates: _compatHostCandidates,
              allowEmpty: false,
            );
        if (preset != null) res = preset;
      }
    } catch (e) {
      unawaited(
        RuntimeLogger.instance.error(
          'DSH',
          'rpc.failed',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'unreachable',
          data: {'method': method, 'error': '$e'},
        ),
      );
      throw DshApiException('DeepSeek Harness 服务不可达：$e');
    }
    if (res.statusCode != 200) {
      String? errorCode;
      String? errorMessage;
      try {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        final result = (decoded is Map ? decoded['result'] : null) as Map?;
        final error =
            (result?['error'] ?? (decoded is Map ? decoded['error'] : null))
                as Map?;
        errorCode = error?['code']?.toString();
        errorMessage = error?['message']?.toString();
      } catch (_) {}
      unawaited(
        RuntimeLogger.instance.warn(
          'DSH',
          'rpc.status',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'HTTP ${res.statusCode}',
          data: {'method': method, 'statusCode': res.statusCode},
        ),
      );
      final trimmedError = errorMessage?.trim() ?? '';
      final suffix = trimmedError.isEmpty ? '' : '：$trimmedError';
      throw DshApiException(
        'DeepSeek Harness HTTP ${res.statusCode}$suffix',
        code: errorCode ?? 'http-${res.statusCode}',
      );
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      unawaited(
        RuntimeLogger.instance.error(
          'DSH',
          'rpc.failed',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'invalid_response',
          data: {'method': method, 'statusCode': res.statusCode},
        ),
      );
      throw DshApiException('DeepSeek Harness 响应解析失败');
    }
    final result = (body['result'] as Map?)?.cast<String, dynamic>();
    if (result == null) throw DshApiException('DeepSeek Harness 响应缺少 result');
    if (result['ok'] != true) {
      final err = (result['error'] as Map?)?.cast<String, dynamic>();
      unawaited(
        RuntimeLogger.instance.warn(
          'DSH',
          'rpc.rejected',
          requestId: requestId,
          durationMs: DateTime.now().difference(started).inMilliseconds,
          result: 'rejected',
          data: {
            'method': method,
            'code': err?['code']?.toString() ?? '',
            'error': err?['message']?.toString() ?? 'unknown',
          },
        ),
      );
      throw DshApiException(
        err?['message']?.toString() ?? '未知错误',
        code: err?['code']?.toString(),
      );
    }
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'rpc.completed',
        requestId: requestId,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        result: 'ok',
        data: {'method': method, 'statusCode': res.statusCode},
      ),
    );
    return (result['value'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  static String _safeEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return '<endpoint>';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}';
  }

  Future<http.Response?> _scanCompatibilityHosts({
    required String method,
    required String encoded,
    required List<String> candidates,
    required bool allowEmpty,
  }) async {
    for (final host in candidates) {
      try {
        final retry = await _client
            .post(
              Uri.parse('$_baseUrl/api/$method'),
              headers: _headers(hostOverride: host),
              body: encoded,
            )
            .timeout(const Duration(seconds: 3));
        if (_isCompatibleDshResponse(retry, allowEmpty: allowEmpty)) {
          _compatHostOverride = host;
          return retry;
        }
        if (!allowEmpty &&
            method == 'session.list' &&
            _isCompatibleDshResponse(retry, allowEmpty: true)) {
          final workspaceProbe = await _client
              .post(
                Uri.parse('$_baseUrl/api/workspace.list'),
                headers: _headers(hostOverride: host),
                body: jsonEncode({
                  'type': 'client-request',
                  'rpcId': _newRpcId(),
                  'method': 'workspace.list',
                  'payload': const <String, dynamic>{},
                }),
              )
              .timeout(const Duration(seconds: 3));
          if (_isCompatibleDshResponse(workspaceProbe, allowEmpty: false)) {
            _compatHostOverride = host;
            return retry;
          }
        }
      } catch (_) {
        // 单个 Host 失败时继续扫描剩余预设。
      }
    }
    return null;
  }

  static bool _isCompatibleDshResponse(
    http.Response response, {
    required bool allowEmpty,
  }) {
    if (response.statusCode != 200) return false;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map) return false;
      final result = body['result'];
      if (result is! Map || result['ok'] != true) return false;
      if (allowEmpty) return true;
      final value = result['value'];
      final items = value is Map ? value['items'] : null;
      return items is List && items.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 会话列表（按 updatedAt 倒序；过滤子代理会话——它们由 agent 派生，
  /// 不应出现在用户会话列表）。
  Future<List<DshSessionSummary>> listSessions() async {
    final value = await _rpc('session.list', {});
    final items = (value['items'] as List?) ?? const [];
    final out =
        items
            .map(
              (e) => DshSessionSummary.fromJson(
                (e as Map).cast<String, dynamic>(),
              ),
            )
            .where((s) => !s.isSubagent)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// 新建或唤醒会话。传入 [sessionId] 会复用 DSH 已有会话并完成挂载。
  ///
  /// [workspaceId] 与 [cwd] 不能同时传（DSH 协议：`session.create accepts
  /// workspaceId or cwd, not both`）。带 [workspaceId] 时 DSH 用工作区路径
  /// 作为 cwd，并 `attachSession` 入账；只带 [cwd] 不会写入 `sessionIds`，
  /// 之后 `insertSessionBefore` 会因未入账失败。
  Future<String> createSession({
    String? agentPreset,
    String? cwd,
    String? sessionId,
    String? workspaceId,
  }) async {
    final payload = <String, dynamic>{};
    final workspace = workspaceId?.trim() ?? '';
    if (workspace.isNotEmpty) {
      payload['workspaceId'] = workspace;
    } else if (cwd != null && cwd.isNotEmpty) {
      payload['cwd'] = cwd;
    }
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['sessionId'] = sessionId.trim();
    }
    final preset = agentPreset?.trim() ?? '';
    if (preset.isNotEmpty) payload['agentPreset'] = preset;
    final value = await _rpc('session.create', payload);
    return (value['sessionId'] ?? '').toString();
  }

  /// 重命名会话。
  Future<void> renameSession(String sessionId, String title) async {
    await _rpc('session.rename', {'sessionId': sessionId, 'title': title});
  }

  /// 更新会话工作目录。
  ///
  /// 新版 DSH 提供 `session.update`；旧版曾把工作区选择暴露为独立
  /// RPC，因此保留两个兼容回退，避免手机端选目录后只更新了 UI。
  Future<void> updateSessionCwd(String sessionId, String cwd) async {
    final path = cwd.trim();
    if (path.isEmpty) return;
    try {
      await _rpc('session.update', {'sessionId': sessionId, 'cwd': path});
      return;
    } catch (_) {
      // 继续尝试旧版命名，最终再用 workspace 关联兜底。
    }
    try {
      await _rpc('session.setCwd', {'sessionId': sessionId, 'cwd': path});
      return;
    } catch (_) {
      // 旧版没有单独 cwd RPC 时，至少把会话挂到选中的工作区。
    }
    final workspace = await createWorkspace(path);
    await insertSessionBefore(workspace.workspaceId, sessionId);
  }

  /// 发送消息（非阻塞：立即返回，agent 后台运行，轮询 history 收结果）。
  Future<void> prompt(String sessionId, String text) async {
    await _rpc('session.prompt', {
      'sessionId': sessionId,
      'mode': 'queue',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'clientTimeZone': 'Asia/Shanghai',
    });
  }

  /// Execute an official DSH command without routing it through session.prompt.
  Future<DshCommandExecution> executeCommand({
    required String sessionId,
    required String line,
  }) async {
    final value = await _rpc('commands/execute', {
      'args': {'agentId': sessionId, 'line': line},
    });
    return DshCommandExecution.fromJson(value);
  }

  Future<DshCommandExecution> compactSession(String sessionId) =>
      executeCommand(sessionId: sessionId, line: '/compact');

  /// 停止当前正在运行的 agent 回合（session.cancel）。
  Future<void> cancel(String sessionId) async {
    await _rpc('session.cancel', {'sessionId': sessionId});
  }

  /// 应答 DSH 下行的 question/requested（client-response 走 POST /api/respond）。
  Future<void> answerQuestion(
    String rpcId,
    String sessionId,
    List<Map<String, dynamic>> answers,
  ) async {
    await _respond(rpcId, {
      'ok': true,
      'value': {
        'sessionId': sessionId,
        'answer': {'answers': answers},
      },
    });
  }

  /// 取消 DSH 提问（result.ok=false，error code=cancelled）。
  Future<void> cancelQuestion(String rpcId) async {
    await _respond(rpcId, {
      'ok': false,
      'error': {
        'code': 'cancelled',
        'message': 'the user closed this question request',
        'details': <String, dynamic>{},
      },
    });
  }

  Future<void> _respond(String rpcId, Map<String, dynamic> result) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_baseUrl/api/respond'),
            headers: _headers(),
            body: jsonEncode({
              'type': 'client-response',
              'rpcId': rpcId,
              'result': result,
            }),
          )
          .timeout(_timeout);
    } catch (e) {
      throw DshApiException('DeepSeek Harness 应答失败：$e');
    }
    if (res.statusCode != 200) {
      throw DshApiException('DeepSeek Harness HTTP ${res.statusCode}');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw DshApiException('DeepSeek Harness 应答响应解析失败');
    }
    if (body['accepted'] != true) {
      throw DshApiException(
        'DeepSeek Harness 未接受应答',
        code: body['reason']?.toString(),
      );
    }
  }

  // ── 模型域 ────────────────────────────────────────────────────────────

  /// 会话可用模型（分组目录 + 当前选择）。
  Future<({DshModelSelection current, List<DshModelGroup> groups})>
  sessionModels(String sessionId) async {
    final v = await _rpc('session.models', {'sessionId': sessionId});
    return (
      current: DshModelSelection.fromJson(
        (v['current'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      groups: _parseModelGroups(v['groups']),
    );
  }

  /// 切换会话模型。
  Future<DshModelSelection> selectModel(
    String sessionId,
    String provider,
    String model, {
    String? reasoningEffort,
  }) async {
    final v = await _rpc('session.selectModel', {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
      if (reasoningEffort != null && reasoningEffort.isNotEmpty)
        'reasoningEffort': reasoningEffort,
    });
    final selection = DshModelSelection.fromJson(
      (v['selected'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    // 服务端回执进审计：排查「公网端模型没有立即变化」时，这里能看到
    // 远端到底承认了什么（200 不等于真的换过去了）。
    unawaited(
      RuntimeLogger.instance.info(
        'DSH',
        'session_model.selected',
        sessionId: sessionId,
        data: {
          'provider': selection.provider,
          'model': selection.model,
          'reasoningEffort': selection.reasoningEffort ?? '',
        },
      ),
    );
    return selection;
  }

  /// 目标 provider/model 不支持所请求思考档位的服务端拒绝
  /// （例如 `model "X" does not support reasoning effort "high"`）。
  /// 切模型时的降级重试判定：静态思考目录只是客户端猜测，服务端声明
  /// 才是权威——被这类拒绝时应去掉档位重试，而不是让整个切换失败。
  static bool isReasoningEffortRejection(String message) =>
      message.contains('does not support reasoning effort') ||
      message.contains('unsupported reasoning effort') ||
      message.contains('reasoning effort') && message.contains('not support');

  /// 全量模型目录（llm.models，跨提供方）。
  Future<List<DshModelGroup>> llmModels() async {
    final v = await _rpc('llm.models', {});
    return _parseModelGroups(v['groups']);
  }

  /// 可配置的模型提供方（llm.providers）。
  Future<List<Map<String, dynamic>>> llmProviders() async {
    final v = await _rpc('llm.providers', {});
    if (!v.containsKey('providers')) {
      throw DshApiException('目标 DSH 未返回 provider 目录', code: 'unsupported');
    }
    final raw = v['providers'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    if (raw is Map) {
      return [
        for (final entry in raw.entries)
          if (entry.value is Map)
            {
              'id': entry.key.toString(),
              ...(entry.value as Map).cast<String, dynamic>(),
            },
      ];
    }
    return const [];
  }

  static List<DshModelGroup> _parseModelGroups(dynamic raw) {
    final entries = raw is List
        ? raw
        : raw is Map
        ? raw.entries
              .where((e) => e.value is Map)
              .map((e) => {'id': e.key.toString(), ...e.value as Map})
              .toList()
        : const <dynamic>[];
    return entries.map((e) {
      final g = (e as Map).cast<String, dynamic>();
      final models = ((g['models'] as List?) ?? const []).map((m) {
        final mm = (m as Map).cast<String, dynamic>();
        return DshModelInfo(
          id: (mm['id'] ?? '').toString(),
          name: (mm['name'] ?? mm['id'] ?? '').toString(),
          providerId: (mm['providerId'] ?? g['id'] ?? '').toString(),
          providerName: (mm['providerName'] ?? g['name'] ?? '').toString(),
          contextWindow: (mm['contextWindow'] as num?)?.toInt(),
          maxTokens: (mm['maxTokens'] as num?)?.toInt(),
        );
      }).toList();
      return DshModelGroup(
        id: (g['id'] ?? '').toString(),
        name: (g['name'] ?? '').toString(),
        models: models,
      );
    }).toList();
  }

  // ── Agent 预设域 ──────────────────────────────────────────────────────

  /// 预设列表（agentPreset.list）。
  Future<({List<DshPresetInfo> presets, bool authorable})> listPresets() async {
    final v = await _rpc('agentPreset.list', {});
    return (
      presets: ((v['presets'] as List?) ?? const [])
          .map(
            (e) => DshPresetInfo.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList(),
      authorable: v['authorable'] == true,
    );
  }

  /// 切换会话的 agent 预设。
  Future<String> selectPreset(String sessionId, String agentPreset) async {
    final v = await _rpc('agentPreset.select', {
      'sessionId': sessionId,
      'agentPreset': agentPreset,
    });
    return (v['agentPreset'] ?? '').toString();
  }

  /// 把预设设为后续新建会话的默认（官方写 agent-presets.default）。
  Future<void> setDefaultPreset(String agentPreset) async {
    await _rpc('settings.update', {
      'ns': 'agent-presets',
      'patch': {'default': agentPreset},
    });
  }

  /// 读取预设内容（agentPreset.read）。
  Future<({String content, String trust, String? name, String? description})>
  readPreset(String agentPreset) async {
    final v = await _rpc('agentPreset.read', {'agentPreset': agentPreset});
    return (
      content: (v['content'] ?? '').toString(),
      trust: (v['trust'] ?? 'user').toString(),
      name: v['name']?.toString(),
      description: v['description']?.toString(),
    );
  }

  /// 复制预设为新的用户预设（agentPreset.copy）。
  Future<String> copyPreset(
    String from,
    String agentPreset, {
    String? name,
  }) async {
    final v = await _rpc('agentPreset.copy', {
      'from': from,
      'agentPreset': agentPreset,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    return (v['agentPreset'] ?? '').toString();
  }

  /// 删除用户预设（agentPreset.remove）。
  Future<void> removePreset(String agentPreset) async {
    await _rpc('agentPreset.remove', {'agentPreset': agentPreset});
  }

  // ── 工作区域 ──────────────────────────────────────────────────────────

  /// 工作区列表（workspace.list）。
  Future<({List<DshWorkspace> items, List<String> archivedSessionIds})>
  listWorkspaces() async {
    final v = await _rpc('workspace.list', {});
    return (
      items: ((v['items'] as List?) ?? const [])
          .map((e) => DshWorkspace.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      archivedSessionIds: ((v['archivedSessionIds'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// 创建/采用工作区目录（workspace.create）。
  Future<DshWorkspace> createWorkspace(String path) async {
    final v = await _rpc('workspace.create', {'path': path});
    return DshWorkspace.fromJson(
      (v['workspace'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// 重命名工作区（workspace.rename）。
  Future<DshWorkspace> renameWorkspace(String workspaceId, String title) async {
    final v = await _rpc('workspace.rename', {
      'workspaceId': workspaceId,
      'title': title,
    });
    return DshWorkspace.fromJson(
      (v['workspace'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// 删除工作区（workspace.delete）。
  Future<void> deleteWorkspace(String workspaceId) async {
    await _rpc('workspace.delete', {'workspaceId': workspaceId});
  }

  /// 调整工作区显示顺序（workspace.insertBefore）。
  /// [beforeWorkspaceId] 为 null 表示挪到末尾。
  Future<List<String>> insertWorkspaceBefore(
    String workspaceId, {
    String? beforeWorkspaceId,
  }) async {
    final v = await _rpc('workspace.insertBefore', {
      'workspaceId': workspaceId,
      'beforeWorkspaceId': ?beforeWorkspaceId,
    });
    return ((v['workspaceIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  /// 归档会话（workspace.archiveSession）。
  Future<List<String>> archiveSession(String sessionId) async {
    final v = await _rpc('workspace.archiveSession', {'sessionId': sessionId});
    return ((v['archivedSessionIds'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
  }

  /// 把会话搬到另一个工作区目录。
  ///
  /// 官方 `insertSessionBefore` 不能改 header.cwd；跨目录必须走拾忆内置
  /// 插件 `POST /__shiyi/move-session`。插件未加载时抛 `plugin-missing`。
  Future<Map<String, dynamic>> moveSessionToWorkspace({
    required String sessionId,
    required String workspaceId,
    String? workspacePath,
  }) async {
    final http.Response res;
    final payload = <String, String>{
      "sessionId": sessionId,
      "workspaceId": workspaceId,
    };
    final path = workspacePath?.trim() ?? "";
    if (path.isNotEmpty) payload["workspacePath"] = path;
    try {
      res = await _client
          .post(
            Uri.parse("$_baseUrl/__shiyi/move-session"),
            headers: _headers(),
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      throw DshApiException("DeepSeek Harness 服务不可达：$e");
    }
    if (res.statusCode == 404) {
      throw DshApiException("跨工作区移动插件未加载", code: "plugin-missing");
    }
    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}
    if (res.statusCode != 200 || body["ok"] != true) {
      throw DshApiException(
        body["error"]?.toString() ?? "移动失败（HTTP ${res.statusCode}）",
        code: body["code"]?.toString() ?? "session-move-failed",
      );
    }
    return body;
  }

  /// 把会话插入工作区（workspace.insertSessionBefore）。
  Future<void> insertSessionBefore(
    String workspaceId,
    String sessionId, {
    String? beforeSessionId,
  }) async {
    await _rpc('workspace.insertSessionBefore', {
      'workspaceId': workspaceId,
      'sessionId': sessionId,
      'beforeSessionId': ?beforeSessionId,
    });
  }

  // ── 子代理域 ──────────────────────────────────────────────────────────

  /// 子代理列表（subagent.list，需父会话 id）。
  Future<({List<DshSubagentEntry> entries, bool parentAvailable})>
  listSubagents(String parentSessionId) async {
    final v = await _rpc('subagent.list', {'parentSessionId': parentSessionId});
    return (
      entries: ((v['entries'] as List?) ?? const [])
          .map(
            (e) =>
                DshSubagentEntry.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList(),
      parentAvailable: v['parentAvailable'] == true,
    );
  }

  /// 子代理历史 + live token + 投影统计（打开详情页一次拉齐）。
  Future<DshSubagentHistoryBundle> subagentHistoryBundle(
    String parentSessionId,
    String childSessionId, {
    String mode = 'one-shot',
    int? beforeSeq,
    int? maxMessages,
  }) async {
    final v = await _rpc('subagent.history', {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': mode,
      'beforeSeq': ?beforeSeq,
      'maxMessages': ?maxMessages,
    });
    final projections = (v['projections'] as Map?)?.cast<String, dynamic>();
    DshSessionSummary? summary;
    if (projections != null) {
      summary = DshSessionSummary.fromJson({
        'sessionId': childSessionId,
        'updatedAt': 0,
        'running': false,
        'blank': false,
        'projections': projections,
      });
    }
    return DshSubagentHistoryBundle(
      messages: _historyFromValue(v, isSubagentHistory: true),
      live: DshLiveTurn.fromHistoryValue(v),
      summary: summary,
    );
  }

  /// 子代理历史（subagent.history，仅消息）。
  Future<List<ChatMessage>> subagentHistory(
    String parentSessionId,
    String childSessionId, {
    String mode = 'one-shot',
    int? beforeSeq,
    int? maxMessages,
  }) async {
    return (await subagentHistoryBundle(
      parentSessionId,
      childSessionId,
      mode: mode,
      beforeSeq: beforeSeq,
      maxMessages: maxMessages,
    )).messages;
  }

  /// 继续子代理（subagent.prompt，continuable 模式）。
  Future<void> subagentPrompt(
    String parentSessionId,
    String childSessionId,
    String text,
  ) async {
    await _rpc('subagent.prompt', {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': 'continuable',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'clientTimeZone': 'Asia/Shanghai',
    });
  }

  /// 中断子代理（subagent.interrupt）。
  Future<void> subagentInterrupt(
    String parentSessionId,
    String childSessionId,
  ) async {
    await _rpc('subagent.interrupt', {
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': 'continuable',
    });
  }

  // ── 技能域 ────────────────────────────────────────────────────────────

  /// 技能列表（skill.list）。
  ///
  /// DSH 0.1.0-rc.6 起 payload 固定要求已挂载的会话 id，冷会话会返回
  /// session-not-found；调用方应先通过 [createSession] 唤醒/挂载会话。
  /// 不再回退到空 payload，避免把协议错误伪装成“网络/启动失败”。
  Future<List<DshSkillInfo>> listSkills({required String sessionId}) async {
    final sid = sessionId.trim();
    if (sid.isEmpty) throw DshApiException('技能列表需要有效的 DSH 会话');
    final v = await _rpc('skill.list', {'sessionId': sid});
    final rawItems =
        v['items'] ?? v['skills'] ?? v['availableSkills'] ?? const [];
    final items = rawItems is List
        ? rawItems
        : rawItems is Map
        ? rawItems.values.toList()
        : const <dynamic>[];
    final result = items
        .whereType<Map>()
        .map((e) => DshSkillInfo.fromJson(e.cast<String, dynamic>()))
        .where((e) => e.name.isNotEmpty)
        .toList();
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  // ── 凭据域 ────────────────────────────────────────────────────────────

  /// 凭据描述。官方要 refs 数组；空数组不会枚举已知槽位。
  Future<List<DshCredentialSlot>> describeCredentials({
    List<String> refs = const [
      'SHIYI_API_KEY',
      'SHIYI_DSH_SEARCH_KEY',
      'DEEPSEEK_API_KEY',
    ],
  }) async {
    final v = await _rpc('credentials.describe', {'refs': refs});
    return DshCredentialSlot.fromDescribeValue(v);
  }

  /// 设置凭据（credentials.set，字段是 ref 字符串）。
  Future<void> setCredential(String ref, String value) async {
    await _rpc('credentials.set', {'ref': ref, 'value': value});
  }

  /// 删除凭据（credentials.unset，字段是 ref 字符串）。
  Future<void> unsetCredential(String ref) async {
    await _rpc('credentials.unset', {'ref': ref});
  }

  // ── 主机域 ────────────────────────────────────────────────────────────

  /// 主机信息（host.describe）。
  Future<DshHostInfo> hostDescribe() async {
    final v = await _rpc('host.describe', {});
    return DshHostInfo.fromJson(v);
  }

  /// 完整目录快照（host.listDirectory）；省略 path 时由远端列出其 home。
  Future<DshDirectoryListing> directoryListing([String? path]) async {
    final normalized = path?.trim() ?? '';
    final v = await _rpc(
      'host.listDirectory',
      normalized.isEmpty ? const {} : {'path': normalized},
    );
    return DshDirectoryListing.fromJson(v);
  }

  /// 目录条目兼容入口。
  Future<List<DshDirEntry>> listDirectory(String path) async {
    return (await directoryListing(path)).entries;
  }

  /// DSH 宿主账户的 home。host.listDirectory 省略 path 时会返回该字段。
  Future<String> hostHome() async {
    return (await directoryListing()).home;
  }

  /// 选择目录（host.pickDirectory）。
  Future<String?> pickDirectory() async {
    final v = await _rpc('host.pickDirectory', {});
    return (v['path'] ?? v['directory'] ?? v['selected'] ?? '').toString();
  }

  /// 打开路径（host.openPath）。
  Future<void> openPath(String path) async {
    await _rpc('host.openPath', {'path': path});
  }

  /// 创建目录（host.createDirectory）。name 必须是单个路径段。
  Future<String> createDirectory(String path, String name) async {
    final v = await _rpc('host.createDirectory', {'path': path, 'name': name});
    return (v['path'] ?? '').toString();
  }

  // ── 设置域 ────────────────────────────────────────────────────────────

  /// 设置命名空间（settings.describe）。
  Future<
    ({bool writable, bool hasDocument, List<DshSettingsNamespace> namespaces})
  >
  describeSettings() async {
    final v = await _rpc('settings.describe', {});
    final namespaces = ((v['namespaces'] as List?) ?? const []).map((e) {
      final n = (e as Map).cast<String, dynamic>();
      return DshSettingsNamespace(
        ns: (n['ns'] ?? '').toString(),
        value: (n['value'] as Map?)?.cast<String, dynamic>() ?? const {},
        base: (n['base'] as Map?)?.cast<String, dynamic>() ?? const {},
        user: (n['user'] as Map?)?.cast<String, dynamic>() ?? const {},
        schema: (n['schema'] as Map?)?.cast<String, dynamic>() ?? const {},
        secrets: ((n['secrets'] as List?) ?? const [])
            .map(
              (s) => DshCredentialSlot.fromJson(
                (s as Map).cast<String, dynamic>(),
              ),
            )
            .toList(),
        revision: (n['revision'] as num?)?.toInt() ?? 0,
      );
    }).toList();
    return (
      writable: v['writable'] == true,
      hasDocument: v['hasDocument'] == true,
      namespaces: namespaces,
    );
  }

  /// 更新设置命名空间（settings.update）。
  Future<void> updateSettings(
    String ns,
    Map<String, dynamic> patch, {
    int? expectedRevision,
  }) async {
    await _rpc('settings.update', {
      'ns': ns,
      'patch': patch,
      'expectedRevision': ?expectedRevision,
    });
  }

  /// 按路径改设置（settings.mutate）。手写自定义路由必须整段 set，
  /// 避免用 update 盖掉同命名空间里其他提供商。
  Future<void> mutateSettings(
    String ns,
    List<Map<String, dynamic>> ops, {
    int? expectedRevision,
  }) async {
    await _rpc('settings.mutate', {
      'ns': ns,
      'ops': ops,
      'expectedRevision': ?expectedRevision,
    });
  }

  // ── 权限预设（permissionPresets 服务） ──────────────────────────────

  /// 读权限预设表。未挂 permissionPresets 服务的 DSH 返回 null（按钮隐藏）。
  Future<DshPermissionPresets?> describePermissionPresets() async {
    final describe = await describeSettings();
    for (final namespace in describe.namespaces) {
      if (namespace.ns != 'permission') continue;
      final current = (namespace.value['defaultPreset'] ?? '').toString();
      final options = permissionOptionsFromSchema(namespace.schema);
      if (current.isEmpty && options.isEmpty) return null;
      return DshPermissionPresets(
        defaultPreset: current,
        revision: namespace.revision,
        options: options,
      );
    }
    return null;
  }

  /// 实时切换当前会话的权限预设（typert `commands/execute`，即官方输入框
  /// 弹层走的 `/permission <preset>` 命令）。对当前会话立即生效并写入
  /// `permission/preset` 事件；agent 未物化（会话冷）时服务端拒绝。
  /// 返回命令回执文本；kind=error 或 RPC 失败抛 [DshApiException]。
  /// 注意：typert assertExactArguments 要求可选参数的键也必须存在，
  /// `images` 缺键会被网关以 "missing images" 拒绝，必须显式传空数组。
  Future<String> executeSessionCommand(String sessionId, String line) async {
    final value = await _rpc('commands/execute', {
      'args': {'agentId': sessionId, 'line': line, 'images': <dynamic>[]},
    });
    final outcome = (value['result'] as Map?)?.cast<String, dynamic>();
    final kind = (outcome?['kind'] ?? '').toString();
    final text = (outcome?['text'] ?? '').toString();
    if (value.isEmpty || kind != 'success') {
      throw DshApiException(text.isEmpty ? '命令未被 DSH 接受' : text);
    }
    return text;
  }

  /// 从 schemastery 序列化 schema（{uid, refs} 引用图）解析预设表：
  /// 根对象 → dict.defaultPreset → union.list → const{value, meta.description}。
  /// 形状对不上时返回空列表（按钮隐藏，不硬编码预设名）。
  static List<DshPermissionPresetOption> permissionOptionsFromSchema(
    Map<String, dynamic> schema,
  ) {
    try {
      final refs = (schema['refs'] as Map?)?.cast<String, dynamic>();
      if (refs == null) return const [];
      final root = refs['${schema['uid']}'];
      final dict = root is Map ? (root['dict'] as Map?) : null;
      final unionId = dict?['defaultPreset'];
      final union = unionId == null ? null : refs['$unionId'];
      if (union is! Map || union['type'] != 'union') return const [];
      final list = (union['list'] as List?) ?? const [];
      final options = <DshPermissionPresetOption>[];
      for (final id in list) {
        final ref = refs['$id'];
        if (ref is! Map || ref['type'] != 'const') continue;
        final key = '${ref['value']}';
        if (key.isEmpty) continue;
        final meta = ref['meta'];
        final label = meta is Map && meta['description'] != null
            ? '${meta['description']}'
            : key;
        options.add(DshPermissionPresetOption(key: key, label: label));
      }
      return options;
    } catch (_) {
      return const [];
    }
  }

  /// 折叠 history 事件流里最后一次 `permission/preset`（data.preset）。
  static String? permissionPresetFromValue(Map<String, dynamic> value) {
    String? preset;
    for (final entry in (value['events'] as List?) ?? const []) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      if (ev?['type']?.toString() != 'permission/preset') continue;
      final data = (ev?['data'] as Map?)?.cast<String, dynamic>();
      preset = (data?['preset'] ?? '').toString();
    }
    return preset;
  }

  // ── 插件清单（typert pluginInventory/list，实时只读） ───────────────

  /// 目标 DSH 当前装载的插件实时清单（含 fiber 装载相位）。
  /// 远端连接的插件页用这条 RPC，不读本机补丁文件。
  Future<List<DshPluginInventoryEntry>> pluginInventoryList() async {
    final value = await _rpc('pluginInventory/list', {
      'args': <String, dynamic>{},
    });
    final entries = (value['entries'] as List?) ?? const [];
    return entries
        .map(
          (e) => DshPluginInventoryEntry.fromJson(
            (e as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
  }

  // ── 目标域 ────────────────────────────────────────────────────────────

  /// 创建目标（goal.create）。
  Future<DshGoalRef> createGoal(
    String sessionId,
    String objective, {
    int? maxGoalRounds,
  }) async {
    final v = await _rpc('goal.create', {
      'sessionId': sessionId,
      'objective': objective,
      'maxGoalRounds': ?maxGoalRounds,
    });
    return DshGoalRef.fromJson(v);
  }

  /// 编辑目标（goal.edit）。
  Future<DshGoalRef> editGoal(
    String sessionId,
    String ref,
    String objective, {
    int? maxGoalRounds,
  }) async {
    final v = await _rpc('goal.edit', {
      'sessionId': sessionId,
      'ref': ref,
      'objective': objective,
      'maxGoalRounds': ?maxGoalRounds,
    });
    return DshGoalRef.fromJson(v);
  }

  /// 暂停目标（goal.pause）。
  Future<void> pauseGoal(String sessionId, String ref) async {
    await _rpc('goal.pause', {'sessionId': sessionId, 'ref': ref});
  }

  /// 恢复目标（goal.resume）。
  Future<void> resumeGoal(String sessionId, String ref) async {
    await _rpc('goal.resume', {'sessionId': sessionId, 'ref': ref});
  }

  /// 完成目标（goal.complete）。
  Future<void> completeGoal(String sessionId, String ref) async {
    await _rpc('goal.complete', {'sessionId': sessionId, 'ref': ref});
  }

  /// 清除目标（goal.clear）。
  Future<void> clearGoal(String sessionId, String ref) async {
    await _rpc('goal.clear', {'sessionId': sessionId, 'ref': ref});
  }

  // ── 搜索域 ────────────────────────────────────────────────────────────

  /// 搜索会话（session.search）。部署未启用全文索引时抛 DshApiException。
  Future<List<DshSessionSummary>> searchSessions(String query) async {
    final v = await _rpc('session.search', {'query': query});
    final items = (v['items'] ?? const []) as List;
    return items
        .map(
          (e) => DshSessionSummary.fromJson((e as Map).cast<String, dynamic>()),
        )
        .where((s) => !s.isSubagent)
        .toList();
  }

  /// 拉取会话历史并重建为消息列表。
  /// 事件流是 delta 模型：正式气泡来自 user/message、assistant/message、
  /// tool/call；若一轮在 turn/end 时仍只有 assistant/chunk、没有正式
  /// assistant/message，则把未收口缓冲冻成最后一条助手消息（与官方
  /// 客户端的 interrupted 节点一致）。
  Future<List<ChatMessage>> history(String sessionId) async {
    return (await historyBundle(sessionId)).messages;
  }

  /// 历史消息 + 末尾未收口的 live token（打开会话时补种流式气泡）。
  Future<DshHistoryBundle> historyBundle(String sessionId) async {
    final value = await _rpc('session.history', {'sessionId': sessionId});
    return DshHistoryBundle(
      messages: _historyFromValue(value),
      live: DshLiveTurn.fromHistoryValue(value),
      responseModels: _responseModelsFromValue(value),
      turnEnded: _historyTurnEnded(value),
      permissionPreset: permissionPresetFromValue(value),
    );
  }

  static bool _historyTurnEnded(Map<String, dynamic> value) {
    final entries = (value['events'] as List?) ?? const [];
    var sawUser = false;
    var ended = false;
    for (final entry in entries) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      final type = ev?['type']?.toString() ?? '';
      final surfaceOp = ev?['surfaceOp'];
      final isReplacementCheckpoint =
          surfaceOp is Map && surfaceOp['op']?.toString() == 'replace';
      if ((type == 'user/message' && !isReplacementCheckpoint) ||
          type == 'agent/inbox/spliced') {
        sawUser = true;
        ended = false;
      } else if (type == 'turn/end' && sawUser) {
        ended = true;
      }
    }
    return ended;
  }

  /// 全会话 mux 下行。调用方按 sessionId 过滤。
  Stream<Map<String, dynamic>> watchMux() =>
      DshWsDownlink.connect(_baseUrl, 'events.mux', headers: _wsHeaders());

  /// 主机级下行：running 翻转、会话增删。
  Stream<Map<String, dynamic>> watchHost() =>
      DshWsDownlink.connect(_baseUrl, 'events.host', headers: _wsHeaders());

  /// DSH 把运行时沙箱快照写成 sourced user/message。这是官方注入，不改 DSH；
  /// 拾忆把它挂到相邻真实气泡上，做成可展开组件，默认收起。
  static bool isInjectedRuntimeContext(String text) {
    final t = text.trimLeft();
    if (t.isEmpty) return false;
    return t.startsWith('Current runtime context') ||
        t.contains(
          'This snapshot supersedes earlier runtime-context snapshots',
        ) ||
        t.contains('Current DSH file policy:');
  }

  /// DSH 把 skill 目录（`<system-reminder>` 包裹的可用技能列表）写成
  /// sourced user/message，每次 agent 步骤前注入。这是写给模型看的目录，
  /// 对用户零价值，聊天界面直接丢弃、不单独成气泡也不挂折叠。
  static bool isInjectedSkillCatalog(String text) {
    final t = text.trimLeft();
    return t.contains(
          'A skill is a reusable set of task-specific instructions',
        ) ||
        t.contains('<available_skills>') ||
        t.contains('The available skill catalog changed');
  }

  /// 从 history 响应 value 重建消息列表（session.history / subagent.history 共用）。
  static List<ChatMessage> _historyFromValue(
    Map<String, dynamic> value, {
    bool isSubagentHistory = false,
  }) {
    final entries = (value['events'] as List?) ?? const [];
    final messages = <ChatMessage>[];
    final rolledBack = <ChatMessage>[];
    final seenMessageIds = <String>{};
    final surfaceSeqs = <int>[];
    final messageEventSeqs = <ChatMessage, int>{};
    final pendingLive = DshLiveTurn();
    var pendingStepFinalized = false;
    var pendingContext = '';
    var pendingSubagentSummary = false;
    var suppressDuplicateSubagentReply = false;

    void rememberContext(String text) {
      final t = text.trim();
      if (t.isNotEmpty) pendingContext = t;
    }

    void attachContext(ChatMessage msg) {
      if (pendingContext.isEmpty) return;
      msg.runtimeContext = pendingContext;
      pendingContext = '';
    }

    bool pendingLiveVisible() =>
        pendingLive.text.trim().isNotEmpty ||
        pendingLive.reasoning.trim().isNotEmpty ||
        pendingLive.toolCalls.isNotEmpty;

    void resetPendingLive({required bool keepReasoning}) {
      if (keepReasoning) {
        pendingLive.continueTurn();
      } else {
        pendingLive.reset();
      }
      pendingStepFinalized = false;
    }

    String markedText(String text, String marker) {
      return text.trimLeft().startsWith(marker) ? text : '$marker\n$text';
    }

    ({String role, String content, bool isSubagentResult}) presentUserMessage(
      String text,
      Iterable<dynamic> sources,
    ) {
      if (_isSubagentResult(sources)) {
        return (
          role: 'assistant',
          content: markedText(text, '<子代理返回信息>'),
          isSubagentResult: true,
        );
      }
      final promptMarked = text.trimLeft().startsWith('<子代理提示词注入>');
      if (promptMarked ||
          (isSubagentHistory && _isSubagentPromptSource(sources))) {
        return (
          role: 'assistant',
          content: markedText(text, '<子代理提示词注入>'),
          isSubagentResult: false,
        );
      }
      return (role: 'user', content: text, isSubagentResult: false);
    }

    bool isPresentedUserMessage(ChatMessage message) {
      final text = message.content.trimLeft();
      return message.role == 'user' ||
          text.startsWith('<子代理返回信息>') ||
          text.startsWith('<子代理提示词注入>');
    }

    String messageId(Map<String, dynamic> value, int seq) {
      final raw = value['id']?.toString().trim() ?? '';
      return 'dsh-${raw.isEmpty ? seq : raw}';
    }

    void trackSubagentSummary(
      ({String role, String content, bool isSubagentResult}) presentation,
    ) {
      pendingSubagentSummary = presentation.isSubagentResult;
    }

    bool takeIfContext(String text) {
      // skill 目录注入（写给模型的 <system-reminder>）与运行时沙箱快照
      // 一样：不单独成气泡，挂到相邻真实气泡的注入上下文折叠，默认收起。
      if (!isInjectedRuntimeContext(text) && !isInjectedSkillCatalog(text)) {
        return false;
      }
      rememberContext(text);
      return true;
    }

    /// 官方客户端在 turn/end 时若本步没有 assistant/message，会把
    /// 已发出的 chunk 冻成 interrupted 节点。这里同样冻成一条助手消息，
    /// 避免拉取历史时最后输出被截断。
    void freezePendingLive({required int seq, required int time}) {
      if (pendingStepFinalized || !pendingLiveVisible()) {
        resetPendingLive(keepReasoning: false);
        return;
      }
      if (suppressDuplicateSubagentReply) {
        suppressDuplicateSubagentReply = false;
        pendingSubagentSummary = false;
        resetPendingLive(keepReasoning: false);
        return;
      }
      final text = pendingLive.text.trim();
      final reasoning = pendingLive.reasoning.trim();
      if (takeIfContext(text)) {
        resetPendingLive(keepReasoning: false);
        return;
      }
      final isSubagentSummary = pendingSubagentSummary && reasoning.isNotEmpty;
      final item = ChatMessage(
        id: 'dsh-asst-$seq',
        sessionId: '',
        role: 'assistant',
        content: text,
        reasoning: isSubagentSummary ? '' : reasoning,
        subagentSummary: isSubagentSummary ? reasoning : '',
        toolCalls: List<ToolCall>.of(pendingLive.toolCalls),
        createdAt: time,
      );
      attachContext(item);
      messages.add(item);
      messageEventSeqs[item] = seq;
      if (pendingSubagentSummary) pendingSubagentSummary = false;
      resetPendingLive(keepReasoning: false);
    }

    void applySurfaceOp(Map<String, dynamic> event, String type, int seq) {
      if (type != 'user/message' &&
          type != 'assistant/message' &&
          type != 'tool/result') {
        return;
      }
      final rawOp = event['surfaceOp'];
      if (rawOp is! Map || rawOp['op']?.toString() != 'replace') {
        // 旧版 history 与测试夹具没有 surfaceOp；按 append 兼容。
        surfaceSeqs.add(seq);
        return;
      }
      final start = (rawOp['start'] as num?)?.toInt();
      final end = (rawOp['end'] as num?)?.toInt();
      if (start == null || end == null) {
        surfaceSeqs.add(seq);
        return;
      }
      final startIndex = surfaceSeqs.indexOf(start);
      final endIndex = surfaceSeqs.indexOf(end);
      if (startIndex < 0 || endIndex < startIndex) {
        // 畸形或截断历史不能破坏整页加载；至少展示新的 checkpoint。
        surfaceSeqs.add(seq);
        return;
      }

      final removed = messages.where((message) {
        final eventSeq = messageEventSeqs[message];
        return eventSeq != null && eventSeq >= start && eventSeq <= end;
      }).toList();
      for (final message in removed) {
        seenMessageIds.remove(message.id);
        messageEventSeqs.remove(message);
      }
      messages.removeWhere(removed.contains);
      rolledBack.removeWhere((message) {
        final eventSeq = messageEventSeqs[message];
        final shadowed =
            eventSeq != null && eventSeq >= start && eventSeq <= end;
        if (shadowed) messageEventSeqs.remove(message);
        return shadowed;
      });
      surfaceSeqs.replaceRange(startIndex, endIndex + 1, [seq]);
      pendingContext = '';
      pendingSubagentSummary = false;
      suppressDuplicateSubagentReply = false;
      resetPendingLive(keepReasoning: false);
    }

    for (final entry in entries) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      if (ev == null) continue;
      final type = ev['type']?.toString() ?? '';
      final data = (ev['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final seq = (ev['seq'] as num?)?.toInt() ?? 0;
      final time = (ev['time'] as num?)?.toInt() ?? 0;
      applySurfaceOp(ev, type, seq);
      if (type == 'agent/inbox/spliced') {
        final removed = (data['removedCount'] as num?)?.toInt() ?? 0;
        var left = removed;
        var removedSubagentResult = false;
        while (left > 0 &&
            messages.isNotEmpty &&
            isPresentedUserMessage(messages.last)) {
          final removed = messages.removeLast();
          removedSubagentResult =
              removedSubagentResult ||
              removed.content.trimLeft().startsWith('<子代理返回信息>');
          seenMessageIds.remove(removed.id);
          rolledBack.add(removed);
          left--;
        }
        if (removedSubagentResult) pendingSubagentSummary = false;
        final inserted = (data['inserted'] as List?) ?? const [];
        for (final item in inserted) {
          final m = (item as Map).cast<String, dynamic>();
          if (m['role']?.toString() != 'user') continue;
          final text = _joinTextParts((m['content'] as List?) ?? const []);
          if (text.trim().isEmpty) continue;
          if (takeIfContext(text)) continue;
          final presentation = presentUserMessage(text, [
            m['source'],
            m['metadata'],
            data,
            data['source'],
            data['metadata'],
            ev['source'],
          ]);
          final id = messageId(m, seq);
          if (seenMessageIds.contains(id)) {
            if (presentation.isSubagentResult) {
              suppressDuplicateSubagentReply = true;
              pendingSubagentSummary = false;
            }
            continue;
          }
          final msg = ChatMessage(
            id: id,
            sessionId: '',
            role: presentation.role,
            content: presentation.content,
            createdAt: time,
          );
          attachContext(msg);
          messages.add(msg);
          messageEventSeqs[msg] = seq;
          seenMessageIds.add(id);
          trackSubagentSummary(presentation);
        }
      } else if (type == 'turn/end') {
        freezePendingLive(seq: seq, time: time);
        final reason = (data['reason'] as Map?)?.cast<String, dynamic>();
        if (reason != null && reason['kind']?.toString() == 'error') {
          pendingSubagentSummary = false;
          messages.addAll(rolledBack.reversed);
          seenMessageIds.addAll(rolledBack.map((message) => message.id));
          rolledBack.clear();
          final err =
              (reason['error'] as Map?)?.cast<String, dynamic>() ?? const {};
          final msg = err['message']?.toString() ?? '未知错误';
          final errorMessage = ChatMessage(
            id: 'dsh-err-$seq',
            sessionId: '',
            role: 'assistant',
            content: '本轮失败：$msg',
            createdAt: time,
          );
          messages.add(errorMessage);
          messageEventSeqs[errorMessage] = seq;
        } else {
          rolledBack.clear();
        }
      } else if (type == 'assistant/chunk') {
        if (pendingLive.ingest(ev)) pendingStepFinalized = false;
      } else if (type == 'user/message') {
        final content = (data['content'] as List?) ?? const [];
        final text = _joinTextParts(content);
        if (text.trim().isEmpty) continue;
        if (takeIfContext(text)) continue;
        resetPendingLive(keepReasoning: false);
        final presentation = presentUserMessage(text, [
          data['source'],
          data['metadata'],
          data['message'],
          data,
          ev['source'],
        ]);
        final id = messageId(data, seq);
        if (seenMessageIds.contains(id)) {
          if (presentation.isSubagentResult) {
            // DSH can replay the same report after it has already been
            // consumed through agent/inbox/spliced. Its following assistant
            // acknowledgement is a duplicate turn, not a new user request.
            suppressDuplicateSubagentReply = true;
            pendingSubagentSummary = false;
          }
          continue;
        }
        final msg = ChatMessage(
          id: id,
          sessionId: '',
          role: presentation.role,
          content: presentation.content,
          createdAt: time,
        );
        attachContext(msg);
        messages.add(msg);
        messageEventSeqs[msg] = seq;
        seenMessageIds.add(id);
        trackSubagentSummary(presentation);
      } else if (type == 'assistant/message') {
        resetPendingLive(keepReasoning: true);
        pendingStepFinalized = true;
        if (suppressDuplicateSubagentReply) {
          suppressDuplicateSubagentReply = false;
          pendingSubagentSummary = false;
          continue;
        }
        final msg =
            (data['message'] as Map?)?.cast<String, dynamic>() ?? const {};
        final content = (msg['content'] as List?) ?? const [];
        var text = _joinTextParts(content);
        if (takeIfContext(text)) continue;
        final split = splitThinkTags(text);
        text = split.text.trim();
        final reasoning = mergeReasoning(
          _joinReasoningParts(content),
          split.reasoning,
        ).trim();
        final isSubagentSummary =
            pendingSubagentSummary && reasoning.trim().isNotEmpty;
        final item = ChatMessage(
          id: 'dsh-asst-$seq',
          sessionId: '',
          role: 'assistant',
          content: text,
          reasoning: isSubagentSummary ? '' : reasoning,
          subagentSummary: isSubagentSummary ? reasoning : '',
          createdAt: time,
        );
        attachContext(item);
        messages.add(item);
        messageEventSeqs[item] = seq;
        if (pendingSubagentSummary) pendingSubagentSummary = false;
      } else if (type == 'tool/call') {
        pendingLive.ingest(ev);
        // 本步已有正式 assistant/message 时挂到该气泡；否则留给
        // turn/end 的 freeze，避免工具误挂到上一轮助手消息。
        if (!pendingStepFinalized) continue;
        final last = messages.isEmpty ? null : messages.last;
        if (last != null && last.role == 'assistant') {
          last.toolCalls.add(
            ToolCall(
              id: data['callId']?.toString() ?? '',
              name: data['name']?.toString() ?? '',
              arguments: data['arguments']?.toString() ?? '',
            ),
          );
        }
      }
    }
    if (pendingContext.isNotEmpty && messages.isNotEmpty) {
      messages.last.runtimeContext = pendingContext;
    }
    return messages;
  }

  /// DSH 版本之间曾把子代理回传的来源放在不同层级：有的在插入消息
  /// 的 source，有的在 user/message 的 data.source。兼容这些形态，避免
  /// 回传被当成右侧用户气泡。
  static bool _isSubagentResult(Iterable<dynamic> values) {
    bool visit(dynamic value, int depth) {
      if (depth > 3 || value == null) return false;
      if (value is String) {
        final t = value.toLowerCase();
        return t.contains('subagent') &&
            (t.contains('settled') ||
                t.contains('report') ||
                t.contains('result') ||
                t.contains('return') ||
                t == 'subagent');
      }
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase();
          final raw = entry.value;
          if (key == 'kind' ||
              key == 'type' ||
              key == 'status' ||
              key == 'source' ||
              key == 'origin' ||
              key == 'metadata' ||
              key == 'sender' ||
              key == 'senderkind') {
            if (visit(raw, depth + 1)) return true;
          }
        }
        // 某些网关只留下 senderSessionId；它只会出现在子代理注入里。
        if (value.keys.any(
          (k) => k.toString().toLowerCase() == 'sendersessionid',
        )) {
          return true;
        }
      }
      if (value is Iterable) {
        for (final item in value) {
          if (visit(item, depth + 1)) return true;
        }
      }
      return false;
    }

    return values.any((value) => visit(value, 0));
  }

  /// 子代理会话里的直接 user 来源是主代理派发或追加给子代理的提示词。
  /// 只在 subagent.history 解析路径启用，普通主会话的用户消息不受影响。
  static bool _isSubagentPromptSource(Iterable<dynamic> values) {
    bool visit(dynamic value, int depth) {
      if (depth > 3 || value == null) return false;
      if (value is String) {
        final t = value.toLowerCase();
        return t == 'user' ||
            t == 'prompt' ||
            t.contains('subagent-prompt') ||
            t.contains('subagent_prompt');
      }
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase();
          if (key == 'kind' ||
              key == 'type' ||
              key == 'source' ||
              key == 'origin' ||
              key == 'metadata') {
            if (visit(entry.value, depth + 1)) return true;
          }
        }
      }
      if (value is Iterable) {
        for (final item in value) {
          if (visit(item, depth + 1)) return true;
        }
      }
      return false;
    }

    return values.any((value) => visit(value, 0));
  }

  /// 上游网关可能把请求模型别名解析成真实模型名。DSH 派生子代理时会
  /// 复用 responseModel，因此拾忆需要把历史里见过的真实名字补进 provider。
  static Set<String> _responseModelsFromValue(Map<String, dynamic> value) {
    final models = <String>{};
    final entries = (value['events'] as List?) ?? const [];
    for (final entry in entries) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      if (ev?['type']?.toString() != 'assistant/message') continue;
      final data = (ev?['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final message =
          (data['message'] as Map?)?.cast<String, dynamic>() ?? const {};
      final source =
          (message['source'] as Map?)?.cast<String, dynamic>() ?? const {};
      final replay =
          (source['replayState'] as Map?)?.cast<String, dynamic>() ?? const {};
      for (final raw in [
        replay['responseModel'],
        message['responseModel'],
        data['responseModel'],
      ]) {
        final model = raw?.toString().trim() ?? '';
        if (model.isNotEmpty &&
            model.length <= 200 &&
            !model.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
          models.add(model);
        }
      }
    }
    return models;
  }

  static String _joinTextParts(List<dynamic> content) {
    final buf = StringBuffer();
    for (final part in content) {
      final p = (part as Map?)?.cast<String, dynamic>();
      if (p == null) continue;
      if (p['type'] == 'text') buf.write(p['text']?.toString() ?? '');
    }
    return buf.toString().trim();
  }

  static String _joinReasoningParts(List<dynamic> content) {
    final buf = StringBuffer();
    for (final part in content) {
      final p = (part as Map?)?.cast<String, dynamic>();
      if (p == null) continue;
      if (p['type'] == 'reasoning' ||
          p['type'] == 'thinking' ||
          p['type'] == 'thought') {
        buf.write(p['text']?.toString() ?? p['content']?.toString() ?? '');
      }
    }
    return buf.toString().trim();
  }

  void dispose() {
    _client.close();
  }
}
